# v0.5.4 menu bar improvements, build 56 — 21 October 2026

The working repository is now `~/Development/uliege-vpn`, tracking GitHub
`master`. Build 56 adds right-click/Control-click Quit, optional macOS launch
at login, a popup that fits visible content, and a tick-free time slider.

- **140 native assertions pass**: the existing 112 health/cache assertions and
  28 native UI/login-item assertions. The latter exercise real AppKit sliders,
  mouse-action delivery, keyboard and accessibility steps, disabled controls,
  SwiftUI disclosure expansion/collapse, and native window resizing. Login-item
  success, pending approval, failures and external changes use injected service
  operations; tests never register a real login item.
- Full sources typecheck for arm64 and x86_64 with warnings as errors. Five
  packaging regression tests and shell/whitespace checks pass.
- A synthetic instance of the actual menu renders at **283 pt** with Settings
  collapsed, **720 pt** expanded, then returns to 283 pt. Screenshots confirm
  the visible login option and slider without tick marks. Long content scrolls.
- Optimized arm64 native rebuild, strict bundle signature, DMG checksum,
  read-only mounted signature/plist and native archive comparisons pass. The
  existing, already-built Python/Go runtime is retained unchanged.
- Installed and launched build 56 in `~/Applications`; build 55 is backed up
  in `~/Applications/ULiege VPN Backups`. The existing VPN PID and launch time,
  privileged helper/runtime hashes and separate `/Applications` copy are
  unchanged. No login item was registered and no privileged update was made.
- GitHub's prior DMG failure came from the argument order accepted by older
  Apple `lipo`. Packaging now passes the input file before `-verify_arch`.

Real login/logout execution and macOS login-item approval remain manual checks.
Native UI automation could not read this accessory app's accessibility tree;
the local UI evidence above comes from isolated native fixtures.

---

# v0.5.4 saved-session validation — 21 October 2026

Implemented on top of local commit `af715d4`. This update adds a one-hour
configurable maximum reuse age, one saved-session check, fresh-sign-in fallback,
a bypass action, and local acceptance/rejection/unknown observations. It does
not modify or require installing a new privileged helper.

Build **55** replaces the reuse-time stepper with a slider and a live duration
label. Its range remains 0–24 hours in 15-minute steps. This UI-only revision
passed arm64/x86_64 warnings-as-errors typechecking, an isolated native visual
preview and an optimized arm64 rebuild. The rebuilt DMG passed checksum and
read-only strict signature, version/plist and native archive comparisons.
Installed application/helper hashes remain unchanged. The functional suites
listed below were completed before this UI revision and were not rerun.

## Current checks

- **112 native assertions**: 93 session-cache/HTTP/reconnect assertions plus the
  existing 19 tunnel-health assertions. These execute the actual reconnect
  coordinator using synthetic session records and injected operations.
- Coverage includes expired/unknown/future-dated cookies, exact age boundaries,
  disabled caching, forced sign-in, account changes, retained acquisition time,
  rejected-token invalidation even when Keychain deletion fails, network
  failures, one-attempt fallback, concurrent/running/unavailable tunnel states,
  cache-save failure, history retention and clearing, and credential-free
  observation serialization.
- The real URLSession validation path is tested through a local URLProtocol
  fixture. There are no live F5 requests. It checks the fixed endpoint, no
  redirect following, cross-host isolation, transport errors, token/header
  validation, bounded response size, valid VPN XML, and DTD/alternate-encoding
  rejection. Unfamiliar HTTP failures remain unknown.
- **55 Python tests**, including all 12 real Chrome EN/FR fixtures, pass with no
  skips. A fresh temporary Python environment was used after the old synced
  build environment stalled; production authentication scripts are unchanged.
- Native sources typecheck for arm64 and x86_64 with warnings treated as errors.
  Intel execution remains untested. Shell/Python parsing and Git whitespace
  checks pass.
- Settings were rendered and visually checked using a synthetic, nonpolling
  model. The preview never reads account credentials or real saved preferences.
- A full arm64 build was completed from source using a portable Python 3.13.13
  and a temporary BUILD_VENV outside the synced workspace. Both patched gof5
  tests and module verification pass. Six bundled Mach-O slices meet the
  declared macOS 13.5 minimum, and both frozen auth help/startup checks pass.
  The final UTF8 parsing guard was then rebuilt into the native executable;
  the unchanged Python/Go runtime from that full build was retained and the
  complete bundle was signed and repackaged.
- The final DMG passed image integrity and portable SHA-256 checks. Mounted
  read-only, it passed recursive strict signature validation, both frozen auth
  startup checks, version/build checks and byte comparisons of bundled helpers,
  installer, plist, privacy and security documents against the working source.
  Installed app and privileged executable hashes are unchanged.

The v0.5.4 deliverable is `dist/ULiegeVPN-0.5.4-preview-arm64-UNSIGNED.dmg`, with
its portable `.sha256` checksum. It is an ad-hoc-signed, unnotarized preview.
The v0.5.3 DMG remains available separately. The canonical signed app archive is
`build/ULiegeVPN.app.zip`; use it or the DMG rather than a file-provider-modified
workspace display copy.

## Live behavior and remaining validation

The new app-v3 Keychain cache is separate from older undated entries, so the
first connection obtains a fresh session. No-cache mode avoids the native F5
cache; browser profiles may still retain valid Microsoft SSO cookies. A success
observation means F5 accepted the cookie, not that a tunnel is verified or that
the same lifetime is guaranteed next time. A client age cutoff is not recorded
as server rejection. Only attempted reuses are measured; there are no background
probes and there is no automatic adjustment of the configured limit.

During the initial cache implementation, installed app and privileged executable
hashes were unchanged; builds/tests did not modify credentials, browser profiles,
routes or DNS. Later source publication and app installation are documented
above. No public release or privileged installation was performed. Live university sign-in/profile responses,
server-side expiry, real Keychain permissions, Intel execution and older macOS
execution still need account-owner testing. Earlier security/release caveats
continue to apply.

---

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
