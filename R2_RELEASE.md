# RetreatUI R2 release process

Cloudflare R2 is the primary distribution source for RetreatUI Launcher 0.3.12 and later. GitHub Releases remain a fallback source, but GitHub Actions are not required for publishing new RetreatUI releases.

## Verified release PC configuration

The current release PC uses:

- AWS CLI profile: `retreatui-r2`
- R2 bucket: `retreatui-releases`
- R2 S3 endpoint: `https://f2f139a476f03851f203d52e399a8ffb.eu.r2.cloudflarestorage.com`
- Public distribution host: `https://pub-1f3b72d79f1d4138945f7bd13e131def.r2.dev`

Credentials remain in the local AWS CLI profile and are never committed to GitHub.

The following checks have been verified on the release PC:

- CoA package dry-run
- TBC package dry-run
- Launcher .NET build/package dry-run
- R2 read access
- R2 write access
- R2 metadata read-back
- R2 delete access
- Public CoA beta.19 asset access
- Public Launcher 0.3.12 executable and SHA-256 access
- TBC beta.16 GitHub fallback access

## Current live state

- CoA `1.1.7-beta.19` is served from R2.
- Launcher `0.3.12` is served from R2.
- TBC `0.1.0-beta.16` is currently obtained through the verified GitHub Releases fallback.
- The next TBC release should be published to R2 using the process below.

## Read-only pre-flight

This verifies the current distribution state without modifying R2:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-R2.ps1
```

Expected result:

```text
R2 PRE-FLIGHT PASSED
```

## Isolated R2 write test

This writes a random object only below `_healthchecks/`, reads it back, and deletes it again. It never touches release files or feeds.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-R2-Write.ps1
```

Expected result:

```text
R2 WRITE TEST PASSED
```

## Package-only validation

`tools/Publish-R2.ps1` remains the validated package builder. Always use `-DryRun` when invoking it directly.

CoA:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Publish-R2.ps1 -Product CoA -DryRun
```

TBC:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Publish-R2.ps1 -Product TBC -DryRun
```

Launcher:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Publish-R2.ps1 -Product Launcher -DryRun
```

The package builder validates source version metadata, required addon folders/files, launcher executable version and SHA-256 generation. No R2 object is changed in dry-run mode.

## Live R2 publish

The canonical live publisher is:

`tools/Publish-R2-Live.ps1`

It first invokes the validated package builder, then uses the existing AWS CLI profile to publish to R2.

### CoA

After the new version has been merged to `RetreatUI/RetreatUI-Addon` and its release manifest/version files agree:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Publish-R2-Live.ps1 -Product CoA
```

Objects are stored as:

```text
addons/coa/<version>/RetreatUI_v<version>.zip
addons/coa/<version>/RetreatUI_v<version>.zip.sha256
```

### TBC

After the new version has been merged to `RetreatUI/RetreatUI-TBC`:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Publish-R2-Live.ps1 -Product TBC
```

Objects are stored as:

```text
addons/tbc/<version>/RetreatUI_TBC_v<version>.zip
addons/tbc/<version>/RetreatUI_TBC_v<version>.zip.sha256
```

### Launcher

After the launcher project version has been bumped and merged to `RetreatUI/RetreatUI-Launcher`:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Publish-R2-Live.ps1 -Product Launcher
```

The .NET 8 SDK is required. Objects are stored as:

```text
launcher/<version>/RetreatUI_Launcher.exe
launcher/<version>/RetreatUI_Launcher.exe.sha256
```

## Publish safety order

The live publisher follows this order:

1. Download the requested GitHub ref (`main` by default).
2. Build and validate the package locally.
3. Verify AWS profile/bucket access.
4. Refuse to reuse an existing immutable release object unless disaster-recovery `-Force` is explicitly supplied.
5. Load the current live feed before modifying anything.
6. Upload the release asset and SHA-256.
7. Verify both through the public R2 hostname.
8. Upload a timestamped backup of the old feed under `feed/backups/`.
9. Build the new merged feed.
10. Upload the live feed **last**.
11. Read the live feed back and verify the new release is visible.
12. Update the local GitHub fallback feed mirror.

A failure before the live-feed upload cannot advertise a half-published release.

## Feed layout

Addon releases share:

```text
feed/addon-releases.json
```

The launcher differentiates CoA and TBC by asset naming:

- CoA: `RetreatUI_v...zip`
- TBC: `RetreatUI_TBC_v...zip`

Launcher self-update uses:

```text
feed/launcher-releases.json
```

## Optional GitHub fallback mirror push

After R2 has been published and verified, the publisher updates the matching local `feed/*.json` mirror. To also commit and push that mirror without GitHub Actions:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Publish-R2-Live.ps1 -Product CoA -PushGitHubMirror
```

Use `TBC` or `Launcher` as required.

Failure of the optional GitHub mirror push does not invalidate an already verified R2 release.

## Rules

- Never reuse a normal release version.
- Never use `-Force` for a routine release.
- Never publish a version until source metadata and package versions agree.
- Never manually update the live feed before its release assets are publicly reachable.
- Keep addon author metadata as `Retreat`.
- Do not store R2 credentials, AWS secrets or access keys in GitHub.
