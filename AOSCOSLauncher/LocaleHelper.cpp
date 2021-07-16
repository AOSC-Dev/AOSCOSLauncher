#include "LocaleHelper.h"

namespace LocaleHelper {

    static HRESULT getLocale(LPWSTR buf)
    {
        HRESULT hr = ERROR_SUCCESS;
        int result;
        result = GetUserDefaultLocaleName(buf, LOCALE_NAME_MAX_LENGTH);
        if (result <= 0) {
            // GetUserDefaultLocaleName() returns the string length of the locale name.
            // If it fails, fallback to en_US.
            hr = StringCchCopyW(buf, LOCALE_NAME_MAX_LENGTH, L"en_US");
            if (FAILED(hr)) {
                return E_FAIL;
            }
            // Helpers::PrintMessage(MSG_LOCALE_ACQUIRSION_FAILURE);
        }
        for (int i = 0; buf[i] != L'\0' || i < LOCALE_NAME_MAX_LENGTH; i++) {
            if (buf[i] == L'-') {
                buf[i] = L'_';
            }
        }
        return hr;
    }
    static int isValidLocale(LPWSTR code) {
        int res = 0;

        std::wstring str = code;
        if (str.find(L"_") == std::wstring::npos) {
            // One exception is "eo"
            for (int i = 0; i < 198; i++) {
                if (str.compare(languages[i]) == 0) {
                    return 0;
                }
            }
            return -1;
        }

        std::wstring cr = (str.substr(0, str.find(L"_")).c_str());
        std::wstring tr = (str.substr(str.find(L"_") + 1).c_str());

        for (; res < 198; res++) {
            if (cr.compare(languages[res]) == 0) {
                for (int j = 0; j < sizes[res]; j++) {
                    if (tr.compare(territories[res][j]) == 0) {
                        return 0;
                    }
                }
            }
            if (res == 197) return -1;
        }
        return res;
    }

    static HRESULT GenerateLocaleCommand(LPWSTR command_buf)
    {
        // Generate the command which sets container locale according to system locale.
        // The buffer given to this function should be big as CMD_BUF_MAX_LENGTH.
        // This might be an AOSC OS specific functionality.
        HRESULT hr = ERROR_SUCCESS;

        // Get a buffer which stores locale information.
        wchar_t locale[LOCALE_NAME_MAX_LENGTH];
        hr = getLocale(locale);
        if (FAILED(hr)) {
            return hr;
        }

        int res = isValidLocale(locale);
        switch (res) {
        case 0:
            // Locale is valid in AOSC
            break;
        case -1:
            // Such country code does not exist
            // fallback to en_US
            hr = StringCchCopyW(locale, 6, L"en_US");
            if (FAILED(hr)) {
                return E_FAIL;
            }
            Helpers::PrintErrorMessage(MSG_LOCALE_ACQUIRSION_FAILURE);
            break;
        default:
            // Country is valid but such territory does not exist (e.g. de_US)
            // The default fallback territory code is in the first of its list.
            hr = StringCchCopyW(locale, LOCALE_NAME_MAX_LENGTH, territories[res][0]);
            if (FAILED(hr)) {
                return hr;
            }
            break;
        }

        hr = StringCchPrintfW(command_buf, CMD_BUF_MAX_LENGTH, CMD_AOSC_SET_LOCALE, locale);
        if (FAILED(hr)) {
            return hr;
        }
        return ERROR_SUCCESS;
    }
}