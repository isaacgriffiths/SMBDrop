# Share-extension constraints and upload-handoff patterns

Research for [issue #4](https://github.com/isaacgriffiths/SMBDrop/issues/4), feeding the architecture decision in #7.
Question: what are the hard iOS constraints on a share extension that uploads over raw TCP (SMB), and what handoff patterns do transfer apps use?

Date: 2026-08-23. Sources are Apple primary docs / Apple DTS ("Quinn the Eskimo!") forum posts wherever possible; the memory ceiling and some behaviours are undocumented and sourced from credible field reports, marked as such.

---

## 1. Hard constraints (facts)

### 1.1 Memory limit: ~120 MB, and it is undocumented

- Apple does not publish a memory limit for share extensions anywhere in the App Extension Programming Guide. The widely observed figure on modern iOS is **120 MB**, at which point the extension is killed with `EXC_RESOURCE RESOURCE_TYPE_MEMORY`.
  - Field confirmations: [Igor Kulman, "Dealing with memory limits in iOS app extensions"](https://blog.kulman.sk/dealing-with-memory-limits-in-app-extensions/) (states 120 MB for share extensions, 24 MB for notification service extensions); [Element iOS issue #2341](https://github.com/element-hq/element-ios/issues/2341) (share extension force-quit at the memory limit when sharing several images or a panorama); [Flutter issue #135243](https://github.com/flutter/flutter/issues/135243).
- Apple DTS's position on extension memory limits generally (stated for Network Extensions, but the policy statement is general): limits "have changed in the past and may well change in the future… You should not hard code knowledge about these limits into your code" — Quinn, [Apple Developer Forums thread 73148](https://developer.apple.com/forums/thread/73148). Treat 120 MB as an observed envelope, not a contract; design for streaming so the number never matters.
- Practical implication: never materialise a shared photo/video in memory. Ask `NSItemProvider` for **file representations** and stream from disk. Kulman's note shows even innocuous `UIImage` round-trips blow the limit; use `CGImageSource` thumbnailing or raw file copies instead.

### 1.2 Lifetime: the extension dies shortly after its UI completes — and can die any time after `completeRequest`

- App Extension Programming Guide ([Handling Common Scenarios](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html)): "After your app extension calls `completeRequestReturningItems:completionHandler:` to tell the host app that its request is complete, **the system can terminate your extension at any time**."
- There is no documented wall-clock limit while the extension's UI is frontmost — it lives as long as the user keeps the sheet up — but it is suspended/terminated aggressively once the sheet is dismissed or the host app backgrounds. Quinn ([thread 76659, "Networking in a Short-Lived Extension"](https://developer.apple.com/forums/thread/76659)): whether the extension or the app gets a task's completion callback is non-deterministic precisely because "if the task takes longer, the system has time to terminate the extension".
- Brief protection against suspension while a short operation is in flight: `ProcessInfo.performExpiringActivity(withReason:using:)` — Quinn's explicit recommendation for short-lived requests in extensions ([thread 76659](https://developer.apple.com/forums/thread/76659)). Extensions cannot use `UIApplication.beginBackgroundTask` (no `UIApplication` access), and this buys seconds, not minutes.

### 1.3 Raw sockets / Network.framework: allowed while running, dead on termination

- There is **no prohibition** on an extension using `Network.framework` / POSIX sockets / any userland SMB client while its process is alive; app extensions get normal network access (nothing in the [App Extension Programming Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html)'s list of unavailable APIs restricts sockets; the restrictions are things like `UIApplication.shared` and long-running background modes). AmberXie/field evidence: FileBrowser, Documents, and PhotoSync all ship share extensions that talk to LAN targets directly.
- The hard limit is **continuation, not permission**: the *only* networking that survives extension termination is a `URLSession` **background session**. Quinn ([thread 76659](https://developer.apple.com/forums/thread/76659)) frames background sessions as the sole mechanism for "keeping network requests alive after the extension terminates"; there is no equivalent for sockets. When the extension process is suspended or killed, its TCP connections are gone.

### 1.4 Background URLSession cannot carry SMB — confirmed

- [`URLSession` documentation](https://developer.apple.com/documentation/foundation/urlsession): "The URLSession class natively supports the `data`, `file`, `ftp`, `http`, and `https` URL schemes"; background sessions support **upload/download tasks over HTTP/HTTPS only** (HTTP/1.1, /2, /3). SMB is a raw-TCP protocol on port 445 with its own framing — it cannot be expressed as a URLSession upload task. **Therefore the one iOS mechanism that lets a transfer outlive a share extension is unusable for SMB.** (It would only become usable via an HTTP relay, e.g. a WebDAV bridge on the NAS — a deployment burden that defeats SMBDrop's premise; noted and rejected in §3.)
- For completeness, the background-session choreography for HTTP apps (per Quinn, [thread 76659](https://developer.apple.com/forums/thread/76659) and [App Extension Programming Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html)): session must set `sharedContainerIdentifier` to the App Group; one process connected at a time (`NSURLErrorBackgroundSessionInUseByAnotherProcess` otherwise); events with no process connected **relaunch the containing app**, not the extension, via `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.

### 1.5 The extension cannot open or wake its containing app on demand

- `NSExtensionContext.open(_:completionHandler:)` is supported **only from Today widgets**; using it from a share extension is unsupported (works intermittently via responder-chain hacks, App Store rejection risk) — [NSExtensionContext docs](https://developer.apple.com/documentation/foundation/nsextensioncontext) and Apple forum guidance (e.g. [thread 65621](https://developer.apple.com/forums/thread/65621)).
- **Darwin notifications** (`CFNotificationCenterGetDarwinNotifyCenter`) cross the app/extension process boundary but carry no payload and are delivered only to processes that are *currently running* — they do not launch a terminated app ([Nonstrict, "Using Darwin Notifications to communicate with App Extensions"](https://nonstrict.eu/blog/2023/darwin-notifications-app-extensions/); [forum thread 769398](https://developer.apple.com/forums/thread/769398)). Useful as a "new work staged" ping when the main app happens to be alive; useless as a wake mechanism.
- **BGTaskScheduler**: an extension *may submit* a `BGProcessingTaskRequest` on behalf of the app — Apple's own WWDC19 example is a keyboard extension scheduling ML training ([WWDC19 session 707, "Advances in App Background Execution"](https://developer.apple.com/videos/play/wwdc2019/707/)); the launch handler then runs **in the main app** in the background. But BGProcessingTask execution is discretionary: typically device-idle/charging/overnight, minutes of runtime, no guaranteed schedule ([BGTaskScheduler docs](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler)). It is an opportunistic drain mechanism, not a prompt one.
- **Local notifications**: extensions *can* post `UserNotifications` — Quinn confirms this is the sanctioned way for an extension to surface transfer status ([thread 76656](https://developer.apple.com/forums/thread/76656)). A "Tap to finish upload" notification is the reliable user-mediated wake: tapping it launches the main app.

### 1.6 NSItemProvider payloads and the App Group container

- `NSItemProvider.loadFileRepresentation(forTypeIdentifier:completionHandler:)` hands the extension a temporary file URL and **deletes the file when the completion handler returns** ([loadFileRepresentation docs](https://developer.apple.com/documentation/foundation/nsitemprovider/2888338-loadfilerepresentation)); the file also lives in the extension's sandbox, unreadable by the main app. So any handoff **requires a copy (or `FileManager` move/clone) into the App Group shared container** before completing the request. On APFS a same-volume copy is a near-instant clone, so staging a 4 GB video is fast and costs no double storage until blocks diverge — but the shared container copy does count against device free space until uploaded and deleted.
- App Groups are the sanctioned data-sharing channel (shared container + `UserDefaults(suiteName:)`) — [App Extension Programming Guide, "Sharing Data with Your Containing App"](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html).

### 1.7 Activation rules and multi-item shares

- `NSExtensionActivationRule` in the extension's Info.plist governs when SMBDrop appears in the share sheet. Dictionary form supports per-type max counts: `NSExtensionActivationSupportsImageWithMaxCount`, `...MovieWithMaxCount`, `...FileWithMaxCount`, `...WebURLWithMaxCount`, `...AttachmentsWithMaxCount` — [App Extension Programming Guide, "Declaring Supported Data Types"](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html#//apple_ref/doc/uid/TP40014214-CH21-SW8).
- **`TRUEPREDICATE` is an App Store rejection**: "If any app extensions in your containing app include the string `TRUEPREDICATE`, the app will be rejected" (same page). For "images + movies + arbitrary files, any count", use either the dictionary keys with generous counts (e.g. Image/Movie/File each set high — the dictionary keys OR together) or a `SUBQUERY` predicate on `public.image OR public.movie OR public.file-url OR public.data` conformance. A predicate is the right call for "anything shareable, up to N items"; keep N bounded (e.g. 100) rather than unbounded to avoid pathological share-sheet payloads.
- Multi-item shares arrive as one `NSExtensionItem` with multiple attachments (or several items); each attachment is loaded independently, so the staging loop is per-attachment and memory stays flat if files are streamed/copied one at a time.

### 1.8 What PhotoSync's observable behaviour tells us Apple permits

([photosync-app.com](https://www.photosync-app.com) docs/FAQ — evidence of what ships and passes review)

- PhotoSync transfers to SMB/NAS targets directly from the app and ships a Sharing Extension that transfers to the same targets, including manually configured computers (fixed in [4.6 release notes](https://www.photosync-app.com/support/release-notes/photosync-4-6-for-ios-released)) — i.e. **raw LAN protocol traffic from inside a share extension is App Store-permitted in practice**.
- Its background story is explicitly *not* socket-continuation: background autotransfer relies on **location-triggered wakes of the main app** ("your iPhone will automatically wake up PhotoSync in the background and PhotoSync will start with the transfer") and the FAQ concedes transfers get only about **3 minutes of background runtime** before iOS suspends the app ([location autotransfer FAQ](https://www.photosync-app.com/support/ios/answers/how-do-i-automatically-transfer-photos-when-i-arrive-at-a-pre-selected-location), [autotransfer troubleshooting](https://www.photosync-app.com/support/basics/answers/how-to-solve-my-autotransfer-problems-on-ios)). Large transfers require keeping the app in the foreground. This is the strongest field evidence that **nobody has a trick around "SMB dies when the process sleeps"** — the best-in-class app resorts to location wakes and foreground sessions.
- FileBrowser (Stratospherix) similarly performs SMB transfers in-app/in-extension foreground; its share extension stages into the app when transfers are large. Same shape.

---

## 2. What this rules out

1. **"Fire and forget" from the share sheet over SMB is impossible.** No API keeps an SMB socket alive after the extension (or backgrounded main app) is suspended. Background URLSession is HTTP(S)-only (§1.4).
2. **Silently waking the main app the moment the user hits Share is impossible.** No `openURL` from share extensions, Darwin notifications don't launch, BGTasks are discretionary (§1.5).
3. **Unbounded in-extension buffering is impossible** (~120 MB ceiling) — but that only forbids *buffering*, not *transferring*: a streamed copy from a file URL to a socket in, say, 1–8 MB chunks runs in constant memory regardless of file size (§1.1, §1.6).

## 3. Viable architectures

### Option A — App-Group staging; main app uploads ("outbox")

Extension: enumerate attachments → `loadFileRepresentation` → copy/clone each into the App Group container + append a manifest entry (target share, remote path, per-file state) → post a Darwin ping (in case the app is running) → post a local notification "N files queued — tap to upload" → `completeRequest`. Main app: on foreground (or notification tap, or an opportunistic `BGProcessingTask` submitted by the extension), drain the outbox over SMB with full background-time husbanding (~30 s via `beginBackgroundTask` if the user leaves; resume on next launch).

- **Pros:** bulletproof for any size/count (4 GB video is a fast APFS clone); constant, tiny memory in the extension; extension UI dismisses instantly (good share-sheet UX); one SMB engine lives only in the app; retries/conflicts/errors handled with a real UI.
- **Cons:** **the upload does not start until the app runs** — worst case the user must tap the notification or open the app (PhotoSync/FileBrowser accept the same cost); staged bytes occupy device storage until drained; BGProcessingTask drain is best-effort (overnight/charging).

### Option B — Upload inside the extension, UI held open ("live upload")

Extension opens the SMB connection itself (permitted, §1.3/§1.8) and streams each attachment file-URL → socket in chunks while showing progress in the sheet. `performExpiringActivity` guards short gaps; on completion, `completeRequest`. If the user dismisses early or the host app backgrounds, the socket dies — the transfer must be treated as failed/partial.

- **Pros:** zero-touch for the common case (a few photos on LAN finish in seconds); no staging storage; instant feedback; no second app-launch step.
- **Cons:** user must keep the sheet up for the whole transfer — a 4 GB video over Wi-Fi is minutes of forced foreground with no recovery if interrupted; duplicate SMB stack in the extension (binary size, keychain access from extension); memory discipline mandatory; host apps (esp. Photos) sometimes kill sheets; wall-clock behaviour is at the system's mercy the moment the UI isn't frontmost.

### Option C — Hybrid: live upload for small work, staged outbox otherwise (recommended)

Size-gate in the extension: if total payload is under a threshold (e.g. ≤ 50–100 MB *of transfer*, not memory) and the target is reachable, do Option B inline with progress; otherwise (or on any failure/dismissal) fall back to Option A — stage, notify, let the main app finish. Always write the manifest first so an interrupted live upload degrades into a staged one instead of losing work. Optionally submit a `BGProcessingTaskRequest` from the extension so an overnight charge drains the outbox without user action.

- **Pros:** matches user expectations (photos "just go"; a movie gets an honest "open SMBDrop to finish" flow); every failure path lands in the durable outbox; mirrors what the PhotoSync/FileBrowser class of apps demonstrably ships.
- **Cons:** two code paths (mitigate by making the extension's uploader the same streaming engine over the same manifest, just driven inline); threshold tuning; SMB engine + credentials must be extension-safe (App Group keychain access group).

**Leaning: Option C**, with Option A as the always-correct backbone and Option B as an inline fast path. Option B alone is untenable for the 4 GB-video case; Option A alone makes the delightful case (share three photos from Photos) needlessly clunky.

### Rejected: HTTP relay to reach background URLSession

Running a WebDAV/HTTP bridge beside the SMB server (or a companion daemon) would unlock true fire-and-forget via background URLSession — but requires server-side installs, defeating "point at any SMB share". Out of scope; note it as the only path to genuine background continuation should requirements change.

---

## 4. Facts checklist (as asked in #4)

| Question | Answer | Source |
|---|---|---|
| Memory limit ~120 MB? | Yes, observed on modern iOS; undocumented, may change | §1.1 |
| Lifetime | Alive while sheet frontmost; killable "at any time" after `completeRequest` | §1.2 |
| Raw sockets from extension? | Allowed while running; die on suspension/termination | §1.3, §1.8 |
| Background continuation for SMB? | None — background URLSession is HTTP/HTTPS upload/download only | §1.4 |
| How main app learns of staged work | Next foreground; notification tap; Darwin ping if already running; discretionary BGProcessingTask (extension may submit) | §1.5 |
| Must user open app? | For large/interrupted transfers, yes (tap notification or open) — PhotoSync has the same cost | §1.5, §1.8 |
| One photo vs 4 GB video in-extension | Photo: fine inline (streamed). 4 GB: only with sheet held open; stage instead | §3 B/C |
| Multi-item | Per-attachment staging/streaming; bounded counts in activation rule | §1.7 |
| TRUEPREDICATE | App Store rejection; use dictionary max-count keys or SUBQUERY predicate | §1.7 |
