//
//    Copyright (C) Microsoft.  All rights reserved.
// Licensed under the terms described in the LICENSE file in the root of this project.
//

#include "stdafx.h"

// Commandline arguments: 
#define ARG_CONFIG              L"config"
#define ARG_CONFIG_DEFAULT_USER L"--default-user"
#define ARG_INSTALL             L"install"
#define ARG_INSTALL_ROOT        L"--root"
#define ARG_RUN                 L"run"
#define ARG_RUN_C               L"-c"
#define CMD_BUF_MAX_LENGTH      (LOCALE_NAME_MAX_LENGTH + 38)
#define CMD_AOSC_SET_LOCALE     L"echo \"LANG=%s.UTF-8\" > /etc/locale.conf"

// Helper class for calling WSL Functions:
// https://msdn.microsoft.com/en-us/library/windows/desktop/mt826874(v=vs.85).aspx
WslApiLoader g_wslApi(DistributionInfo::Name);

static HRESULT InstallDistribution(bool createUser);
static HRESULT SetDefaultUser(std::wstring_view userName);
static HRESULT GenerateLocaleCommand(LPWSTR command_buf);

HRESULT InstallDistribution(bool createUser)
{
    // Register the distribution.
    Helpers::PrintMessage(MSG_STATUS_INSTALLING);
    HRESULT hr = g_wslApi.WslRegisterDistribution();
    if (FAILED(hr)) {
        return hr;
    }

    // Delete /etc/resolv.conf to allow WSL to generate a version based on Windows networking information.
    DWORD exitCode;
    hr = g_wslApi.WslLaunchInteractive(L"/bin/rm /etc/resolv.conf", true, &exitCode);
    if (FAILED(hr)) {
        return hr;
    }

    // Do not unset PATH
    hr = g_wslApi.WslLaunchInteractive(L"sed -e 's/^unset PATH MANPATH/unset MANPATH # PATH/' -i /etc/profile", true, &exitCode);
    if (FAILED(hr)) {
        return hr;
    }

    // Configure per distro launch settings with wslconf
    //hr = g_wslApi.WslLaunchInteractive(L"echo \"# Enable extra metadata options by default\n[automount]\noptions = \\\"metadata,umask=22,fmask=11\\\"\" > /etc/wsl.conf", true, &exitCode);
    //if (FAILED(hr)) {
    //    return hr;
    //}

    // Set container locale according to Windows system locale
    wchar_t command[CMD_BUF_MAX_LENGTH];
    if (command == nullptr) {
        return E_FAIL;
    }
    hr = GenerateLocaleCommand(command);
    if (FAILED(hr)) {
        return hr;
    }
    hr = g_wslApi.WslLaunchInteractive(command, true, &exitCode);
    if (FAILED(hr)) {
        return hr;
    }

    // Create a user account.
    if (createUser) {
        Helpers::PrintMessage(MSG_CREATE_USER_PROMPT);
        std::wstring userName;
        do {
            userName = Helpers::GetUserInput(MSG_ENTER_USERNAME, 32);

        } while (!DistributionInfo::CreateUser(userName));

        // Set this user account as the default.
        hr = SetDefaultUser(userName);
        if (FAILED(hr)) {
            return hr;
        }
    }

    return hr;
}

HRESULT SetDefaultUser(std::wstring_view userName)
{
    // Query the UID of the given user name and configure the distribution
    // to use this UID as the default.
    ULONG uid = DistributionInfo::QueryUid(userName);
    if (uid == UID_INVALID) {
        return E_INVALIDARG;
    }

    HRESULT hr = g_wslApi.WslConfigureDistribution(uid, WSL_DISTRIBUTION_FLAGS_DEFAULT);
    if (FAILED(hr)) {
        return hr;
    }

    return hr;
}

static HRESULT GenerateLocaleCommand(LPWSTR command_buf)
{
    // Generate the command which sets container locale according to system locale.
    // The buffer given to this function should be big as CMD_BUF_MAX_LENGTH.
    // This might be an AOSC OS specific functionality.

    int result = 0;
    HRESULT hr = ERROR_SUCCESS;

    // Get a buffer which stores locale information.
    wchar_t locale[LOCALE_NAME_MAX_LENGTH];
    result = GetUserDefaultLocaleName(locale, LOCALE_NAME_MAX_LENGTH);
    if (result <= 0) {
        // GetUserDefaultLocaleName() returns the string length of the locale name.
        // If it fails, fallback to en_US.
        hr = StringCchCopyW(locale, LOCALE_NAME_MAX_LENGTH, L"en_US");
        if (FAILED(hr)) {
            return E_FAIL;
        }
        Helpers::PrintMessage(MSG_LOCALE_ACQUIRSION_FAILURE);
    }
    for (int i = 0; locale[i] != L'\0' || i < LOCALE_NAME_MAX_LENGTH; i++) {
        if (locale[i] == L'-') {
            locale[i] = L'_';
        }
    }
    hr = StringCchPrintfW(command_buf, CMD_BUF_MAX_LENGTH, CMD_AOSC_SET_LOCALE, locale);
    if (FAILED(hr)) {
        return E_FAIL;
    }
    return ERROR_SUCCESS;
}

int wmain(int argc, wchar_t const *argv[])
{
    // Enable UTF-8 support.
    setlocale(LC_ALL, ".UTF8");

    // Update the title bar of the console window.
    SetConsoleTitleW(DistributionInfo::WindowTitle.c_str());

    // Initialize a vector of arguments.
    std::vector<std::wstring_view> arguments;
    for (int index = 1; index < argc; index += 1) {
        arguments.push_back(argv[index]);
    }

    // Ensure that the Windows Subsystem for Linux optional component is installed.
    DWORD exitCode = 1;
    if (!g_wslApi.WslIsOptionalComponentInstalled()) {
        Helpers::PrintErrorMessage(HRESULT_FROM_WIN32(ERROR_LINUX_SUBSYSTEM_NOT_PRESENT));
        if (arguments.empty()) {
            Helpers::PromptForInput();
        }

        return exitCode;
    }

    // Install the distribution if it is not already.
    bool installOnly = ((arguments.size() > 0) && (arguments[0] == ARG_INSTALL));
    HRESULT hr = S_OK;
    if (!g_wslApi.WslIsDistributionRegistered()) {

        // If the "--root" option is specified, do not create a user account.
        bool useRoot = ((installOnly) && (arguments.size() > 1) && (arguments[1] == ARG_INSTALL_ROOT));
        hr = InstallDistribution(!useRoot);
        if (FAILED(hr)) {
            if (hr == HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS)) {
                Helpers::PrintMessage(MSG_INSTALL_ALREADY_EXISTS);
            }

        } else {
            Helpers::PrintMessage(MSG_INSTALL_SUCCESS);
        }

        exitCode = SUCCEEDED(hr) ? 0 : 1;
    }

    // Parse the command line arguments.
    if ((SUCCEEDED(hr)) && (!installOnly)) {
        if (arguments.empty()) {
            hr = g_wslApi.WslLaunchInteractive(L"", false, &exitCode);

            // Check exitCode to see if wsl.exe returned that it could not start the Linux process
            // then prompt users for input so they can view the error message.
            if (SUCCEEDED(hr) && exitCode == UINT_MAX) {
                Helpers::PromptForInput();
            }

        } else if ((arguments[0] == ARG_RUN) ||
                   (arguments[0] == ARG_RUN_C)) {

            std::wstring command;
            for (size_t index = 1; index < arguments.size(); index += 1) {
                command += L" ";
                command += arguments[index];
            }

            hr = g_wslApi.WslLaunchInteractive(command.c_str(), true, &exitCode);

        } else if (arguments[0] == ARG_CONFIG) {
            hr = E_INVALIDARG;
            if (arguments.size() == 3) {
                if (arguments[1] == ARG_CONFIG_DEFAULT_USER) {
                    hr = SetDefaultUser(arguments[2]);
                }
            }

            if (SUCCEEDED(hr)) {
                exitCode = 0;
            }

        } else {
            Helpers::PrintMessage(MSG_USAGE);
            return exitCode;
        }
    }

    // If an error was encountered, print an error message.
    if (FAILED(hr)) {
        if (hr == HCS_E_HYPERV_NOT_INSTALLED) {
            Helpers::PrintMessage(MSG_ENABLE_VIRTUALIZATION);

        } else {
            Helpers::PrintErrorMessage(hr);
        }

        if (arguments.empty()) {
            Helpers::PromptForInput();
        }
    }

    return SUCCEEDED(hr) ? exitCode : 1;
}
