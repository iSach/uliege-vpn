# ULiège VPN for macOS · unofficial preview

A lightweight macOS menu-bar interface for the [gof5](https://github.com/kayrus/gof5)
F5 VPN client and ULiège/Microsoft browser authentication. Its menu-bar icon
turns colorful when the ULiège full tunnel is connected and monochrome when
disconnected. **This is an independent community prototype, not supported or
endorsed by ULiège, Microsoft, or F5.**

> **v0.5.0 preview — do not publicly promote yet.** The root helper has not
> been independently reviewed. The source includes ULiège-derived art requiring
> branding permission before public redistribution. Read
> [SECURITY.md](SECURITY.md) and [BRANDING.md](BRANDING.md).

## For a colleague testing the unsigned DMG

The DMG contains an app for one CPU architecture (Apple Silicon or Intel).
No `uv`, Homebrew, `oathtool`, Python, or developer tools are needed to run
this preview. Google Chrome is still needed for SSO.

1. Drag **ULiege VPN.app** into `/Applications` and open it. This prototype is
   **not notarized**. macOS may require **System Settings → Privacy & Security
   → Open Anyway** after you verify the downloaded source.
2. Click the menu-bar icon and **Install VPN Support…**. This launches an
   explicit one-time installer in Terminal; it requires admin authorization.
   It installs a root-owned copy of gof5 and a *restricted, passwordless*
   sudoers rule for the VPN helper. **This is a security caveat, not a
   completely seamless or hardened privileged helper.**
3. Click **Refresh status** and enter *your own* university email.
4. Click **Connect** and sign in using your normal ULiège/Microsoft MFA method.
   Your session is cached in your own macOS Keychain when possible.

Never copy someone else's TOTP secret or session cookie. Automatic TOTP
sign-in is optional; it stores that person's own university password and
TOTP seed in their user Keychain, which weakens multi-factor separation if
that Mac is compromised. Normal browser sign-in is recommended for testers.

**Uninstall:** Run `uninstall-helper.sh` from a trusted source checkout or the
app's `Contents/Resources/Support` directory, then remove the app. This does
not revoke the MFA enrollment or clear every browser/Keychain credential.

## What changed in v0.5

- Bundles a gof5 executable for the target Mac architecture, with Apache-2.0
  license attribution. No Homebrew install is needed by the DMG user.
- Adds a visible first-run **Install VPN Support…** action when the helper is
  missing, instead of sending new users to a README for a shell command.
- Adds [`Packaging/create-dmg.sh`](Packaging/create-dmg.sh) for an unsigned DMG
  with a drag-to-Applications shortcut.
- Builds Apple Silicon and Intel previews on GitHub Actions. CI artifacts are
  produced without automatically publishing a public release.
- Tagging a version generates a GitHub **DRAFT** Release containing two
  preview DMGs; only the maintainer can choose to publish the draft.
- Adds privacy, supply-chain, publishing, and third-party licensing notes.

**Inherited from v0.4.2:** F5 session handoff through a private process pipe,
nonfatal Keychain cache failures, browser MFA fallback, optional locally
configured TOTP, connection-state probing, and Touch ID as optional UI
confirmation (not a privilege boundary).

## For developers: build without overwriting an installed app

Build requires macOS 13+, Xcode Command Line Tools, Python 3.11–3.13 + pip,
and gof5 at build time (`brew install gof5`). Python dependencies are installed
in a local build-only environment by the script. The result is built for the
CPU architecture of the builder.

```sh
python3 -m unittest discover -s tests -v
INSTALL_APP=0 ./build.sh
./Packaging/create-dmg.sh
ls -lh dist/*.dmg
```

`INSTALL_APP=0` preserves your existing `~/Applications/ULiege VPN.app`.
Without it, `build.sh` installs the built copy to `~/Applications` for local
testing (same behavior as earlier versions). **Building does not run the
privileged support installer.** The `build.sh` default is preserved for users
already developing against this repository.

For source installs on a fresh machine, `./setup.command` remains available
as an experimental guided Terminal workflow. Public DMG testers should not
need it.

## Publishing to GitHub

See [PUBLISHING.md](PUBLISHING.md) for the review checklist, creating the repo,
and preparing an unsigned **draft** release. The GitHub Actions macOS runners
for public repos can build both Apple Silicon and Intel variants; no Apple
Developer subscription is required to build an **unsigned** disk image.

Do **not** publish this as a hardened or trusted VPN client until the
privileged helper and credential-handling issues in [SECURITY.md](SECURITY.md)
have been reviewed. The lack of notarization also requires manual Gatekeeper
approval on user machines. A paid Developer ID isn't required to open-source
or test the source.

## Privacy and third-party licenses

See [PRIVACY.md](PRIVACY.md), [ThirdParty/README.md](ThirdParty/README.md), and
[BRANDING.md](BRANDING.md). Project-owned code is MIT-licensed; gof5 is
Apache-2.0-licensed. ULiège's marks are **not** licensed by the MIT license.

## Troubleshooting

- **App doesn't show an icon:** It is menu-bar-only (`LSUIElement`), so check
  the right side of the macOS menu bar. `pgrep -fl ULiegeVPN` confirms whether
  the app process is running.
- **VPN support missing:** use *Install VPN Support…* once and *Refresh status*.
- **Authentication completes but VPN doesn't connect:** test the helper status,
  check for a `utun` route and university DNS, and open a private bug report
  without cookies, MFA codes, or authentication URLs.
- **Intel vs ARM:** use the correct DMG for your Mac. A DMG's filename specifies
  architecture. Neither DMG is universal.
- **Security prompt:** don't disable Gatekeeper globally; verify the build and
  use the normal *Open Anyway* process if you trust the source.


### French authentication (v0.5.2)

Automatic sign-in recognizes French and English variants of ULiège's choice
pages, Microsoft MFA screens, and F5 endpoint inspection. If your tenant
shows an unfamiliar button, use **Debug sign-in in browser** and report the
button wording (never send passwords, TOTP secrets, or cookies).
