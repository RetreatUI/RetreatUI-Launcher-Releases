# RetreatUI R2 release process

This repository contains the release tool used when GitHub Actions is unavailable. Cloudflare R2 is the primary distribution source used by RetreatUI Launcher 0.3.12 and later; GitHub remains a fallback only.

## What the tool does

`tools/Publish-R2.ps1` performs the release in a fail-safe order:

1. Downloads the exact requested GitHub ref (`main` by default).
2. Reads the product version from the source release metadata.
3. Validates that packaged addon/version files agree.
4. Builds the launcher or creates the launcher-compatible addon ZIP.
5. Creates a SHA-256 checksum.
6. Authenticates to Cloudflare through Wrangler. No R2 secret is stored in this repository.
7. Uploads immutable release files to R2.
8. Verifies the files through the public R2 hostname.
9. Downloads and preserves the current live feed.
10. Uploads a timestamped feed backup.
11. Adds the new release to the feed and uploads the feed **last**.
12. Reads the live feed back and verifies that the launcher will be able to see the new asset.

If packaging or upload fails before step 11, the launcher feed is not changed.

## One-time setup on the release PC

- Windows PowerShell 5.1 or PowerShell 7.
- Node.js LTS, which supplies `npx`.
- For launcher builds only: .NET 8 SDK. You can instead pass an already built `RetreatUI_Launcher.exe` with `-ArtifactPath`.
- A Cloudflare account with write access to the RetreatUI R2 bucket.

The first real publish asks for the R2 bucket name and stores only the bucket name and public R2 URL in:

`%LOCALAPPDATA%\RetreatUI\release-config.json`

Wrangler handles Cloudflare authentication separately. No access key or secret is written to GitHub.

## Publish CoA

After the intended CoA release has been merged to `RetreatUI/RetreatUI-Addon` and `.github/release-manifest.json` contains the new version:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Publish-R2.ps1 -Product CoA
```

The package layout is validated as:

- `RetreatUI/`
- `RetreatUI_Classes/`
- `RetreatUI_BuffManager/`

Future immutable R2 objects use:

`addons/coa/<version>/RetreatUI_v<version>.zip`

## Publish TBC

After the intended TBC release has been merged to `RetreatUI/RetreatUI-TBC`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Publish-R2.ps1 -Product TBC
```

The package layout is validated as a single top-level `RetreatUI/` folder. Future immutable R2 objects use:

`addons/tbc/<version>/RetreatUI_TBC_v<version>.zip`

## Publish Launcher

To build the launcher directly from `RetreatUI/RetreatUI-Launcher` and publish it:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Publish-R2.ps1 -Product Launcher
```

To publish an already built executable instead:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Publish-R2.ps1 -Product Launcher -ArtifactPath C:\Path\To\RetreatUI_Launcher.exe
```

Launcher objects are stored under `launcher/<version>/`, matching the launcher's verified R2 path contract. Both the executable and `RetreatUI_Launcher.exe.sha256` are required in the feed.

## Dry run before a release

A dry run downloads, validates and packages the source without touching R2:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Publish-R2.ps1 -Product CoA -DryRun
```

Use `-Product TBC` or `-Product Launcher` for the other products.

## Pin an exact commit

`main` is the default source. To publish a specific already-reviewed commit instead:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Publish-R2.ps1 -Product CoA -Ref <commit-sha>
```

## GitHub fallback feed

After a successful R2 publish, the tool updates the matching `feed/*.json` file in a local clone of this repository. This keeps a ready-to-commit mirror of the live R2 feed.

To also commit and push that mirror automatically, without invoking GitHub Actions:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Publish-R2.ps1 -Product CoA -PushGitHubMirror
```

Failure of the optional GitHub mirror push does not roll back or invalidate a release that has already been successfully verified on R2.

## Safety rules

- Do not reuse an existing version number.
- Release objects are immutable by default; an existing asset or feed entry aborts the publish.
- `-Force` exists for disaster recovery only. Normal releases should never need it.
- The live feed is always updated after the release files have uploaded and passed public verification.
- Keep `RetreatUI` as addon author metadata; release tooling must never rewrite addon author fields.
