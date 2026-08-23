# Research: SMB client library for iOS

**Ticket:** [#3 — Choose the SMB client library for iOS](https://github.com/isaacgriffiths/SMBDrop/issues/3)
**Date:** 2026-08-23
**Question:** Which SMB2/3 client library should SMBDrop (a free iOS app that uploads photos/videos/files from iPhone to a LAN SMB share, primarily via a share extension) build on?

## Recommendation

**Build on [AMSMB2](https://github.com/amosavian/AMSMB2)** (Swift wrapper over libsmb2), distributed as the dynamic framework its Package.swift already produces. It is the only candidate with full SMB 2.02–3.1.1 dialect coverage (including SMB3 signing/encryption), NTLMv2 + guest auth, a streaming upload API that fits share-extension memory limits, SwiftPM integration, and active maintenance. Licence is LGPL-2.1 — workable for a free closed-source App Store app via dynamic linking (details below). Fallback if LGPL is ever deemed unacceptable: MIT-licensed [SMBClient](https://github.com/kishikawakatsumi/SMBClient), at the cost of losing all SMB3 support.

## Candidates evaluated

### 1. AMSMB2 (amosavian/AMSMB2) — recommended

- **Licence: effectively LGPL-2.1.** GitHub's licence detection reports LGPL-2.1 ([repo API](https://api.github.com/repos/amosavian/AMSMB2)), and the [README](https://github.com/amosavian/AMSMB2) states it explicitly: the Swift source is MIT, but it links the vendored `libsmb2` (LGPL-2.1), "consequently the whole project becomes LGPL v2.1", and "You **must** link this library dynamically to your app if you intend to distribute your app on App Store."
- **SwiftPM / linking mechanics.** [Package.swift](https://raw.githubusercontent.com/amosavian/AMSMB2/master/Package.swift) declares a C target building libsmb2 from vendored source (`Dependencies/libsmb2`, a submodule) and — crucially — declares the `AMSMB2` product `type: .dynamic`. SwiftPM therefore embeds it as a dynamic framework, which is the mechanism that makes LGPL §6(b)'s relinking obligation satisfiable on iOS. No binary targets; everything builds from source.
- **Protocol coverage (via libsmb2):** SMB2/3 dialects 2.02, 2.10, 3.00, 3.02, 3.1.1; NTLMSSP (NTLMv2); optional Kerberos; SMB3 signing and encryption (AMSMB2 exposes `connectShare(name:encrypted:)`). Guest/anonymous works — AMSMB2's own README sample uses `URLCredential(user: "guest", password: "")`. Sources: [libsmb2 README](https://github.com/sahlberg/libsmb2), [AMSMB2 README](https://github.com/amosavian/AMSMB2), [AMSMB2.swift](https://github.com/amosavian/AMSMB2/blob/master/AMSMB2/AMSMB2.swift).
- **Upload API — streams from disk, progress ~every 1 MiB.** From [AMSMB2.swift](https://github.com/amosavian/AMSMB2/blob/master/AMSMB2/AMSMB2.swift) (class `SMB2Manager`, async/await + completion-handler overloads):
  - `uploadItem(at url: URL, toPath:progress:)` — opens an `InputStream` on the local file and streams it; never loads the whole file into memory. Doc comment: "With reporting progress on about every 1MiB."
  - `write(data:toPath:progress:)` for in-memory payloads.
  - `WriteProgressHandler = (@Sendable (_ bytes: Int64) -> Bool)?` — return `false` to cancel.
  - Plus `createDirectory(atPath:)`, `moveItem(atPath:toPath:)`, `attributesOfItem(atPath:)`, `copyItem`.
- **Maintenance:** latest release 4.0.3 (2025-08-13, Swift 6.2 compat + libsmb2 bump); 4.0.2 (2025-03-08, security patches); repo `pushed_at` 2026-05-30; 308 stars; 16 open issues ([releases API](https://api.github.com/repos/amosavian/AMSMB2/releases), [repo API](https://api.github.com/repos/amosavian/AMSMB2)).
- **Notable open bugs:** [#138](https://github.com/amosavian/AMSMB2/issues/138) (use-after-free / re-entrant teardown around request callbacks, open 2026-08) and [#136](https://github.com/amosavian/AMSMB2/issues/136) (crash in `generic_handler` on delayed CHANGE_NOTIFY response, open 2026-04). Both concern long-lived async watchers/teardown, **not the plain upload path**. Historical upload/memory issues (#79, #116, #124) are closed. No open share-extension-specific issues found.

### 2. libsmb2 directly (sahlberg/libsmb2)

LGPL-2.1 (dcerpc part BSD-2-Clause), extremely active (`pushed_at` 2026-08-23; 422 stars — [repo API](https://api.github.com/repos/sahlberg/libsmb2)). Full dialect range to 3.1.1, NTLMSSP/Kerberos, sync + async + raw-PDU APIs ([README](https://github.com/sahlberg/libsmb2)). But it is a raw C API: using it directly means re-implementing what AMSMB2 already wraps (Swift bridging, socket/run-loop pumping, credential plumbing) for the identical LGPL obligation. Only worth it if AMSMB2's wrapper bugs bite and can't be fixed upstream.

### 3. SMBClient (kishikawakatsumi/SMBClient) — MIT fallback

- **Licence: MIT** — zero copyleft; ideal for closed source ([repo API](https://api.github.com/repos/kishikawakatsumi/SMBClient)).
- **Dialects: SMB 2.0.2 and 2.1 only.** [Session.swift](https://github.com/kishikawakatsumi/SMBClient/blob/main/Sources/SMBClient/Session.swift) negotiates `[.smb202, .smb210]`. **No SMB 3.x → no SMB3 encryption**; a NAS/Windows server requiring SMB3 or encrypted shares will refuse it. This is the disqualifying risk for an app whose whole job is talking to arbitrary LAN shares.
- **Auth:** NTLMv2 yes; anonymous/guest yes (`login(username:password:)` accepts nil/empty, sets `isAnonymous`; release 0.3.1 disabled packet signing for anonymous login).
- **Upload:** `upload(localPath:remotePath:progressHandler:)` / `upload(fileHandle:path:progressHandler:)` truly stream — [FileWriter.swift](https://github.com/kishikawakatsumi/SMBClient/blob/main/Sources/SMBClient/FileWriter.swift) reads `maxWriteSize` (server-negotiated) per iteration with a `(Double) -> Void` progress handler. The `Data` variant holds the whole file in RAM — avoid in the extension.
- **SwiftPM:** yes; iOS 13+; pure Swift, no C code.
- **Maintenance:** last release 0.3.1 (2024-12-31); `pushed_at` 2026-04-27; 285 stars; 12 open issues. Alive but slower-moving and still 0.x.

### 4. Disqualified

- **TOSMBClient / libdsm** and **filmicpro/SMBClient** — SMB1 only; SMB1 is disabled by default on modern Windows/Samba/NAS.
- **alexiscn/libsmb** — merely a SwiftPM packaging of libsmb2; no wrapper value over AMSMB2.
- No other credible maintained Swift SMB library surfaced in searches.

## Share-extension viability

Both finalists keep memory flat: AMSMB2 `uploadItem(at:)` streams via `InputStream`; SMBClient streams via `FileHandle` reads. Neither uses extension-forbidden APIs in the upload path (no `UIApplication` dependency); both run I/O off the main thread (AMSMB2 on its own dispatch queue; SMBClient via async/await over its own socket). AMSMB2 ships as a dynamic framework — embed once, link from both the main app and the share extension (this is also what the licence requires).

**Red flags to design around (AMSMB2):** keep `SMB2Manager` lifetimes simple and avoid the change-notification / file-monitoring APIs until [#136](https://github.com/amosavian/AMSMB2/issues/136)/[#138](https://github.com/amosavian/AMSMB2/issues/138) are fixed — the crashes live in delayed-async-callback teardown, not in connect/mkdir/upload/rename. Stay inside the ~120 MB share-extension memory budget by always using `uploadItem(at:)` (file URL), never `write(data:)`, for media.

## Minimal usage sketch (AMSMB2, real API names)

```swift
import AMSMB2

let serverURL = URL(string: "smb://192.168.1.50")!            // README "Usage"
let credential = URLCredential(user: "isaac", password: "…",
                               persistence: .forSession)
let client = SMB2Manager(url: serverURL, credential: credential)!

// Connect + authenticate (guest: URLCredential(user: "guest", password: ""))
try await client.connectShare(name: "Photos", encrypted: false)

// Create the destination directory
try await client.createDirectory(atPath: "SMBDrop/2026-08-23")

// Chunked upload: streams from the file URL via InputStream,
// progress ~every 1 MiB; return false from the closure to cancel.
try await client.uploadItem(at: localVideoURL,
                            toPath: "SMBDrop/2026-08-23/IMG_0421.mov.part") { bytesSent in
    updateProgress(bytesSent)
    return true
}

// Verify, then atomically rename into place
let attrs = try await client.attributesOfItem(atPath: "SMBDrop/2026-08-23/IMG_0421.mov.part")
try await client.moveItem(atPath: "SMBDrop/2026-08-23/IMG_0421.mov.part",
                          toPath: "SMBDrop/2026-08-23/IMG_0421.mov")
try await client.disconnectShare()
```

## Licence verdict (free, closed-source App Store app)

Adopting AMSMB2 makes SMBDrop an LGPL-2.1-consuming app: the Swift wrapper is MIT but the vendored libsmb2 is LGPL-2.1, and the project's README declares the combined work LGPL-2.1 and mandates dynamic linking for App Store distribution. That is workable because AMSMB2's Package.swift already builds the product as a dynamic framework (`type: .dynamic`), satisfying LGPL §6(b)'s requirement that users can substitute a modified library — no §6(a) object-file distribution route needed. Remaining obligations are procedural, not open-sourcing:

1. Ship the LGPL-2.1 licence text plus libsmb2/AMSMB2 attribution in the app's legal notices.
2. Provide (or link to) the complete corresponding source of libsmb2/AMSMB2, including any modifications made.
3. Do not impose EULA terms forbidding reverse-engineering for debugging the library.

SMBDrop's own code stays closed. The known residual grey area is the FSF's position that App Store DRM frustrates on-device relinking; in practice LGPL-2.1 dynamic linking is widely shipped on the App Store and AMSMB2 explicitly designs for it. If zero copyleft ambiguity is ever required, switch to MIT-licensed SMBClient and accept losing SMB3.
