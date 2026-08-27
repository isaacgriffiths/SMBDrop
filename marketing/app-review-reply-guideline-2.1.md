# App Review reply — Guideline 2.1 information request

## How to send

App Store Connect → SMBDrop → the rejection message → **Reply to App Review**.
Attach `S:\Video\SMBDrop-review-recording.mp4` (the blurred copy — NOT the original
`ScreenRecording_08-27-2026 21-18-11_1.mp4`, which shows incoming message
notifications), paste the reply text below, and send. No new build is required.

Recording verified 2026-08-27: launch from TestFlight, full onboarding, add-share with
Find Shares + Test Connection, the iOS Local Network permission prompt (accepted on
camera at ~0:37), sending 3 photos with live progress, importing files back, a Files-tab
document round-trip with preview, and Settings/About. The iOS Photos permission dialog
does not appear (access was already granted on the device before recording), and the
share-sheet extension is not shown — the reply text below is worded to match.

Optional: a second ~20s clip of the extension (Photos app → Share → SMBDrop → send)
would cover the one core feature the video misses. If you record it, attach it too and
add this sentence to the end of item 1: "A second short clip showing the share-sheet
extension (Photos app → Share → SMBDrop) is also attached."

## Reply text (paste below the attachment) — fits the 4000-character limit

---

Hello, thank you for the review. Responses to each numbered point:

1. Attached is a screen recording captured on a physical iPhone 16 Pro running iOS 26.6.
It begins at app launch and shows: onboarding (including the in-app photo-access step),
adding an SMB share with Find Shares and Test Connection — including the iOS Local
Network permission prompt being granted on camera — sending photos with live transfer
progress, browsing the share and importing files back to the phone, a document
round-trip from the Files tab with preview, and the Settings and About screens. The iOS
photo-library permission dialog itself does not appear because photo access had already
been granted to the app on this device before recording started. A small strip at the
top of the frame is blurred between 0:35 and 0:48 to hide incoming personal message
notifications; nothing behind it is app UI. SMBDrop has no account registration or
login, no purchases or subscriptions, and no user-generated content shared between
users, so those flows do not exist in the app. As a real-world demonstration: this very
recording was transferred from the iPhone to our Windows PC using SMBDrop itself, via
the same Samba share shown in the video, which the PC also mounts.

2. The app was tested via TestFlight on a physical iPhone 16 Pro running iOS 26.6,
against a real SMB server: Samba on Linux, with the same share also accessed from
Windows 11.

3. SMBDrop moves photos, videos, and files between an iPhone and the user's own SMB
network shares (a NAS, a Windows or macOS shared folder, or a Samba server), and imports
files from those shares back to the phone. It is completely free — no account, no cloud
service, no subscription, no ads. Its audience is home and small-office users who own a
NAS or file server and want to offload camera photos or fetch files without a cloud
intermediary: transfers go directly from the phone to the user's own server over the
local network, preserving original bytes (including both halves of Live Photos).

4. There are no user accounts, so no demo login exists — the app talks only to the
reviewer's own SMB server. To test with any Mac: System Settings → General → Sharing →
enable File Sharing, and under its ⓘ options enable "Share files and folders using SMB"
for a user account. In SMBDrop: Settings → add a share → enter the Mac's IP address and
that user's username and password → tap "Find Shares" and pick a listed share → "Test
Connection" → save. Photos and files can then be sent from the Photos and Files tabs or
via the share sheet, and downloaded back from the Import tab. Any Windows shared folder,
Samba server, or NAS works the same way. No sample files are needed — any photo or
document on the device can be sent.

5. No external services are used for core functionality. All SMB transfers run on-device
via the open-source AMSMB2 library, directly between the phone and the user's server; no
data passes through any server of ours. The only network call outside the user's LAN is
the optional Settings → "Request a Feature" form, which relays the user's typed message
to us via a Cloudflare Worker and the Resend email API. No authentication services,
payment processors, data providers, analytics, or AI services are used.

6. There are no regional differences; the app functions identically in all regions.

7. Not applicable — the app operates in no regulated industry and contains no protected
third-party material. The AMSMB2 library is used under its MIT licence and credited in
Settings → About.

The App Review Information Notes field has also been updated with this information for
future submissions. Thank you!
