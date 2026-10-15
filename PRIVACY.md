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
