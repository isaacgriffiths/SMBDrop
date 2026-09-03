# SMBDrop

A free iOS app that sends photos, videos and files from an iPhone straight to your own SMB share (a NAS, a Windows or macOS shared folder, or a Samba server), and pulls files back again. No account, no cloud, no subscription, no analytics.

Website: [smbdrop.com](https://smbdrop.com/) · Support: [smbdrop.com/support](https://smbdrop.com/support.html) · Privacy: [smbdrop.com/privacy](https://smbdrop.com/privacy.html)

Requires iOS 17 or later and an SMB server reachable on your network. Builds ship to TestFlight on every push to `main`; the App Store listing is going through Apple's review at the time of writing.

## Why it exists

Getting a photo off an iPhone and onto a home server should be one tap in the share sheet. Most apps that do it want an account, a subscription, or a cloud relay in the middle. SMBDrop does the one job over the local network and keeps the original bytes intact.

## What it does

**Send**

- Pick photos and videos from Recents or any album, with multi-select and drag-to-select a range.
- Original quality. Live Photos send both halves, HEIC and video are never transcoded.
- Send any file through Apple's Files picker (iCloud Drive, On My iPhone, third-party providers).
- Share from any app through the iOS share sheet via the bundled Share Extension.
- Transfers survive backgrounding and interruption. On iOS 26 a send runs as a Continued Processing Task with progress in the Dynamic Island.

**Import**

- Browse a share's folders and download files onto the phone, one at a time.
- Imports are verified byte for byte, keep their modification time, and never overwrite a local file.
- Imported files land in Files under On My iPhone, and can be previewed, shared, saved to Photos, or sent on to another share.

**Setup**

- Enter a host, port and sign-in, then Find Shares lists the server's real disk shares so nobody has to type one. Typed share names were the dominant setup failure before this existed.
- Test Connection must pass against the exact current field values before Save is enabled.
- Passwords live only in the iOS Keychain. Everything else non-secret lives in the shared App Group.

## How it is built

| Area | Choice |
| --- | --- |
| UI | SwiftUI, iOS 17+, iPhone only |
| SMB | [AMSMB2](https://github.com/amosavian/AMSMB2) 4.0.3 (Swift wrapper over libsmb2), embedded once as a dynamic framework and shared with the extension |
| Project | [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`. The `.xcodeproj` is generated on the runner and never committed |
| CI | GitHub Actions on a macOS runner: build, unit tests, plus scripted checks on target wiring and a cross-process outbox probe |
| Release | Fastlane with `match` for signing, TestFlight upload on every push to `main`, a separate Linux-only workflow for App Store metadata and screenshots |
| Feedback | A small Cloudflare Worker (`feedback-worker/`) relays in-app feature requests to email via Resend |

The app is developed on Windows, where Xcode does not exist. The cloud Mac build in `.github/workflows/ci.yml` is the compiler feedback loop, which is why the CI does more than a typical build and why target configuration lives in a YAML file rather than a pbxproj.

## Architecture

```
SMBDrop/            Main app: Photos, Files, Import and Settings tabs
  Networking/       Connection test, share and folder listing, import service
  ViewModels/       Destination setup, photo library, transfer queue, imports
  Views/            SwiftUI screens, onboarding, settings, transfer activity
ShareExtension/     Share-sheet surface: destination chooser and inline send
Shared/             Code compiled into both targets
  Destination.swift, DestinationStore.swift, PasswordVault.swift
  Transfers/        Durable outbox, transfer worker, batch progress
SMBDropTests/       XCTest unit tests (64 test cases)
feedback-worker/    Cloudflare Worker behind Settings > Request a Feature
fastlane/           Lanes, match config, App Store metadata and screenshots
marketing/          Screenshot editor and App Review correspondence
scripts/            CI configuration checks and the secrets helper
```

The `gh-pages` branch holds the marketing site at smbdrop.com, deployed to Cloudflare Workers with GitHub Pages as a mirror.

### Transfer design

The durable outbox in the App Group is the backbone shared by the main app and the Share Extension. Every item is staged there before any network work starts, so a dismissed share sheet or a killed app never loses a file.

- Transfers run one item at a time. The main app drains the global queue in order; a foreground Share Extension drains only the batch the user just submitted.
- Each upload streams from a local file URL to a visible `smbdrop-<UUID>.partial` name on the share, verifies the byte count, then renames into place. The temporary name never starts with a dot, because Samba can carry the hidden attribute through the rename and make a successful upload vanish from Windows Explorer.
- If the exact filename already exists, that item stops and asks the user. SMBDrop never renames or overwrites.
- Every transfer is bound to a Destination ID and an export batch before upload, so one share's worker can never claim another share's files.
- Failed items stay visible with a friendly error and a retry button. Items queued behind them are not discarded.

`CONTEXT.md` is the project glossary and records these decisions in full. `CICD_SETUP.md` covers signing, secrets and the release pipeline.

## Building locally

You need a Mac with Xcode. The project file is generated, not checked in:

```bash
brew install xcodegen
xcodegen generate
open SMBDrop.xcodeproj
```

Run the unit tests from Xcode, or from the command line against any available simulator:

```bash
xcodebuild -project SMBDrop.xcodeproj -scheme SMBDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO test
```

Signing and TestFlight uploads need the repository variables and secrets described in `CICD_SETUP.md`. Copy `.env.example` to `.env.local` and run `node scripts/set-apple-secrets.mjs` to set them without printing secret material.

## Privacy

No account, no analytics, no tracking. Files and credentials go from the phone to the server and nowhere else. The only outbound call beyond the SMB connection is the optional feedback form, which sends the message the user typed plus app and iOS version numbers.

Third-party licence notices are in `SMBDrop/Resources/ThirdPartyNotices.txt`.
