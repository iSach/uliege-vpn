# Bundled gof5

gof5 is Apache-2.0 licensed: https://github.com/kayrus/gof5.
The app bundles a locally built derivative of upstream **v0.1.5**, commit
`fabb2b8bb92980f6ac481c5e7d66dc395d79f962`. See `gof5-source.env` and
`GOF5-APACHE-2.0.txt`. Build with `Scripts/build-gof5.sh` as a normal user.

`gof5-hardening.patch` changes three upstream files and adds two test files:

- `--config-dir` selects an absolute configuration directory without consulting
  `SUDO_UID`, `SUDO_USER`, or the calling user's home. Ownership for generated
  files is the effective user running gof5 (root in the helper).
- `--session-stdin` reads at most 4098 bytes from a private input pipe and accepts
  a 10–4096 byte printable ASCII token, optionally followed by one newline.
  Errors never include the token. It cannot be combined with `--session`.
- Session-only mode returns an error on a rejected session rather than asking
  for a username/password in the background.

The helper uses both new flags and a fixed server. It launches with a clean
environment and never places the cookie in process arguments. Stock gof5 is
not accepted as a replacement. Config/cookie files and logs still require root
protection. Upstream may save session cookies in the root-only configuration
folder during a connection; explicit Disconnect removes that cookie file.

This small patch is **not** an independent audit of gof5 or its dependencies.
The source includes pinned `go.sum` checksums. Build provenance can be inspected
with `go version -m build/gof5-hardened`; the app also bundles its binary SHA-256.
Dependencies and security updates need ongoing review.
