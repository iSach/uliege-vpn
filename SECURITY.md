# Security model for v0.5.3 preview

Experimental, unofficial client. No independent security audit or Apple
notarization has occurred. Review before public distribution.

## Credentials and authentication

Browser sign-in is the default for new users. Each user uses their own
university account and approved MFA. Session handoff uses private process pipes
and the app caches F5 sessions in that user's login Keychain. Cache failures do
not disconnect an active VPN. User-facing auth errors are fixed messages rather
than copies of subprocess diagnostics.

Automatic TOTP is optional. It stores both the university password and MFA seed
in the same user's Keychain, reducing factor separation if that login session
is compromised. Touch ID is an app confirmation preference, not an OS-enforced
restriction on helper calls. No Keychain entries are deleted by upgrades or
helper uninstall. Browser profiles contain sensitive SSO data and must remain
private; do not include them or raw authentication logs in a report.

Credential submission is limited to HTTPS ULiège identity pages and Microsoft
Online domains with proper hostname boundaries. Known EN/FR action labels and
saved account emails match in full. Unknown pages require manual intervention.
These controls are not an independent review of the browser automation.

## Privileged component

The fixed root-owned helper lives at
`/Library/PrivilegedHelperTools/be.uliege.vpn/helper`. A per-user sudoers rule
permits only `start`, `stop`, and `status`, with NOSETENV. Any process running as
that user can invoke them. The GUI and its Touch ID preference are not security
boundaries. The helper accepts no executable path, server, config path or shell
fragment from callers.

The v0.5.3 helper:

- Rejects symlinked, hard-linked, non-root-owned or group/world-writable support
  files and writable directory modes. It does not recursively chown an existing
  installation. It assumes system-owned ancestors and no extra ACL grants;
  independent ACL/authorization review remains necessary.
- Uses privileged Bash mode, fixed PATH, a clean gof5 environment, bounded token
  input and root-only state/config files. Start/stop are serialized with an
  atomic directory lock. Status is read-only. An interrupted operation may leave
  a lock requiring manual administrator recovery; it is never blindly removed.
- Checks process UID, executable name, PID > 1 and recorded launch time before
  signalling. Legacy PID files without a launch stamp retain UID/executable
  checks. This reduces PID reuse risk but is not a kernel process handle; an
  XPC/launchd design would provide a stronger lifecycle boundary.
- Signals only on explicit Disconnect. It refuses to force-kill gof5. The
  installer refuses running or unknown sessions. Uninstall aborts if stop fails.

The installer stages and validates a root-owned sudoers candidate before atomic
activation. It must be run from trusted source; installing app-supplied code as
root authorizes that code. Ad-hoc signing does not establish publisher identity.

## gof5 configuration and session hardening

Upstream v0.1.5 `pkg/config/config.go` selects the sudo caller's home using
`SUDO_UID`/`SUDO_USER`. Setting HOME alone does not isolate that configuration.
Our pinned derivative adds an explicit `--config-dir` which bypasses that lookup
and writes generated files as the effective process owner. The helper supplies
only its fixed private root-owned directory. It uses server-provided routes
rather than forcing a default route or overriding DNS.

The patch also adds bounded `--session-stdin`; the new helper forwards the F5
session through a pipe. It never includes the token in gof5 arguments or
environment. Upstream cookie persistence can still write the cookie to the
root-only config directory; explicit stop removes it, and start replaces stale
cookies. A crash can leave that root-only file until the next operation.
Root-only gof5 logs may contain network-sensitive data and are never shown in
the UI. See [ThirdParty/README.md](ThirdParty/README.md) for source and patch.

**These changes apply only after separately updating VPN support.** The app can
use an older installed helper for compatibility, but it does not confer the
new helper protections on that installation.

## Before a recommended public release

1. Replace or independently audit the sudoers bridge, preferably with a signed,
   authenticated ServiceManagement/XPC service and reviewed request validation.
2. Audit gof5 and its dependencies, installer atomicity/rollback and ACL handling.
   Keep the pinned fork current with upstream security fixes.
3. Developer ID sign all nested code, enable reviewed hardened-runtime settings,
   notarize, and test Gatekeeper behavior on fresh Macs.
4. Test Intel and Apple Silicon, live browser/automatic auth, expired sessions,
   sleep/resume, clean install, upgrade, uninstall and routing/DNS cleanup.
5. Resolve university branding permission and confirm institutional VPN/MFA rules.
6. Fully lock and review transitive build dependencies and update provenance.

For security reports, contact the maintainer privately. Do not post passwords,
seeds, codes, cookies, authentication URLs, private hostnames or raw logs.
