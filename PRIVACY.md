# Privacy

The application is designed to contact ULiège's identity/VPN gateways and
Microsoft Entra in order to authenticate; these services have their own privacy
policies and logs. No analytics or telemetry has been deliberately added to
this project's own source.

Optional automatic authentication stores a university password and personal
TOTP enrollment secret in this user's login Keychain. Browser authentication
doesn't need these credentials, but F5 session cookies are sensitive and may be
cached in the login Keychain. An F5 cookie is passed to the privileged gof5
client at connect time. The v0.5.3 helper uses a private input pipe; older
installed helpers still expose the cookie through process arguments until
separately updated. gof5 may persist the session in its root-only configuration
directory; explicit Disconnect removes that cookie file. A crash may leave it
until the next start/stop operation. Never publish raw authentication logs.

You can remove optional automatic sign-in credentials in the app's setup
window. Removing the app by itself does not revoke Microsoft MFA enrollment,
erase SSO browser profile data, or delete every Keychain credential.

The project's GitHub Actions runs tests and packages the app, but does not
handle production user credentials. Each colleague must authenticate with
their own ULiège account and MFA method.

## v0.5.4 saved sign-in metadata

The new app-v3 Keychain entry stores the cookie with its acquisition time,
account and a randomly generated local identifier. Undated app-v2 entries are
preserved and ignored. Reuse observations are stored only in this Mac's app
preferences: timestamps, ages, accepted/rejected/unknown outcomes and random
association IDs. They contain no cookie, password, seed, account name, URL,
profile name or server response. Up to 100 observations are kept; entries older
than 30 days are pruned on load or recording. Clearing the visible history keeps
up to 32 rejected local IDs so an undeletable Keychain cookie cannot retry.

A saved-session check occurs only on an actual eligible Connect request, over
system-validated HTTPS to the fixed university F5 endpoint. Redirects are not
followed. No background validation, keep-alive, analytics or remote history
upload is performed. Zero reuse age disables reading/saving the new cache.
