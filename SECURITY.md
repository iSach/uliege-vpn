# Security model and release blockers

**STATUS: Experimental release candidate for testing on machines you control.
NOT approved for distribution as a turnkey security-sensitive application.**

## Trust boundaries

- Each user must use their own Entra/ULiège MFA enrollment and credentials.
  No cookie, password, or TOTP secret ships in the repository.
- Browser sign-in is the default and does not require the app to access the
  user's password or TOTP seed. It saves the authenticated F5 session in the
  local login Keychain.
- Optional unattended TOTP sign-in stores a password and TOTP enrollment seed
  in the **same** macOS user Keychain. This weakens factor isolation if the
  user's login session is compromised. It is opt-in.
- The app and authentication browser are not a security boundary. Its Touch ID
  toggle is a user-interface confirmation only.
- The root-owned helper is installed at
  `/Library/PrivilegedHelperTools/be.uliege.vpn/helper` and a per-user sudoers
  rule grants passwordless `start`, `stop`, and `status` for that binary.
  Any process running as that user may invoke those operations, independent of
  Touch ID. The helper has been restricted to fixed commands and does not
  evaluate supplied shell commands. It still requires independent review.
- The external gof5 API accepts `--session` on its command line, exposing the
  F5 cookie to local process inspection on some macOS configurations. Fixing
  that requires a gof5 change or an alternate safer credential transport.
- Root-owned gof5 parses untrusted network responses and needs careful
  security maintenance. We do not automatically update the copied binary.

## Must address before a recommended public release

1. Replace the sudoers bridge with a properly signed and authenticated
   ServiceManagement/XPC privileged component, or deliberately choose an
   interactive per-connect OS authorization model. Review code-signing and
   helper request validation, and test on fresh Macs.
2. Remove the F5 session from process arguments (upstream change), if feasible.
3. If shipping unsigned builds, make Gatekeeper limitations explicit. For a
   smoother public installation, Developer ID signing/notarization is preferable;
   validate update provenance and uninstall flow either way.
4. Resolve university branding permission (see BRANDING.md).
5. Test both Intel and Apple Silicon, including clean install, browser login,
   automatic TOTP, expired sessions, sleep/resume, and disconnect cleanup.
6. Confirm use complies with ULiège VPN and MFA policies.

## Reporting

Please avoid public issues containing credentials, MFA setup QR codes, browser
cookies, session IDs, private hostnames, or raw logs. For security reports,
contact the repository maintainer privately through GitHub once its security
advisory channel is enabled.

## Bundled Python runtime

The app now uses a PyInstaller build-time bundle for Python, Playwright and
Keychain support. End users do not need uv or Python. The embedded executable
can nevertheless access this user's Keychain entries with the same privileges
as the GUI client. Treat the standalone executable as authentication-sensitive.
Production distributions need a signed, notarized app with hardened runtime,
reviewed entitlements, and privileged-helper redesign before broad release.

The diagnostic text displayed by the GUI is limited to recognized phrases; it
never displays the raw Playwright subprocess traceback, which may contain SAML
URLs or other session-sensitive information.

## v0.5 unsigned DMG preview

The preview bundles the gof5 executable, then the user explicitly approves
installing it as root together with the fixed-function helper. This **reduces
installation dependencies; it does not resolve the privileged helper's
security issues**. The app's Touch ID toggle remains UI-only; the fixed sudoers
rule allows any process owned by that macOS account to start, stop, or query
the helper. No independent security review or Apple notarization has occurred.

Review the upstream gof5 security posture and licensing, the PyInstaller
bundled dependencies, and the one-time installer on fresh test Macs before
publishing a DMG or asking colleagues to run it. Users must not be told to
turn off Gatekeeper globally.
