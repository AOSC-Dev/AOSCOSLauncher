LanguageNames = (English=0x409:MSG00409)
LanguageNames = (zh_CN=0x804:MSG00804)


MessageId=1001 SymbolicName=MSG_WSL_REGISTER_DISTRIBUTION_FAILED
Language=English
WslRegisterDistribution failed with error: 0x%1!x!
.

Language=zh_CN
函数 WslRegisterDistribution 执行时出错: 0x%1!x!
.


MessageId=1002 SymbolicName=MSG_WSL_CONFIGURE_DISTRIBUTION_FAILED
Language=English
WslGetDistributionConfiguration failed with error: 0x%1!x!
.

Language=zh_CN
函数 WslGetDistributionConfiguration 执行时出错: 0x%1!x!
.


MessageId=1003 SymbolicName=MSG_WSL_LAUNCH_INTERACTIVE_FAILED
Language=English
WslLaunchInteractive %1 failed with error: 0x%2!x!
.

Language=zh_CN
函数 WslLaunchInteractive 执行命令 `%1` 时出错: 0x%2!x!
.


MessageId=1004 SymbolicName=MSG_WSL_LAUNCH_FAILED
Language=English
WslLaunch %1 failed with error: 0x%2!x!
.

Language=zh_CN
函数 WslLaunch 执行命令 `%1` 时出错: 0x%2!x!
.


MessageId=1005 SymbolicName=MSG_USAGE
Language=English
Launches or configures a Linux distribution.

Usage: 
    <no args> 
        Launches the user's default shell in the user's home directory.

    install [--root]
        Install the distribuiton and do not launch the shell when complete.
          --root
              Do not create a user account and leave the default user set to root.

    run <command line> 
        Run the provided command line in the current working directory. If no
        command line is provided, the default shell is launched.

    config [setting [value]] 
        Configure settings for this distribution.
        Settings:
          --default-user <username>
              Sets the default user to <username>. This must be an existing user.

    help 
        Print usage information.
.

Language=zh_CN
启动或配置 Linux 发行版。

用法:
    <无参数>
        在当前用户的主目录中运行用户默认的 Shell。

    install [--root]
        安装该发行版但不运行 Shell。
          --root
              在安装时不创建用户，使 root 成为默认用户。

    run <命令行>
        在当前目录下运行指定的命令。如果没有指定命令，则运行用户默认的 Shell。

    config [设置项 [值]]
        更改该发行版的设置。
        可用设置项:
          --default-user <用户名>
              更改默认用户为指定用户，该用户必须存在于发行版中。

    help
        显示用法信息。
.


MessageId=1006 SymbolicName=MSG_STATUS_INSTALLING
Language=English
Installing, this may take a few minutes...
.

Language=zh_CN
正在安装，这可能需要几分钟，请稍候...
.


MessageId=1007 SymbolicName=MSG_INSTALL_SUCCESS
Language=English
Installation successful!
.

Language=zh_CN
安装完成。
.


MessageId=1008 SymbolicName=MSG_ERROR_CODE
Language=English
Error: 0x%1!x! %2
.

Language=zh_CN
发生错误: 0x%1!x! %2
.


MessageId=1009 SymbolicName=MSG_ENTER_USERNAME
Language=English
Enter new UNIX username: %0
.

Language=zh_CN
输入新 UNIX 用户名: %0
.


MessageId=1010 SymbolicName=MSG_CREATE_USER_PROMPT
Language=English
Please create a default UNIX user account. The username does not need to match your Windows username.
For more information visit: https://aka.ms/wslusers
.

Language=zh_CN
请创建一个 UNIX 用户。该用户的名称无需与 Windows 用户名匹配。
详情请访问: https://aka.ms/wslusers
.


MessageId=1011 SymbolicName=MSG_PRESS_A_KEY
Language=English
Press any key to continue...
.

Language=zh_CN
按任意键继续...
.


MessageId=1013 SymbolicName=MSG_INSTALL_ALREADY_EXISTS
Language=English
The distribution installation has become corrupted.
Please select Reset from App Settings or uninstall and reinstall the app.
.

Language=zh_CN
此发行版的实例已被损坏。
请在应用设置中重置该应用，或卸载并重新安装该应用。
.


MessageId=1014 SymbolicName=MSG_ENABLE_VIRTUALIZATION
Language=English
Please enable the Virtual Machine Platform Windows feature and ensure virtualization is enabled in the BIOS.
For information please visit https://aka.ms/enablevirtualization
.


MessageId=1015 SymbolicName=MSG_LOCALE_ACQUIRSION_FAILURE
Language=English
WARNING: Failed to acquire current locale name. Falling back to en_US.
.

Language=zh_CN
警告：无法获取当前的系统语言信息。将使用默认值 en_US。
.
