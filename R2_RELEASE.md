# RetreatUI R2 release process

Cloudflare R2 is the primary distribution source used by RetreatUI Launcher 0.3.12 and later. GitHub Releases/raw feed remain fallback sources only.

The release PC already uses:

- AWS CLI profile: `retreatui-r2`
- R2 bucket: `retreatui-releases`
- Public R2 host: `https://pub-1f3b72d79f1d4138945f7bd13e131def.r2.dev`

No Cloudflare access key or secret is stored in this repository.

## Tools

### `tools/Publish-R2.ps1`

Validated package builder. It downloads the requested source ref, validates release metadata and addon versions, creates the correct package, builds Launcher when needed, and creates the SHA-256 checksum.

Use this with `-DryRun` when checking package/build integrity only.

### `tools/Publish-R2-Live.ps1`

Production publisher. It first invokes the validated package builder above, then uses the existing AWS CLI R2 profile to publish the resulting files.

The production publish order is deliberately fail-safe:

1. Build and validate the package.
2. Verify AWS CLI access to the R2 bucket.
3. Refuse to reuse an existing immutable release object/version.
4. Download the current live feed.
5. Upload the release asset and SHA-256 checksum.
6. Verify both files through the public R2 hostname.
7. Upload a timestamped backup of the existing feed.
8. Merge the new release into the feed.
9. Upload the live feed **last**.
10. Read the live feed back and verify the new release is visible.
11. Update the local GitHub fallback feed mirror; optional normal `git push` does not require GitHub Actions.

If anything fails before the live-feed upload, users cannot see a half-published release.

### `tools/Test-R2.ps1`

Read-only pre-flight test. It verifies the current live architecture without changing any R2 object.

### `tools/Test-R2-Write.ps1`

Isolated write/read/delete permission test. It creates a random object below `_healthchecks/`, reads its metadata back, and deletes it again. It never touches release assets or release feeds.

## One-time requirements on the release PC

- Windows PowerShell 5.1 or PowerShell 7.
- AWS CLI with the `retreatui-r2` profile already configured.
- For Launcher builds: .NET 8 SDK.
- Git is optional and only needed for `-PushGitHubMirror`.

Node.js and Wrangler are not required for the production AWS CLI release path.

## Pre-flight checks

Read-only live check:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-R2.ps1
```

Safe write/read/delete permission check:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-R2-Write.ps1
```

## Package dry runs

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

## Publish CoA

After the intended CoA release is merged to `RetreatUI/RetreatUI-Addon` and its release manifest/version files contain the new version:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Publish-R2-Live.ps1 -Product CoA
```

Immutable objects are stored as:

`addons/coa/<version>/RetreatUI_v<version>.zip`

## Publish TBC

After the intended TBC release is merged to `RetreatUI/RetreatUI-TBC`:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Publish-R2-Live.ps1 -Product TBC
```

Immutable objects are stored as:

`addons/tbc/<version>/RetreatUI_TBC_v<version>.zip`

TBC beta.16 predates this migration and is currently supplied by the verified GitHub Releases fallback. The next TBC version should be published through R2 with this command.

## Publish Launcher

After the Launcher version is bumped and merged to `RetreatUI/RetreatUI-Launcher`:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Publish-R2-Live.ps1 -Product Launcher
```

Launcher objects are stored under:

`launcher/<version>/RetreatUI_Launcher.exe`

The live launcher feed requires both `RetreatUI_Launcher.exe` and `RetreatUI_Launcher.exe.sha256`.

## Pin an exact source commit

`main` is the default. For an already-reviewed exact commit:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Publish-R2-Live.ps1 -Product CoA -Ref <commit-sha>
```

## GitHub fallback feed mirror

Every successful live R2 publish updates the matching `feed/*.json` in the local clone.

To also commit and push that fallback mirror with normal git, without GitHub Actions:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Publish-R2-Live.ps1 -Product CoA -PushGitHubMirror
```

Failure of the optional GitHub mirror push does not invalidate a release that has already passed R2 verification.

## Safety rules

- Never reuse a normal release version number.
- Existing immutable R2 objects abort the release by default.
- `-Force` is disaster-recovery only.
- The live feed is always uploaded last.
- A timestamped feed backup is written before every feed change.
- Keep addon author metadata as `Retreat`; release tooling must never rewrite author fields.
