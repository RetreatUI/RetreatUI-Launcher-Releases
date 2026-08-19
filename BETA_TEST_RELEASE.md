# CoA beta test publishing

RetreatUI Launcher 0.3.12 supports prerelease addon builds through its existing **Include Beta** setting. A separate launcher binary is not required for normal CoA beta tests.

## beta.21 CoA test

Source branch:

```text
RetreatUI/RetreatUI-Addon
agent/beta21-coa-test
```

Publisher ref:

```text
refs/heads/agent/beta21-coa-test
```

Expected addon version:

```text
1.1.7-beta.21
```

The source `.github/release-manifest.json` must contain `publish=true` and `prerelease=true` while the build is intended for launcher Beta testing.

## Publish from the verified release PC

Run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Publish-CoA-Test.ps1
```

The CoA test publisher builds the requested branch with the validated package builder, checks the R2 package/checksum state, uploads missing objects, backs up the current feed, then publishes `feed/addon-releases.json` last.

If a previous run was interrupted after the package and checksum were uploaded but before the feed was updated, the script detects that partial state and resumes at feed publication instead of requiring a new version.

After the publish succeeds, enable **Beta** in RetreatUI Launcher and check for updates.

## Safety rules

- Never use this helper with `main` or `refs/heads/main`.
- The test branch manifest must remain `publish=true` and `prerelease=true` while it is intended for launcher testing.
- The live feed is always uploaded last.
- Stable remains untouched until the in-game Vol'jin test is accepted.
