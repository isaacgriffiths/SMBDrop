# SMBDrop CI/CD

SMBDrop is developed on Windows. XcodeGen creates `SMBDrop.xcodeproj` on a
GitHub-hosted macOS runner, so generated Xcode project files are not committed.

## Repository configuration

The workflows use four GitHub repository variables:

| Variable        | Value                        |
| --------------- | ---------------------------- |
| `APP_PROJECT`   | `SMBDrop.xcodeproj`          |
| `APP_SCHEME`    | `SMBDrop`                    |
| `APP_BUNDLE_ID` | `com.isaacgriffiths.smbdrop` |
| `APP_TEAM_ID`   | `LKAFZ4ANSY`                 |

They also use six repository secrets:

- `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_P8` authenticate Fastlane with
  the App Store Connect API.
- `MATCH_GIT_URL`, `MATCH_PASSWORD`, and
  `MATCH_GIT_BASIC_AUTHORIZATION` allow Fastlane match to read and update the
  private `ios-certificates` repository.

To set all ten values without printing secret material, copy `.env.example` to
`.env.local`, complete it, and run:

```powershell
node scripts/set-apple-secrets.mjs
```

## First signing run

The Apple Developer portal must already contain both explicit App IDs and the
App Group attached to both:

- `com.isaacgriffiths.smbdrop`
- `com.isaacgriffiths.smbdrop.ShareExtension`
- `group.com.isaacgriffiths.smbdrop`

Run **Init signing (run once per app)**. It creates one App Store provisioning
profile for each target and stores both, encrypted, in `ios-certificates`.

```powershell
gh workflow run "Init signing (run once per app)" --repo isaacgriffiths/SMBDrop
gh run watch --repo isaacgriffiths/SMBDrop --exit-status
```

## Build and release

- `CI` generates the Xcode project and performs an unsigned simulator build.
- `Release to TestFlight` generates the project, installs both match profiles,
  archives the app with its embedded share extension, and uploads the build.
- GitHub's run number becomes `CFBundleVersion`; the app and extension share
  the same project-wide version settings, as Apple requires.

Release is manual until the first signing run succeeds. After that bootstrap,
the release workflow is configured to run for every push to `main` as well as
by manual dispatch.
