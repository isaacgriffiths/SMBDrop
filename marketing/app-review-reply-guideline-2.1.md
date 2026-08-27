# App Review reply — Guideline 2.1 information request

## How to send

App Store Connect → SMBDrop → App Review page for the rejected submission → **Reply**.
Attach the screen recording (see shot list below), paste the reply text, and send.
No new build is required.

## Screen recording shot list (item 1)

Record on your physical iPhone (Settings → Control Centre → Screen Recording), on a
**fresh install** so the onboarding and permission prompts appear. One continuous take:

1. Launch SMBDrop from the Home Screen.
2. Walk through onboarding, including the Photos access prompt — accept it on camera.
3. Add a share: enter the server address, username, password → **Find Shares** → pick the
   share → **Test Connection** (the Local Network permission prompt appears here — accept
   it on camera) → save.
4. Photos tab: multi-select a few photos/videos → send → show live progress completing.
5. Files tab: pick a document with the Files picker → send.
6. Home Screen → Photos app → select a photo → Share → SMBDrop → pick the destination →
   send (shows the Share Extension).
7. Import tab: browse the share, download a file, preview it, save media to Photos.

Keep it a few minutes long; AirDrop it to a machine and attach the file to the reply.
There are no account, purchase, or user-generated-content flows to show — the reply text
says so explicitly.

## Reply text (paste below the attachment)

---

Hello, thank you for the review. Responses to each numbered point:

1. Attached is a screen recording captured on a physical iPhone. It begins at app launch
and shows onboarding, both permission prompts (Photos and Local Network), adding an SMB
share with Find Shares and Test Connection, sending photos and documents, sharing into
the app from the Photos share sheet extension, and browsing/importing files back from the
share. SMBDrop has no account registration or login, no purchases or subscriptions, and
no user-generated content shared between users, so those flows do not exist in the app.

2. The app was tested via TestFlight on a physical iPhone 16 Pro running iOS 26.6,
against a real SMB server: Samba on Linux.

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

We have also added this information to the Notes field of the App Review Information
section for future submissions. Thank you!
