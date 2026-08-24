# SMBDrop — Ubiquitous Language

- **SMBDrop** — the app: a completely free iOS utility that sends photos, videos, and arbitrary files one-way from an iPhone to an SMB share. No accounts, no login, no payments.
- **Destination** — a saved SMB share configuration: free-text host (IP or hostname), share name, optional subfolder, username + password (stored in the iOS Keychain).
- **Transfer** — one file moving from device to Destination. Transfers run one item at a time ("chunked" per Isaac: a video, an image, or a file at a time).
- **Share Extension** — the surface inside the iOS share sheet (Photos app → Share → SMBDrop). The reason the app exists.
- **Main App** — the standalone surface: onboarding, a photos-clone browser for in-app sending, transfer queue/history, and Destination settings.
- **Onboarding** — first-run flow: photo-library permission → Destination setup → Test Connection.
- **Test Connection** — the explicit connect-and-verify step run against a Destination before it is trusted.

## Destination decisions (v1)

- SMBDrop saves one Destination. It can be tested, edited, or removed from the Main App.
- A Destination uses a host name or IP address, share name, optional subfolder, username, and password. Port 445 and SMB dialect selection remain implicit.
- The non-secret fields live in the shared App Group. The password lives in the iOS Keychain and is never stored in preferences or logs.
- Save is available only after Test Connection succeeds for the exact current field values. Editing any value requires another test.
- Test Connection opens the share and verifies the configured subfolder. Failures are translated into friendly authentication, timeout, reachability, and missing-path messages.
