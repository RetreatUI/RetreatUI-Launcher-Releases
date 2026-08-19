# CoA beta test publishing

RetreatUI Launcher 0.3.12 already supports prerelease addon builds through its existing **Include Beta** setting. A separate launcher binary is not required for normal CoA beta tests.

## beta.21 Naowh CoA test

Source branch:

```text
RetreatUI/RetreatUI-Addon
agent/beta21-naowh-coa-test
```

Expected addon version:

```text
1.1.7-beta.21
```

The source `.github/release-manifest.json` must contain:

```json
{
  "publish": false,
  "version": "1.1.7-beta.21",
  "prerelease": true
}
```

`publish=false` prevents the old GitHub Actions release path from being treated as authoritative. The R2 publisher reads the same version/prerelease metadata when building the launcher feed.

## Publish from the verified release PC

Run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Publish-CoA-Test.ps1
```

To publish a different test branch:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Publish-CoA-Test.ps1 -Ref agent/my-coa-test-branch
```

The helper delegates to the validated `Publish-R2-Live.ps1` workflow, which packages the requested GitHub ref, uploads the immutable ZIP and checksum to R2, verifies the public objects, and updates `feed/addon-releases.json` last.

After the publish succeeds, testers can enable **Beta** in RetreatUI Launcher and the launcher will choose the highest compatible CoA prerelease version.

## Safety rules

- Never use this helper with `main`.
- The test branch manifest must remain `prerelease=true`.
- Do not manually edit the live feed before the R2 package and checksum are publicly reachable.
- Never reuse an existing beta version.
- Stable remains untouched until the in-game Vol'jin test is accepted.
