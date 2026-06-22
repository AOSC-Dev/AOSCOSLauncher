# AGENTS.md — AOSCOSLauncher

## What this is

C++ WSL distro launcher for AOSC OS, forked from Microsoft's WSL-DistroLauncher reference implementation. Produces an `.appx` package that registers and launches an AOSC OS WSL distribution.

## Build

```
build.bat          # Debug|x64
build.bat rel      # Release|x64
build.bat clean    # Clean + Build (Debug)
build.bat clean rel # Clean + Build (Release)
```

Requires Visual Studio 2017/2019/2022 with MSBuild. Use the "Developer Command Prompt for Visual Studio" for best results. `build.bat` only builds x64; the solution also defines ARM64 configs but `build.bat` hardcodes `/p:Platform=x64`.

Output: `x64\<Debug|Release>\AOSCOSLauncher-Appx\`

## Architecture

Two Visual Studio projects in the solution `AOSCOSLauncher.sln`:

| Project | Purpose | Directory |
|---------|---------|-----------|
| `launcher` | The executable (`launcher.exe` → renamed to `aoscos.exe` via Appx) | `AOSCOSLauncher/` |
| `AOSCOSLauncher-Appx` | UWP packaging, manifest, assets, signing cert | `AOSCOSLauncher-Appx/` |

Entry point: `wmain()` in `AOSCOSLauncher/AOSCOSLauncher.cpp`. Flow:
1. Check WSL optional component installed
2. If distro not registered → `InstallDistribution()`: register, configure locale, create user
3. Parse args: (none) → launch shell, `install`, `run <cmd>`, `config --default-user <user>`

## Critical gotchas

- **DO NOT rename the `launcher` project** (`AOSCOSLauncher.vcxproj`). The `ProjectName` must stay `launcher` — the Appx project references `launcher.exe` as its dependency output.
- **Distribution name** (`DistributionInfo::Name = L"AOSCOS"` in `DistributionInfo.h`) must not change between versions. Changing it breaks upgrades for existing users.
- **Generated files** (in `.gitignore`): `AOSCOSLauncher/messages.rc`, `AOSCOSLauncher/messages.h`, `AOSCOSLauncher/MSG*.bin` — produced by the `mc` (message compiler) custom build step from `messages.mc`. Do not edit these directly; edit `messages.mc`.
- **Appx signing cert** (`AOSCOSLauncher-Appx_TemporaryKey.pfx`) is for testing only. For store publishing, associate with your Store identity via Visual Studio.

## Source structure

- `AOSCOSLauncher/AOSCOSLauncher.cpp` — main entry, command parsing, install logic
- `AOSCOSLauncher/DistributionInfo.{h,cpp}` — distribution name, user creation (`useradd`/`usermod`), UID query
- `AOSCOSLauncher/WslApiLoader.{h,cpp}` — dynamic loading of WSL API (`wslapi.dll`)
- `AOSCOSLauncher/Helpers.{h,cpp}` — user input, message printing
- `AOSCOSLauncher/messages.mc` — localized messages (English + zh_CN). Compiled to `.rc`/`.h` by `mc`.
- `AOSCOSLauncher-Appx/AOSCOS.appxmanifest` — UWP manifest, app identity, execution alias (`aoscos.exe`)

## Localization

Messages in `messages.mc` use Windows Message Compiler format. Currently supports English (`0x409`) and Chinese (`0x804`). When adding/changing messages, update both language sections.

## User creation distro-specifics

`DistributionInfo.cpp` runs AOSC OS–specific commands inside WSL:
- `useradd -m -s /bin/bash` — creates user
- `usermod -aG audio,cdrom,plugdev,video,wheel` — adds groups
- `passwd` — prompts for password (reads `locale.conf` first)

These may need adjustment if the distro's package paths or groups differ.

## Testing

No automated tests. Manual testing via sideloading the `.appx`:
1. Build with `build.bat` (or Visual Studio "Deploy Solution")
2. Double-click `x64\<config>\AOSCOSLauncher-Appx\*.appx` or run `Add-AppxPackage`
3. Launch from Start menu or run `aoscos.exe` from command line
4. To re-test registration: `wsl --unregister AOSCOS`

Developer Mode must be enabled in Windows Settings for sideloading.
