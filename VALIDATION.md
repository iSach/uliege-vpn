# Local validation — 15 October 2026

Work started from the user's clean v0.5.2 repository at commit
`ab27360871d850184ca537b0f5681854fd4a9415`. Its `master` matched the public
GitHub repository. The four extracted v0.5.2 copies contained identical source.
No local v0.5.3 project or archive was found in the inspected locations, so the
v0.5.3 fixes were implemented against that actual v0.5.2 source.

The working checkout is `outputs/ULiegeVPNMenuBar` on
`fix/v0.5.3-local-hardening`. Existing history is preserved. No force push,
ordinary push, tag upload, PR, GitHub release or privileged installation was
performed during this work.

## Passed on this Mac

Host: Apple Silicon, macOS 27.0.1. Native code compiled with Swift 6.4 in Swift 5
language mode. The application declares macOS 13.5 as its minimum; actual
execution on that older version is not yet tested.

- **55 Python tests**, with no skips. Includes 12 real Chrome EN/FR fixture
  tests, portal completion state tests and 13 simulated helper/installer tests.
  Fixtures use only local HTML and synthetic session data.
- **19 native Swift health assertions**: split routing, missing/failed DNS,
  missing university route, unrelated utun interfaces, exact helper responses,
  failed status commands, slow probes, delayed child startup, and Disconnect
  availability for running/unavailable states.
- Native source typechecks with warnings treated as errors for both arm64 and
  x86_64. The Intel check is compilation analysis, not Intel execution.
- Patched gof5's private-session input test and explicit-config isolation test
  pass. Go modules verify against upstream go.sum. The build pins upstream
  v0.1.5 commit plus the checked-in local patch.
- Full native arm64 application build and bundled authentication `--help` startup
  checks, without contacting ULiège/Microsoft or reading account credentials.
- Runtime compatibility scan: six actual Mach-O slices, highest declared library
  minimum **macOS 13.5.0** (Playwright's Node). The bundled Python is **3.13.13**.
- Strict recursive ad-hoc signature verification of the canonical app during
  staging. Native onboarding and unverified-state previews were rendered from
  isolated fixture models with no polling, credentials or saved user preferences.
- Disk image creation and image integrity verification; portable SHA-256 check.
  Mounted the DMG read-only and repeated strict signature and both auth startup
  checks. Bundled helper, installer and plist bytes match the reviewed source.
- Shell syntax, both workflow YAML files, sudoers candidate syntax (an ordinary
  local file, not installed), and Git whitespace checks.

## Artifacts

- `dist/ULiegeVPN-0.5.3-preview-arm64-UNSIGNED.dmg`
- Matching `.dmg.sha256`
- `build/ULiegeVPN.app.zip` — canonical clean signed bundle archive
- `build/ULiege VPN.app` — convenient workspace copy

The build stages/signs on private temporary storage. This workspace's file
provider can add FinderInfo metadata back to a displayed `.app`, which breaks
strict signature validation. Packaging therefore reads the clean ZIP rather
than that display copy. Use the verified DMG or clean ZIP for installation.
Only FinderInfo/resource-fork metadata is removed from build staging before
signing; no quarantine stripping or Gatekeeper changes are performed.

The first Homebrew-Python build correctly failed the new compatibility scan:
its OpenSSL libraries required macOS 27. The final build uses a separate
project-local portable Python, leaving system Python and the installed app
alone. Build dependencies still need ongoing review; transitive Python versions
are not fully locked.

## Preservation

The original downloaded checkout remains clean on `master`. The installed app
reports v0.4.0. SHA-256 comparisons confirm that its executable and both installed
privileged helper/gof5 executables are unchanged. No Keychain entries, browser
profiles, system routes, DNS settings or installed sudoers rules were edited.

## Still required

- Explicit user approval before installing/updating privileged support. The
  installer refuses an active or uncertain session; it does not disconnect one.
- Account-owner testing of live ULiège/Microsoft EN/FR sign-in, cached/expired
  sessions, cluster access, DNS behavior, sleep/resume and explicit disconnect.
- Real privileged clean install, upgrade, rollback and uninstall testing.
- Intel execution, clean Macs, macOS 13.5 execution and two-architecture CI runs.
- Independent helper/dependency review, authenticated XPC or equivalent stronger
  authorization, full dependency locking, Developer ID signing/notarization,
  and university branding/policy review before a recommended public release.

The GitHub workflows and release notes are prepared locally. The release
workflow creates a draft prerelease only after an approved matching version tag
is uploaded; no tag or release was uploaded here.
