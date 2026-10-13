# ULiège VPN v0.5 — unsigned preview

This is an **unofficial, unnotarized, experimental** client for testers who
trust the code and understand the security implications. It is **not** an
approved university VPN application and is **not recommended for broad
installation** until the privileged helper and branding have been reviewed.

- Native menu bar status, Connect/Disconnect, optional Touch ID confirmation.
- Browser sign-in with regular ULiège/Microsoft MFA or opt-in automatic TOTP.
- Bundled Python authentication runtime, Playwright, and gof5. No Homebrew,
  `uv`, `oathtool`, or system Python required to **run** the prebuilt app.
- Separate one-time admin-authorized helper installer launched from the app.
- Builds for Apple Silicon and Intel, as two unsigned DMG files.

**Important:** Installation of VPN support grants the current user restricted
passwordless root helper commands. Any process running as that user can invoke
them; the Touch ID preference does not secure the helper. The root gof5 process
may expose an F5 session token in its arguments. See `SECURITY.md`.

Before publication: test both DMGs on clean Macs, check ULiège branding
permissions, review helper threat model, and confirm the VPN's terms of use.

### v0.5.1-preview — French sign-in selector

- Recognizes `Authentification Forte Microsoft` on French ULiège identity-provider pages.
- Keeps the English `Microsoft MFA Authentification` selector supported.
- Includes regression tests for both button texts.

### v0.5.2-preview — complete English/French authentication path

- Handles ULiège provider choice and local identifier/password form in EN/FR.
- Handles Microsoft account picker, passwordless-to-password link, TOTP method
  selection, alternative MFA method selection, and stay-signed-in prompt in EN/FR.
- Handles the F5 endpoint-inspection skip choice in EN/FR (where offered).
- Accepts curly apostrophes, different spacing, and accent variants in labels.
- Avoids blindly clicking a generic Microsoft Yes/Oui button without the
  stay-signed-in prompt, and never autoselects federal itsme/eID.
- Adds localized button tests using real Chromium and privacy-safe fixtures.

Note: labels are based on observed and documented UI patterns, not a live test
of every Microsoft tenant language variant. Unrecognized pages may still need
manual interaction through Debug sign-in in browser.
