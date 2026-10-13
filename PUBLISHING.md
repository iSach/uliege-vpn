# GitHub publication and unsigned DMG checklist

These commands do NOT publish for you. Inspect all sources first, especially
`Helper/`, `install-helper.sh`, `Scripts/`, and `ThirdParty/`.

## Prepare repository

- Decide a repository name (e.g. `uliege-vpn-macos`).
- Confirm you have the right to redistribute the ULiège-derived logo, or
  replace it with an original non-infringing icon before making the repo public.
- Inspect `.gitignore`; do **not** commit session cookies, credentials, real
  authentication traces, build output, or Keychain exports.
- Verify that the private login workflow works with normal browser sign-in,
  not just your particular automatic TOTP configuration.
- Consider whether to make the *source repository* public while withholding
  releases until the privileged helper receives security review.

```sh
cd /path/to/ULiegeVPNMenuBar-v0.5-preview
python3 -m unittest discover -s tests -v
git init
git add .
git status --short
git commit -m 'Initial unsigned macOS preview source'
# Review GitHub account and content; start PRIVATE during testing:
gh repo create uliege-vpn-macos --private --source=. --push
```

## Test builds without installing on your Mac

On Apple Silicon or Intel macOS, with build requirements installed:

```sh
INSTALL_APP=0 ./build.sh
./Packaging/create-dmg.sh
```

The DMG will be in `dist/`, named with the app version and CPU architecture.
The CI workflow builds BOTH platforms on GitHub-hosted macOS machines. It
uploads unsigned images as Actions artifacts, not as public releases.

## Make a reviewable DRAFT release

Only after building successfully and testing on real Macs:

```sh
git tag v0.5.0-preview.1
git push origin v0.5.0-preview.1
```

The `draft-release.yml` workflow creates a **DRAFT** GitHub Release with both
DMGs. It is not visible as a public release until you choose *Publish release*.
Do not publish until you have reviewed the security caveats and logo licensing.

## Gatekeeper and trust

Without an Apple Developer ID membership, builds are ad-hoc signed, **not**
notarized, and may be blocked by Gatekeeper. Testers may use macOS **System
Settings → Privacy & Security → Open Anyway** after verifying the source.
Never tell testers to disable Gatekeeper globally or run a blanket
`xattr -rd com.apple.quarantine` on downloaded code.

## Important release blockers

- The experimental helper still relies on sudoers NOPASSWD. No independent
  security audit has been conducted. Consider a narrower authorization model
  or explicit admin authorization per connection for public use.
- The root gof5 CLI receives an F5 cookie through process arguments.
- University-owned branding is not licensed by this project's MIT license.
- Review bundled dependencies, code signing, supply chain provenance, and
  university rules before broad release.
- The unsigned DMG is not a one-click **security-reviewed** distribution.
