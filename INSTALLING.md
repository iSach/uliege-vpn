ULiège VPN for macOS — UNSIGNED PREVIEW

Not an official ULiège app. This is a test build and its privileged helper has
NOT undergone independent security review. Do not install on managed devices
without your IT team's approval.

1. Drag "ULiege VPN.app" into Applications. Do not run it from this disk image.
2. Open the app. If macOS blocks it, use System Settings > Privacy & Security
   > Open Anyway (ONLY after verifying you trust the source).
3. Open the menu bar icon, select "Install VPN Support…", and approve the
   one-time helper installation in Terminal. This installs root-owned gof5 and
   a LIMITED BUT PASSWORDLESS sudoers rule. See SECURITY.md in the source repo.
4. Enter YOUR OWN university email, choose browser sign-in, and connect.
   Optional unattended TOTP enrollment is available under Settings; never share
   a seed or account password with another person.

The app needs Google Chrome for ULiège login. It does not need Homebrew, uv,
Python, or oathtool at runtime. Apple Silicon and Intel DMGs are separate.

Before public use: review the privileged-helper design, university branding
permissions, and university VPN/MFA rules. The app is not notarized.
