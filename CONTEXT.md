# SMBDrop — Ubiquitous Language

- **SMBDrop** — the app: a completely free iOS utility that sends photos, videos, and arbitrary files from an iPhone to an SMB share, and imports files from configured shares back to the iPhone. No accounts, no login, no payments.
- **Destination** — a saved SMB share configuration: free-text host (IP or hostname), share name, optional subfolder, username + password (stored in the iOS Keychain).
- **Transfer** — one file moving from device to Destination. Transfers run one item at a time ("chunked" per Isaac: a video, an image, or a file at a time).
- **Share Extension** — the surface inside the iOS share sheet (Photos app → Share → SMBDrop). The reason the app exists.
- **Main App** — the standalone surface: Photos, Files, Import, and Settings tabs for sending, importing, transfer progress/history, and Destination management.
- **Onboarding** — first-run flow: photo-library permission → Destination setup → Test Connection.
- **Test Connection** — the explicit connect-and-verify step run against a Destination before it is trusted.
- **Import** — one or more files downloaded from a configured Destination into the app's on-device `SMBDrop Imports` folder, visible in Files under On My iPhone.

## Destination decisions

- SMBDrop saves multiple Destinations. Each can be tested, edited, or removed from Settings, and every export explicitly chooses one.
- Settings is organized as a root list of saved shares plus focused detail screens: Transfer History (live progress, per-item retry/remove, clear-completed) and About (privacy summary, version, third-party notices).
- A Destination uses a host name or IP address, TCP port, share name, optional subfolder, username, and password. Port 445 is the default; SMB dialect selection remains implicit.
- The non-secret fields live in the shared App Group. The password lives in the iOS Keychain and is never stored in preferences or logs.
- Save is available only after Test Connection succeeds for the exact current field values. Editing any value requires another test.
- Test Connection opens the share and verifies the configured subfolder. Failures are translated into friendly authentication, timeout, reachability, and missing-path messages.
- **Find Shares** — with host, port, and sign-in filled, SMBDrop enumerates the server's visible disk shares (srvsvc over IPC$, hidden `$` shares excluded) so the user taps a real share instead of typing one; a lone share auto-fills the field. When a test fails because the share is missing, the suggestions load automatically beside the error. Mirrors PhotoSync and the Files app, and exists because typed share names were the dominant setup failure.

## Transfer contract (v1)

- SMBDrop preserves the original bytes and filename for photos, Live Photo resources, RAW files, videos, and arbitrary shared files. It does not transcode HEIC or video.
- Files land directly in the Destination subfolder. If the exact name already exists, SMBDrop stops that item and asks the user to resolve the conflict; it never changes a name or overwrites an existing file.
- Transfers run one item at a time. The Main App resumes durable work in global queue order; a foreground Share Extension drains only the batch the user just submitted so it does not consume an unrelated backlog. Each upload streams from a local file URL, writes to a unique visible `smbdrop-<UUID>.partial` remote name, verifies the uploaded byte count, and then renames into place.
- Every Transfer is bound to a Destination ID and export batch before upload, so one Destination worker can never claim another share's files. Existing single-Destination queues are migrated to their original Destination.
- Progress is presented for the whole export batch: aggregate bytes plus the current item number (`N of X`). Individual history rows show status without competing progress bars.
- Every item is staged in a durable App Group outbox before upload. Interrupted uploads remain retryable; completed files are removed from local staging but retained as lightweight history. Current Transfer lets the user remove queued items immediately or stop and remove the active item safely; an active removal request is durable across the app and Share Extension.
- Temporary remote names are visible, UUID-based `smbdrop-*.partial` names. They never begin with a dot because Samba can preserve the dot-file Hidden attribute after the final rename and make a successful upload disappear from normal Windows Explorer views.
- Automatic retry is bounded. A failed item stays visible with a friendly error and can be retried by the user; queued items after it are not discarded.
- SMB is a local-network protocol, so v1 has no separate Wi-Fi-only switch or custom port/dialect controls.

## Main App source tabs

- **Photos** opens with Recents and the device's Photos albums, then shows a five-column image/video grid with multi-selection, horizontal drag-range selection, and compact video-duration badges. It stages original `PHAssetResource` bytes, including the paired video for a Live Photo.
- **Files** launches Apple's native document picker with multi-selection, then stages security-scoped files without changing their bytes or names. UIKit requires a full document browser to be the app's root controller, so it cannot be embedded inside SMBDrop's tab-based interface.
- **Import** is strictly for importing: it lists configured Destinations, browses each Destination from its configured subfolder, and downloads selected files one at a time into `Documents/SMBDrop Imports`. Imports stream to a unique partial file, verify byte count, preserve modification time, and never overwrite an existing local file. The app exposes its Documents directory in Files.
- Photos and Files both present the same Destination picker and enqueue through the shared durable outbox.
- The Files tab is send-first: choosing files to send sits at the top (Apple's document picker for iCloud Drive, On My iPhone, and third-party providers; UIKit does not permit embedding that picker as the tab's root browser), with an "On This iPhone" section below listing past imports with thumbnails and metadata for re-selection, Quick Look preview, Share Sheet, Save to Photos for compatible media, and deletion.
- On iOS 26 and later, a user-started Photos or Files export runs as a Continued Processing Task so SMB work can continue after the Main App backgrounds and the system shows progress in a Live Activity/Dynamic Island. Older iOS versions use the supported short background-completion window; anything still unfinished remains durable for the next foreground resume.

## Share Extension architecture

- The durable outbox is the always-correct backbone shared by both targets. The extension copies item-provider file representations into it one at a time and never buffers complete media in memory.
- Before staging starts, the extension shows an app-branded Destination chooser. Share extensions cannot launch their containing app on iOS, so the choice and inline transfer remain inside the extension surface.
- Small shares may drain inline while the share sheet remains open. Large shares, dismissal, or any inline failure leave the staged items queued for the Main App rather than losing them.
- The extension cannot promise background SMB transfer after dismissal. It tells the user when work is queued and the Main App resumes on its next foreground run.
- Activation is bounded to images, movies, and files; the extension never uses `TRUEPREDICATE`.
