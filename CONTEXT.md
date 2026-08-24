# SMBDrop — Ubiquitous Language

- **SMBDrop** — the app: a completely free iOS utility that sends photos, videos, and arbitrary files one-way from an iPhone to an SMB share. No accounts, no login, no payments.
- **Destination** — a saved SMB share configuration: free-text host (IP or hostname), share name, optional subfolder, username + password (stored in the iOS Keychain).
- **Transfer** — one file moving from device to Destination. Transfers run one item at a time ("chunked" per Isaac: a video, an image, or a file at a time).
- **Share Extension** — the surface inside the iOS share sheet (Photos app → Share → SMBDrop). The reason the app exists.
- **Main App** — the standalone surface: Photos, Files, and Settings tabs for in-app sending, transfer progress/history, and Destination management.
- **Onboarding** — first-run flow: photo-library permission → Destination setup → Test Connection.
- **Test Connection** — the explicit connect-and-verify step run against a Destination before it is trusted.

## Destination decisions

- SMBDrop saves multiple Destinations. Each can be tested, edited, or removed from Settings, and every export explicitly chooses one.
- A Destination uses a host name or IP address, share name, optional subfolder, username, and password. Port 445 and SMB dialect selection remain implicit.
- The non-secret fields live in the shared App Group. The password lives in the iOS Keychain and is never stored in preferences or logs.
- Save is available only after Test Connection succeeds for the exact current field values. Editing any value requires another test.
- Test Connection opens the share and verifies the configured subfolder. Failures are translated into friendly authentication, timeout, reachability, and missing-path messages.
- **Find Shares** — with host and sign-in filled, SMBDrop enumerates the server's visible disk shares (srvsvc over IPC$, hidden `$` shares excluded) so the user taps a real share instead of typing one; a lone share auto-fills the field. When a test fails because the share is missing, the suggestions load automatically beside the error. Mirrors PhotoSync and the Files app, and exists because typed share names were the dominant setup failure.

## Transfer contract (v1)

- SMBDrop preserves the original bytes and filename for photos, Live Photo resources, RAW files, videos, and arbitrary shared files. It does not transcode HEIC or video.
- Files land directly in the Destination subfolder. If the name already exists, SMBDrop appends ` (2)`, ` (3)`, and so on; it never overwrites an existing file.
- Transfers run one item at a time. The Main App resumes durable work in global queue order; a foreground Share Extension drains only the batch the user just submitted so it does not consume an unrelated backlog. Each upload streams from a local file URL, writes to a unique `.smbdrop-partial` remote name, verifies the uploaded byte count, and then renames into place.
- Every Transfer is bound to a Destination ID and export batch before upload, so one Destination worker can never claim another share's files. Existing single-Destination queues are migrated to their original Destination.
- Progress is presented for the whole export batch: aggregate bytes plus the current item number (`N of X`). Individual history rows show status without competing progress bars.
- Every item is staged in a durable App Group outbox before upload. Interrupted uploads remain retryable; completed files are removed from local staging but retained as lightweight history.
- Automatic retry is bounded. A failed item stays visible with a friendly error and can be retried by the user; queued items after it are not discarded.
- SMB is a local-network protocol, so v1 has no separate Wi-Fi-only switch or custom port/dialect controls.

## Main App source tabs

- **Photos** is a permission-aware, Photos-style thumbnail grid for images and videos with native multi-selection. It stages original `PHAssetResource` bytes, including the paired video for a Live Photo.
- **Files** launches Apple's document browser with multi-selection, then stages security-scoped files without changing their bytes or names.
- Photos and Files both present the same Destination picker and enqueue through the shared durable outbox.

## Share Extension architecture

- The durable outbox is the always-correct backbone shared by both targets. The extension copies item-provider file representations into it one at a time and never buffers complete media in memory.
- Before staging starts, the extension shows an app-branded Destination chooser. Share extensions cannot launch their containing app on iOS, so the choice and inline transfer remain inside the extension surface.
- Small shares may drain inline while the share sheet remains open. Large shares, dismissal, or any inline failure leave the staged items queued for the Main App rather than losing them.
- The extension cannot promise background SMB transfer after dismissal. It tells the user when work is queued and the Main App resumes on its next foreground run.
- Activation is bounded to images, movies, and files; the extension never uses `TRUEPREDICATE`.
