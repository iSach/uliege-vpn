# ULiège VPN for macOS · unofficial v0.5.3 preview

Native menu bar controls for [gof5](https://github.com/kayrus/gof5) and
ULiège/Microsoft browser authentication. This is an independent community
prototype, not endorsed by ULiège, Microsoft, or F5. Read [SECURITY.md](SECURITY.md)
and [BRANDING.md](BRANDING.md) before sharing a build.

## Connection behavior

A running VPN is never stopped because a route, DNS check, or status request
fails. Only an explicit Disconnect action stops it. The app reports:

| Status | Evidence | Indicator |
| --- | --- | --- |
| Connected · IPv4 routes detected | University DNS and three sampled IPv4 destinations use the same utun interface | Green |
| Connected · University route detected | University DNS address routes through a utun interface | Green |
| VPN running · Unverified | gof5 is running; routing checks are inconclusive | Orange |
| VPN status unavailable | Helper failed, timed out, or returned an unknown response | Orange; Disconnect available |
| Disconnected | Helper explicitly reports STOPPED | Gray |

These are local routing hints. Another VPN can own a utun interface. They do
not prove cluster reachability, IPv6 coverage, or that all internet traffic is
private. Cached sessions are retried only after gof5 explicitly exits; an
unverified running process is preserved. Checks use bounded commands and a
monotonic startup deadline. Stale polling results cannot overwrite a newer
Connect/Disconnect operation.

## Install a preview

1. Use the DMG for your Mac's architecture. Drag the app into Applications,
   eject the disk image, and open the app.
2. If Gatekeeper blocks this unsigned preview, verify its provenance and use
   System Settings → Privacy & Security → Open Anyway. Never disable Gatekeeper.
3. On a fresh Mac, use **Install VPN Support…** and review the Terminal prompt.
   This requires explicit administrator approval and installs restricted,
   passwordless helper commands. Any process in your user account can invoke
   these commands. Touch ID in the app is confirmation only.
4. Enter your own university email and identifier. Install Google Chrome if
   prompted, then finish setup. Browser sign-in is the new-user default.
5. Connect using your normal university MFA. Optional automatic TOTP setup is
   available in Settings and uses only your own password and enrollment seed.

Onboarding stays visible while typing. The menu can scroll on smaller screens.
Disconnect remains enabled when email is blank or Chrome is unavailable.

### Upgrading an existing installation

The new app can use the previous fixed helper API for the connection fix.
**The helper security fixes take effect only after separately updating VPN
support.** Finish your current session and disconnect it yourself before
using **Settings → Update VPN Support…** or running the new `install-helper.sh`. The installer refuses a running or
unknown session; it never disconnects one to perform an upgrade. Existing
Keychain entries and browser profiles are preserved.

The new helper requires this project's patched gof5 v0.1.5 binary. It uses an
explicit root-owned config directory and a private pipe for the session.
Stock gof5 is rejected. See [ThirdParty/README.md](ThirdParty/README.md).

## Build and verify locally

Requirements: macOS 13.5+, Xcode Command Line Tools, Python 3.11–3.13, and Go
1.24 or newer (this preview was built with Go 1.27.1). Google Chrome is needed
for sign-in and local browser fixture tests. End users of a prebuilt app need
none of the build tools.

```sh
./tests/run-native-tests.sh
./build.sh
ULIEGE_TEST_CHROMIUM='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' \
  build/.build-venv/bin/python -m unittest discover -s tests -v
./Packaging/create-dmg.sh
```

Builds default to **not installing**. The result is `build/ULiege VPN.app`, with a clean signed archive at
`build/ULiegeVPN.app.zip`; `dist/` contains the DMG and portable SHA-256 checksum. `INSTALL_APP=1 ./build.sh`
explicitly installs to `~/Applications`. Building never installs privileged
support or contacts university authentication services. `setup.command` is an
explicit install flow, including administrator authorization.

The pinned gof5 source and local hardening patch are built as the normal user.
The frozen Python runtime bundles Playwright and Keychain support. Go module
checksums are verified and the four main Python build dependencies are pinned.
Transitive Python dependencies are not yet fully locked; builds are not claimed
bit-for-bit reproducible. The build checks every bundled Mach-O library's minimum
OS requirement and rejects runtimes exceeding macOS 13.5. A Homebrew Python may
link to libraries requiring the builder's latest macOS; use `PYTHON=/path/to/a/compatible/python3.13`
if this check fails. An optional build-only portable Python can be downloaded
inside this checkout with `uv python install --install-dir build/python-runtime --no-bin 3.13`.
The build discovers that local runtime automatically. uv is never required by the
packaged app. Signing and DMG assembly use private temporary storage so workspace
file providers cannot inject Finder metadata into the canonical archive.

## French and English authentication

Both languages are supported across ULiège provider selection, local password
forms, Microsoft account selection, passwordless alternatives, verification
codes, stay-signed-in questions, and F5 inspection choices. Matching tolerates
accents, apostrophes and whitespace, but requires the entire action label.
Account selection requires the configured email exactly. Credentials are only
entered on HTTPS ULiège/Microsoft hosts with proper domain boundaries.

Manual and automatic sign-in share F5 completion detection. An early session
cookie or SAML ACS page alone is not success. A `/my.policy` landing must follow
an observed inspection choice that disappears and a stable cookie. Unknown
pages may still need manual browser sign-in. This preview has local fixture
coverage; live tenant authentication still requires testing by the account owner.

## Releases

GitHub checks build separate Apple Silicon and Intel unsigned previews. Tags
must match the app version. The release workflow verifies both architectures'
checksums and creates a **draft prerelease**. Publishing remains a manual
maintainer decision. See [PUBLISHING.md](PUBLISHING.md), [RELEASE_NOTES.md](RELEASE_NOTES.md),
and [VALIDATION.md](VALIDATION.md).

## Privacy and removal

No real credentials, browser profiles, cookies, or auth traces belong in Git.
The app caches sessions in the user's Keychain. Optional automatic login stores
a password and MFA seed together on this Mac. See [PRIVACY.md](PRIVACY.md).

`uninstall-helper.sh` explicitly disconnects before removing helper support and
refuses removal if stopping fails. It preserves Keychain entries and browser
profiles. Remove the app separately. Project-owned code is MIT licensed; gof5 is
Apache-2.0 licensed. University branding is not covered by those licenses.
