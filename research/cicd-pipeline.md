# CI/CD pipeline and conventions mined from Isaac's existing iOS repos

Resolves [#2](https://github.com/isaacgriffiths/SMBDrop/issues/2). Researched 2026-08-23 against
primary sources: the `isaacgriffiths/ios-app-base` template repo (via `gh api`), the
`isaacgriffiths/ios-certificates` match store (structure only), GitHub Actions secrets/variables
(`gh secret list` / `gh variable list`) on `product-ai-app`, `crossfeed`, `flipdash`, `GYMIT`,
`ios-app-base`, and local working copies at `C:\Users\Isaac\Documents\GitHub\product-ai-app`,
`C:\Users\Isaac\Documents\GitHub\ios social media manager` (Crossfeed) and
`C:\Users\Isaac\Documents\GitHub\GYMIT`.

## TL;DR

Copy the **Crossfeed** generation of the pipeline (it is the newest and fixes a latent bug in the
`ios-app-base` template), extend the `match`/`build_app` calls to a two-identifier array for the
share extension, and set 6 secrets + 4 variables on the SMBDrop repo. Everything runs on GitHub's
`macos-15` runners — no Mac is ever needed, including first-time signing (`init-signing.yml`).
Apple-portal work (bundle IDs, App Group, app record) is browser-only and also needs no Mac.

## 1. How the proven pipeline works (lineage)

Three generations exist; use the newest:

1. **`ios-app-base`** (template repo, root: `Gemfile`, `fastlane/{Fastfile,Appfile,Matchfile}`,
   `.github/workflows/{init-signing.yml,release.yml}`, `CICD_SETUP.md`, `README.md`). Defines the
   model: push to `main` → `macos` runner → fastlane `match` (readonly) → `build_app` →
   `upload_to_testflight`. Signing assets are created once by a manually-dispatched
   `init-signing.yml` running the `init_signing` lane (`match` with `readonly: false`).
2. **`product-ai-app` (ProductShot)** — template copy plus `update_code_signing_settings` (force
   Manual signing on CI; automatic signing fails on a headless runner). Still uses top-level
   `ENV.fetch` constants in the Fastfile.
3. **`crossfeed` (local: `ios social media manager`)** — the reference implementation. Its Fastfile
   comment documents and fixes a latent template bug: *top-level constants are evaluated when the
   Fastfile is parsed for every lane*, so `ENV.fetch("APP_PROJECT")` at file scope makes
   `init_signing` die even though that lane only needs the bundle id. Crossfeed wraps every env
   read in a method. It also adds `ci.yml` (signing-free compile check — the only compiler
   feedback that exists when developing on Windows) and injects backend config
   (`SUPABASE_URL`/`SUPABASE_ANON_KEY`) as `xcargs` build settings surfaced through Info.plist.

`GYMIT` never adopted the pipeline: it has only simulator-build CI workflows (`ci.yml`,
`swift.yml`), no fastlane directory, and **zero** repo secrets/variables. Nothing to mine there
beyond confirming the `CODE_SIGNING_ALLOWED=NO` simulator-build CI pattern.

### The match store: `isaacgriffiths/ios-certificates`

Private repo used by every app (`storage_mode "git"`). Structure (names only):
`certs/distribution/` (one shared Apple Distribution certificate, encrypted with
`MATCH_PASSWORD`), `profiles/appstore/AppStore_<bundle-id>.mobileprovision` (one per app —
currently `com.claudewithisaac.crossfeed` and `com.claudewithisaac.productshot`),
`match_version.txt`. SMBDrop's `init_signing` run will add
`AppStore_com.isaacgriffiths.smbdrop.mobileprovision` and
`AppStore_com.isaacgriffiths.smbdrop.ShareExtension.mobileprovision` here. The distribution
**certificate is shared and already exists**, so init-signing for SMBDrop only mints profiles.

## 2. Exact file set to scaffold for SMBDrop

```
Gemfile
fastlane/Appfile
fastlane/Matchfile
fastlane/Fastfile
.github/workflows/ci.yml
.github/workflows/init-signing.yml
.github/workflows/release.yml
CICD_SETUP.md            (optional doc; content = ios-app-base CICD_SETUP.md adapted)
```

### `Gemfile` (identical in every repo; no Gemfile.lock is committed)

```ruby
source "https://rubygems.org"

gem "fastlane"
```

### `fastlane/Appfile`

```ruby
app_identifier(ENV["APP_BUNDLE_ID"])
# Authentication is handled by the App Store Connect API key in the Fastfile,
# so no apple_id / team_id is needed here.
```

### `fastlane/Matchfile`

```ruby
git_url(ENV["MATCH_GIT_URL"])
storage_mode("git")
type("appstore")
# app_identifier and api_key are passed per-lane from the Fastfile.
```

### `fastlane/Fastfile` (Crossfeed pattern, extended for the share extension)

```ruby
default_platform(:ios)

# Env reads are methods, NOT top-level constants: constants are evaluated when
# the Fastfile is parsed for every lane, which makes init_signing die on a
# missing APP_PROJECT even though that lane never builds anything.
# (Latent bug in the ios-app-base template, fixed in Crossfeed.)
def project_path  = ENV.fetch("APP_PROJECT")     # "SMBDrop.xcodeproj"
def scheme_name   = ENV.fetch("APP_SCHEME")      # "SMBDrop"
def bundle_id     = ENV.fetch("APP_BUNDLE_ID")   # "com.isaacgriffiths.smbdrop"

# NEW for SMBDrop: the share extension is a second signed target with its own
# bundle id and its own provisioning profile.
def extension_bundle_id = "#{bundle_id}.ShareExtension"
def all_bundle_ids      = [bundle_id, extension_bundle_id]

def asc_api_key
  app_store_connect_api_key(
    key_id:      ENV.fetch("ASC_KEY_ID"),
    issuer_id:   ENV.fetch("ASC_ISSUER_ID"),
    key_content: ENV.fetch("ASC_KEY_P8"),
    is_key_content_base64: false
  )
end

platform :ios do
  desc "Build, sign, and upload a new build to TestFlight"
  lane :release do
    setup_ci # ephemeral keychain on the runner

    key = asc_api_key

    match(
      type: "appstore",
      app_identifier: all_bundle_ids,   # match accepts an array; one profile per id
      api_key: key,
      readonly: true
    )

    increment_build_number(
      xcodeproj: project_path,
      build_number: ENV.fetch("GITHUB_RUN_NUMBER", "1")
    )

    team = ENV.fetch("APP_TEAM_ID")

    # Force manual signing per target — automatic signing fails on a headless
    # runner. update_code_signing_settings must run once per target because
    # profile_name differs.
    update_code_signing_settings(
      path: project_path, use_automatic_signing: false, team_id: team,
      targets: ["SMBDrop"],
      code_sign_identity: "Apple Distribution",
      profile_name: "match AppStore #{bundle_id}"
    )
    update_code_signing_settings(
      path: project_path, use_automatic_signing: false, team_id: team,
      targets: ["ShareExtension"],
      code_sign_identity: "Apple Distribution",
      profile_name: "match AppStore #{extension_bundle_id}"
    )

    build_app(
      project: project_path,
      scheme: scheme_name,           # app scheme embeds the extension
      export_method: "app-store",
      xcargs: "DEVELOPMENT_TEAM=#{team}",
      export_team_id: team,
      export_options: {
        provisioningProfiles: {
          bundle_id           => "match AppStore #{bundle_id}",
          extension_bundle_id => "match AppStore #{extension_bundle_id}"
        }
      }
    )

    upload_to_testflight(api_key: key, skip_waiting_for_build_processing: true)
  end

  desc "One-time: create/refresh distribution cert + provisioning profiles"
  lane :init_signing do
    match(
      type: "appstore",
      app_identifier: all_bundle_ids,
      api_key: asc_api_key,
      readonly: false
    )
  end
end
```

Notes on deviations from the single-target originals — this is the entire multi-target delta:

- `app_identifier` becomes an **array** in both lanes (single-target repos pass one string).
- `update_code_signing_settings` runs **twice**, scoped with `targets:`, because the extension
  needs `profile_name: "match AppStore com.isaacgriffiths.smbdrop.ShareExtension"`. The
  single-target repos scope with `bundle_identifier:` instead; `targets:` is more robust here.
- `export_options.provisioningProfiles` gets **two entries** (one per bundle id).
- Nothing else changes: one `build_app` of the app scheme archives and embeds the extension, and
  `increment_build_number` (agvtool) bumps `CURRENT_PROJECT_VERSION` project-wide, keeping app and
  extension `CFBundleVersion` in lockstep — Apple requires the embedded extension's version to
  match the app's, so both targets must use `VERSIONING_SYSTEM = apple-generic` with
  `CURRENT_PROJECT_VERSION` (see §6).

### `.github/workflows/release.yml` (Crossfeed version verbatim, minus the Supabase pair)

```yaml
name: Release to TestFlight
on:
  push:
    branches: [main]
  workflow_dispatch:
concurrency:
  group: testflight
  cancel-in-progress: false
jobs:
  testflight:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: latest-stable
      - name: Set up Ruby + cache fastlane
        uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.3"
          bundler-cache: true
      - name: Build, sign & upload to TestFlight
        run: bundle exec fastlane release
        env:
          APP_PROJECT:   ${{ vars.APP_PROJECT }}
          APP_SCHEME:    ${{ vars.APP_SCHEME }}
          APP_BUNDLE_ID: ${{ vars.APP_BUNDLE_ID }}
          APP_TEAM_ID:   ${{ vars.APP_TEAM_ID }}
          ASC_KEY_ID:    ${{ secrets.ASC_KEY_ID }}
          ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
          ASC_KEY_P8:    ${{ secrets.ASC_KEY_P8 }}
          MATCH_GIT_URL:                 ${{ secrets.MATCH_GIT_URL }}
          MATCH_PASSWORD:                ${{ secrets.MATCH_PASSWORD }}
          MATCH_GIT_BASIC_AUTHORIZATION: ${{ secrets.MATCH_GIT_BASIC_AUTHORIZATION }}
```

### `.github/workflows/init-signing.yml` (Crossfeed version verbatim)

`workflow_dispatch` only; `runs-on: macos-15`; ruby/setup-ruby with `ruby-version: "3.3"` and
`bundler-cache: true`; single step `bundle exec fastlane init_signing` with env
`APP_BUNDLE_ID` (var) + `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `MATCH_GIT_URL`,
`MATCH_PASSWORD`, `MATCH_GIT_BASIC_AUTHORIZATION` (secrets). No `APP_PROJECT`/`APP_SCHEME` —
which is exactly why the Fastfile must read env inside lane methods, not at file scope.

### `.github/workflows/ci.yml` (Crossfeed pattern — the only compiler feedback on Windows)

```yaml
name: CI
on:
  push: { branches: [main] }
  pull_request:
  workflow_dispatch:
jobs:
  build:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - uses: maxim-lobanov/setup-xcode@v1
        with: { xcode-version: latest-stable }
      - name: Build SMBDrop
        run: |
          set -o pipefail
          xcodebuild \
            -project SMBDrop.xcodeproj \
            -scheme SMBDrop \
            -destination 'generic/platform=iOS Simulator' \
            CODE_SIGNING_ALLOWED=NO \
            build
```

Crossfeed's ci.yml treats a red run as a broken build, not flakiness — same policy applies.

## 3. Full secrets/vars list and where each value comes from

Observed live on `product-ai-app`, `crossfeed`, `flipdash` (`gh secret list` / `gh variable list`).
GYMIT and ios-app-base have none set.

### Repository **Variables** (not secret)

| Name | SMBDrop value | Source |
|---|---|---|
| `APP_PROJECT` | `SMBDrop.xcodeproj` | chosen at scaffold time |
| `APP_SCHEME` | `SMBDrop` | chosen at scaffold time |
| `APP_BUNDLE_ID` | `com.isaacgriffiths.smbdrop` | ticket #1 decision |
| `APP_TEAM_ID` | `LKAFZ4ANSY` | **recoverable**: same value on every existing repo's variables |

### Repository **Secrets**

| Name | What it is | Recoverable? |
|---|---|---|
| `MATCH_GIT_URL` | HTTPS URL of the certs repo | **Yes** — `https://github.com/isaacgriffiths/ios-certificates` (known repo; also stored as a secret on 3 repos) |
| `MATCH_GIT_BASIC_AUTHORIZATION` | base64 of `isaacgriffiths:<PAT>` | **Yes, derivable locally** — `GITHUB_PAT` and `GITHUB_USERNAME` are filled in `C:\Users\Isaac\Documents\GitHub\ios social media manager\.env.local`; Crossfeed's `scripts/set-apple-secrets.mjs` derives and uploads it without the PAT touching a terminal/transcript (reuse that script) |
| `MATCH_PASSWORD` | match encryption passphrase (shared across all apps) | **Isaac must supply** — password manager only; the `MATCH_PASSWORD=` line in Crossfeed's `.env.local` is empty. Same passphrase every repo uses (docs: "same one product-ai-app uses") |
| `ASC_ISSUER_ID` | App Store Connect API issuer UUID (team-level, same for all keys) | **Yes** — filled in `C:\Users\Isaac\Documents\GitHub\ios social media manager\.env.local` (`ASC_ISSUER_ID=`) |
| `ASC_KEY_ID` | ASC API key ID | **Probably** — a team key `.p8` exists locally at `C:\Users\Isaac\Documents\GitHub\flipdash\AuthKey_C9752W9BM5.p8` ⇒ key ID `C9752W9BM5`. ASC team keys work for any app in the team, so if that key is still active it can serve SMBDrop. Cannot verify from here that it matches the key IDs stored in crossfeed/product-ai-app secrets; if revoked, Isaac generates a fresh App-Manager key (`.p8` downloadable exactly once) |
| `ASC_KEY_P8` | full contents of the `.p8` incl. BEGIN/END lines (not base64) | Same as above — file contents at the flipdash path, else Isaac downloads a new key |

Not needed by SMBDrop (app-specific extras on other repos, listed for completeness):
`OPENAI_API_KEY` (product-ai-app), `SUPABASE_URL`/`SUPABASE_ANON_KEY` (crossfeed). If SMBDrop
ever needs client-visible backend config, Crossfeed's pattern is the precedent: pass it as
`xcargs` build settings in the release lane and surface it via `$(VAR)` placeholders in
Info.plist read by an `AppConfig` enum, with placeholder values in ci.yml.

**Convention worth copying:** Crossfeed's `scripts/set-apple-secrets.mjs` reads `.env.local`,
validates `ASC_ISSUER_ID` is UUID-shaped, sets the secrets with `gh secret set`, derives
`MATCH_GIT_BASIC_AUTHORIZATION` from `GITHUB_PAT`, prints a checklist of which of the required
secrets exist, and with `--ship` triggers init-signing then release. Adapting it (drop the
Supabase pair) gives SMBDrop one-command secret setup.

## 4. How `init-signing.yml` bootstraps signing for a NEW app id

1. Isaac sets the 4 variables + 6 secrets, then dispatches **"Init signing (run once per app)"**
   from the Actions tab (or `gh workflow run`).
2. The runner executes `bundle exec fastlane init_signing` → `match(type: "appstore",
   readonly: false, api_key: <ASC key>)`. match clones `ios-certificates` (via
   `MATCH_GIT_URL` + `MATCH_GIT_BASIC_AUTHORIZATION`), decrypts with `MATCH_PASSWORD`, reuses the
   existing shared Apple Distribution certificate, creates an App Store provisioning profile for
   each `app_identifier`, encrypts and pushes them back to the certs repo.
3. `release.yml` thereafter runs `match` with `readonly: true` — it only consumes.

**Hard-won caveats recorded in the Crossfeed Fastfile (primary source, comments at the
`init_signing` lane):**

- **match does not create the Bundle ID.** `produce`/`create_app_online` authenticates with an
  Apple ID and rejects `api_key`, so it cannot run on a headless runner. Crossfeed created the
  Bundle ID with a direct **`POST /v1/bundleIds`** call on the App Store Connect API (a
  `scripts/register-app.mjs` referenced in the comment; since deleted after use). For SMBDrop,
  **two** bundle IDs must exist before init-signing: `com.isaacgriffiths.smbdrop` and
  `com.isaacgriffiths.smbdrop.ShareExtension`. Either repeat the API call or click them in at
  developer.apple.com (browser-only, works from Windows).
- **The App Store Connect *app record* has no creation API at all** — it must be created once by
  hand (App Store Connect → Apps → +) before the first TestFlight upload. Only the app record for
  the main bundle id is needed; extensions don't get app records.
- The first TestFlight build needs the export-compliance question answered once in ASC before it
  is installable (`ITSAppUsesNonExemptEncryption=false` in Info.plist avoids this — Crossfeed
  sets it).

### SMBDrop-specific: App Group `group.com.isaacgriffiths.smbdrop`

New territory — no existing repo uses capabilities beyond plain app bundles, so nothing to copy.
What the pipeline implies:

- The App Group container and the APP_GROUPS capability on **both** bundle IDs must be configured
  in the Apple Developer portal **before** `init_signing` runs, so that the profiles match mints
  carry the app-group entitlement. Capability toggling exists on the ASC API
  (`POST /v1/bundleIdCapabilities`, type `APP_GROUPS`), but creating the group itself and
  assigning it to the bundle IDs is safest done once by hand in the portal web UI (browser-only —
  the no-Mac property is preserved).
- If the group or capability is added *after* profiles exist, re-run `init-signing.yml`
  (`readonly: false` regenerates the now-invalid profiles).
- Both targets' `.entitlements` files list `com.apple.security.application-groups` with
  `group.com.isaacgriffiths.smbdrop`.

## 5. Multi-target (share extension) signing implications — summary

- The extension is a separately-signed nested bundle: **its own bundle id**
  (`com.isaacgriffiths.smbdrop.ShareExtension` — must be prefixed by the app id) and **its own
  provisioning profile**. The shared Distribution certificate signs both.
- All four existing single-target lanes extend mechanically (shown in §2): array
  `app_identifier` in both `match` calls, a second `update_code_signing_settings` scoped by
  `targets:`, a second entry in `export_options.provisioningProfiles`. `ci.yml` needs no change
  (`CODE_SIGNING_ALLOWED=NO` covers all targets).
- Apple rejects archives where the extension's `CFBundleVersion`/`CFBundleShortVersionString`
  differ from the app's. Because `increment_build_number` is project-wide agvtool, both targets
  stay in sync automatically **provided both** use `VERSIONING_SYSTEM = apple-generic` +
  `CURRENT_PROJECT_VERSION` and their Info.plists use the `$(CURRENT_PROJECT_VERSION)` /
  `$(MARKETING_VERSION)` placeholders (Crossfeed's `SupportFiles/Info.plist` is the exact model).

## 6. Bundle-id / env / project conventions observed

- **Bundle ids:** existing apps use `com.claudewithisaac.<lowercasename>` (crossfeed,
  productshot; flipdash is the older `com.wynbrothers.*`). SMBDrop starts a third prefix by
  Isaac's decision: `com.isaacgriffiths.smbdrop`. A prefix change costs nothing in this pipeline
  (the id is data in `APP_BUNDLE_ID`), it just needs fresh bundle-id registrations.
  Team: `LKAFZ4ANSY` everywhere.
- **Env names:** `APP_PROJECT`, `APP_SCHEME`, `APP_BUNDLE_ID`, `APP_TEAM_ID` (GitHub Variables);
  `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `MATCH_GIT_URL`, `MATCH_PASSWORD`,
  `MATCH_GIT_BASIC_AUTHORIZATION` (Secrets). Fastfile reads all of them with `ENV.fetch` inside
  lane-scoped methods.
- **Project layout (Crossfeed, the model):** `<App>.xcodeproj` at repo root; app sources under
  `<App>/` grouped `App/ Models/ Services/ ViewModels/ Views/ Design/`; a hand-written
  `SupportFiles/Info.plist` with `GENERATE_INFOPLIST_FILE = NO` and `$(...)` placeholders for
  everything build-setting-driven; shared scheme committed at
  `<App>.xcodeproj/xcshareddata/xcschemes/`; docs under `docs/`; helper scripts under `scripts/`
  (Node `.mjs`, run with plain `node`); `.env.example` committed, `.env.local` gitignored.
- **Build numbering:** GitHub run number = `CFBundleVersion`; `MARKETING_VERSION` manually bumped.
- **Workflow discipline:** `concurrency: group: testflight` so two releases never race a build
  number; ci.yml on push+PR, release.yml on push-to-main + manual dispatch.

## 7. Ruby / fastlane / runner versions

| Thing | ios-app-base (template) | product-ai-app | Crossfeed (newest) | Use for SMBDrop |
|---|---|---|---|---|
| Runner | `macos-14` | `macos-15` | `macos-15` | `macos-15` |
| Xcode | pinned `16.1` | latest-stable | `latest-stable` (setup-xcode action) | `latest-stable` |
| Ruby | `3.3` (ruby/setup-ruby@v1, `bundler-cache: true`) | `3.3` | `3.3` | `3.3` |
| fastlane | `gem "fastlane"` unpinned; no Gemfile.lock committed | same | same | same (lockfile resolved fresh per run) |
| Actions | checkout@v4, setup-xcode@v1, setup-ruby@v1 | same | same | same |

## 8. Open items for the scaffold ticket

1. Confirm whether `AuthKey_C9752W9BM5.p8` (flipdash dir) is still an active ASC team key; if so
   reuse it for `ASC_KEY_ID`/`ASC_KEY_P8`, else Isaac generates a new App-Manager key.
2. Isaac must supply `MATCH_PASSWORD` from his password manager (only non-recoverable value).
3. One-time browser work before init-signing: register both bundle IDs, create the App Group,
   attach APP_GROUPS to both IDs, create the ASC app record for `com.isaacgriffiths.smbdrop`.
4. Port `scripts/set-apple-secrets.mjs` (drop the Supabase checks) for one-command secret setup.
5. Ensure BOTH Xcode targets use `apple-generic` versioning with placeholder-driven Info.plists
   so agvtool keeps app and extension versions identical.
