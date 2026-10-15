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
