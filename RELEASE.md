# Release AOSC OS on WSL

## Prerequisites

- Windows with Visual Studio 2026 and the **Desktop development with C++** workload.
- MSVC v145 x64 and ARM64 build tools and a Windows SDK. `release.ps1` discovers MSBuild with `vswhere` and selects the newest installed SDK.
- Windows `tar.exe`, Git, and GitHub CLI (`gh`).
- The two WSL images and their `.sha256sum` files in the repository root. These files are local release inputs and must not be committed.
- For GitHub publication, `gh auth login` with permission to push to `AOSC-Dev/AOSCOSLauncher` and create releases.
- For Store submission, a Partner Center application registration with the Manager role, its tenant ID, client ID, and client secret, and the existing Store app ID.

The existing Store entry is `9NMDF21NV65Z`. Its package identity is `20470KexyBiscuit.AOSCOSonWSL`, and its publisher is `CN=7A0EF4AF-D8E1-463F-A051-23A700957CE2`. Do not change either identity when releasing an update.

## Inputs and versioning

The current release uses:

```text
aosc-os_wsl_20261017_amd64.wsl
aosc-os_wsl_20261017_amd64.wsl.sha256sum
aosc-os_wsl_20261017_arm64.wsl
aosc-os_wsl_20261017_arm64.wsl.sha256sum
```

For another release, pass different paths with `-Amd64Image` and `-Arm64Image`, and set `-ExpectedVersion` to the expected rootfs `VERSION_ID`.

The script verifies each image against its checksum before building. It reads `/etc/os-release` directly from both rootfs images, requires both versions to match `ExpectedVersion`, and appends `.0` to form the four-part Appx version. For this release, `14.0.0` becomes `14.0.0.0` in `AOSCOSLauncher-Appx/AOSCOS.appxmanifest`.

The images are staged as `x64/install.tar.gz` and `ARM64/install.tar.gz`, matching the paths in the Appx project.

## Clean build

From the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\release.ps1
```

A release build must use this default clean mode. `-SkipClean` is available for diagnosis, but its outputs must not be published.

The script performs the complete local release:

1. Verify both SHA-256 hashes and rootfs versions.
2. Set the Appx manifest version and generate Store association metadata if it is missing.
3. Locate or generate a current-user certificate matching the existing Store publisher.
4. Build Release x64 and ARM64 launchers and signed architecture packages.
5. Verify each package's architecture, version, launcher, embedded rootfs hash, signer, and signature integrity.
6. Create and sign a combined Store bundle and verify its contents.
7. Package the complete toolchain-generated x64 and ARM64 `_Test` folders as ZIPs, including `Install.ps1`, the signed `.appx`, and the matching public `.cer`.
8. Require each GitHub asset to be strictly smaller than 2 GiB and write `SHA256SUMS` with LF line endings.

The generated `Package.StoreAssociation.xml` is local metadata based on the existing Store identity; it is ignored by Git. No wizard UI or server-side association change is needed for an already associated app. Visual Studio's `_ValidateSigningCertificate` MSBuild target generates a publisher-matching certificate when no valid one exists. The private key remains in the current-user certificate store and is not exported by the release script.

The certificate is self-signed. Signature verification accepts only the expected untrusted-root result after checking the signer thumbprint and package integrity; hash or signer failures remain fatal. For sideloading, extract the architecture-specific ZIP and run `Install.ps1`. The toolchain script offers to install the included certificate into `TrustedPeople` before installing the signed package.

## Artifacts

Artifacts are written to `artifacts/release/14.0.0.0/`:

```text
AOSCOS_14.0.0.0_Store_x64_ARM64.appxbundle
AOSCOSLauncher-Appx_14.0.0.0_x64_Test.zip
AOSCOSLauncher-Appx_14.0.0.0_arm64_Test.zip
SHA256SUMS
```

The Store bundle contains both architectures. Only the two architecture-specific sideload ZIPs and `SHA256SUMS` are GitHub release assets.

Verify the GitHub assets from Git Bash:

```bash
cd artifacts/release/14.0.0.0
sha256sum -c SHA256SUMS
```

## Commit, tag, and GitHub release

Review the diff and ensure that no WSL images, build outputs, association files, certificates, or credentials are staged. Commit only the release automation, documentation, and intended packaging changes:

```powershell
git add .gitignore README.md RELEASE.md release.ps1 submit-store.ps1 AOSCOSLauncher-Appx/AOSCOS.appxmanifest
git commit -m "Release AOSC OS 14.0.0"
git push origin main
git tag v14.0.0
git push origin v14.0.0
```

Create the public release with generated notes:

```powershell
gh release create v14.0.0 `
  artifacts/release/14.0.0.0/AOSCOSLauncher-Appx_14.0.0.0_x64_Test.zip `
  artifacts/release/14.0.0.0/AOSCOSLauncher-Appx_14.0.0.0_arm64_Test.zip `
  artifacts/release/14.0.0.0/SHA256SUMS `
  --title "AOSC OS on WSL 14.0.0" `
  --generate-notes `
  --repo AOSC-Dev/AOSCOSLauncher
```

Verify the remote release, its assets, and their sizes:

```powershell
gh release view v14.0.0 --repo AOSC-Dev/AOSCOSLauncher --json url,isDraft,assets
```

Download the release into a separate directory and rerun `sha256sum -c SHA256SUMS` there to verify the uploaded bytes.

## Microsoft Store submission

The Store submission API can update an existing app; it cannot reserve a new app name or replace the initial app-creation steps. Partner Center credentials are read from `STORE_TENANT_ID`, `STORE_CLIENT_ID`, and `STORE_CLIENT_SECRET`. Supply them through a secret manager or the current process environment, never through repository files or logged command arguments.

Submit only the combined bundle:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\submit-store.ps1 `
  -StoreBundle artifacts/release/14.0.0.0/AOSCOS_14.0.0.0_Store_x64_ARM64.appxbundle
```

The submission script creates a new submission from the current Store metadata, marks old packages for deletion, adds the combined bundle, uploads a ZIP, commits it for certification, and verifies the remote status and package name. It streams the upload and never logs credentials or the signed upload URL. It does not wait for certification or Store availability.

If Partner Center already has a pending submission, the script stops rather than overwriting it. To resume a submission created for this release, add `-SubmissionId <id>` to the command. A failed upload or commit must be treated as an incomplete release, not reported as published.
