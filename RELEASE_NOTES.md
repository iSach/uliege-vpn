# ULiège VPN v0.5.4 — saved sign-in lifetime controls

Next-day reconnects no longer blindly try an undated or indefinitely cached
cookie. The default reuse window is one hour, configurable in Settings from
zero (always fresh sign-in) to 24 hours. A separate action bypasses saved
sign-in once. Both paths preserve every running or unverified VPN session.

- Records fresh authentication time and account together with the cookie in a
  new Keychain entry. Older undated entries and automatic-login credentials
  are preserved. Successful reuse never extends the recorded age.
- Checks a recent saved cookie once against the fixed F5 profile endpoint.
  Recognized authentication redirects invalidate it and fall back to fresh
  sign-in; transport failures and unfamiliar responses remain unknown.
- Uses a six-second request deadline, bounded response parsing, system TLS,
  no shared cookies/credentials and no redirect following. No background probes
  or privileged-helper update are needed for this feature.
- Shows local acceptance/rejection/unknown observations and cookie ages. History
  never contains tokens or account names; it is bounded and can be cleared.
  Clearing observations does not resurrect a rejected saved session.
- Checks again for a running/unknown helper around authentication so a concurrent
  connection is never replaced. Keychain save failure remains nonfatal.

The chosen reuse window is not ULiège's guaranteed timeout. Rejection can reflect
inactivity, absolute expiry, revocation or policy changes. Acceptance means the
server accepted the cookie, not that all network traffic uses a VPN. Live
university authentication remains an account-owner test after installation.

# ULiège VPN v0.5.3 — unsigned preview

The app no longer disconnects a working university session when route or DNS
verification times out. Split routing and uncertain health remain manageable
with Disconnect, including when helper status is unavailable. Health hints
separate sampled IPv4 routing, university routing, and unverified running
sessions; they do not claim IPv6 coverage or prove end-to-end connectivity.

- Bounds startup checks by elapsed time and ignores stale polling results.
- Retries cached authentication only after an explicit stopped helper status.
- Builds a pinned gof5 v0.1.5 derivative with `--config-dir` and `--session-stdin`.
  The new helper no longer lets gof5 consult a sudo user's config and no longer
  places the F5 token in process arguments or environment.
- Checks privileged file ownership, modes, links and process identity; serializes
  start/stop. Installer rejects running/unknown sessions and validates an atomic
  sudoers candidate. Explicit disconnect removes the root-side cached cookie.
- Uses exact EN/FR action labels and account email matching, HTTPS-only host
  checks, and shared F5 portal completion logic for browser and automatic modes.
- Keeps onboarding visible during input, checks Chrome availability, makes the
  menu scrollable and defaults new users to browser MFA.
- Builds without installing by default. Adds native health tests, pinned main
  Python build dependencies, portable checksums, architecture/signature checks,
  and a draft-only GitHub prerelease workflow.
- Declares macOS 13.5 as the minimum required by the bundled Playwright Node
  runtime and checks every bundled Mach-O slice against that requirement.

## Upgrade

The app-side connection fix is compatible with the old helper API. The helper
security changes require a separate, explicitly authorized support update.
Disconnect your current session yourself before updating support. Your Keychain
entries and browser profiles are preserved. No automatic session migration is
performed and no active VPN is stopped by the installer.

## Validation and remaining limits

See VALIDATION.md for the actual local results. This is an unofficial,
ad-hoc-signed preview. Live ULiège/Microsoft authentication, privileged helper
installation, Intel execution and clean-machine upgrades remain untested in
this local run. It is not notarized. The sudoers bridge still grants per-user
passwordless fixed helper commands and has not been independently audited.
University branding permission and policy review remain outstanding.
