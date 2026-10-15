ULiège VPN v0.5.3 — UNOFFICIAL UNSIGNED PREVIEW

1. Drag ULiege VPN.app into Applications. Eject the disk image, then open the app.
2. This app is not notarized. If blocked, verify the source and checksum before
   using System Settings > Privacy & Security > Open Anyway. Keep Gatekeeper on.
3. On a fresh Mac, open the menu bar and select Install VPN Support. Review the
   Terminal prompt before typing INSTALL and approving administrator access.
   The helper grants limited passwordless start/stop/status commands to your
   account. Read SECURITY.md included on this disk before approving.
4. Enter your own university email and identifier. Install Google Chrome if
   prompted, finish setup, then connect using normal browser MFA.

The app requires macOS 13.5 or newer and Chrome for sign-in, but no Homebrew, Go, Python, uv or oathtool
at runtime. Use the DMG matching Apple Silicon (arm64) or Intel (x86_64).
Automatic TOTP sign-in is optional and uses your own password and MFA seed.

UPGRADING: The app-side connection fix works with the previous helper API. The
new helper security protections require a separate support update from the new
app's Settings > Update VPN Support action. Finish and disconnect your
current session yourself before running that installer. It refuses to replace
a running or unknown session. Keychain entries and browser profiles are kept.

Routing and DNS checks never automatically stop gof5. Orange means running but
unverified, or status unavailable; Disconnect remains available. Green routing
hints do not prove IPv6 coverage, privacy of every connection, or reachability.

This helper has not been independently audited. Live sign-in, clean installs,
upgrades, Intel execution and managed-device policies require further testing.
