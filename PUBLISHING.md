# Prepare the v0.5.4 GitHub preview

Local builds do not publish, install privileged support, or replace the installed
app. `./build.sh` defaults to INSTALL_APP=0. See SECURITY.md for remaining limits.

## Review and build

```sh
./tests/run-native-tests.sh
./build.sh
ULIEGE_TEST_CHROMIUM='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' \
  build/.build-venv/bin/python -m unittest discover -s tests -v
./Packaging/create-dmg.sh
(cd dist && shasum -a 256 -c *.sha256)
git diff --check
git status --short
```

The local output is architecture-specific. CI also builds and tests Intel.
Do not claim a local Apple Silicon build validates Intel execution or live MFA.
Never commit credentials, profiles, session cookies, build products or raw logs.

## Source branch and draft release

Review the complete source diff and VALIDATION.md. Preserve existing Git history;
this update does not require a force push. Push the reviewed feature branch and
merge it through your normal review process. Before tagging, confirm the remote
branch points to the exact reviewed commit and both architecture jobs passed.

The release workflow accepts only a tag matching CFBundleShortVersionString,
currently **v0.5.4**. After maintainer authorization, create and push that tag on
the reviewed commit. The workflow builds two DMGs, verifies portable checksums,
and creates a **draft prerelease** using RELEASE_NOTES.md. It never publishes
that draft automatically. A manual branch dispatch builds review artifacts only.

A public release needs separate explicit approval. Before publishing, finish
live/privileged tests and review signing, university branding and the remaining
sudoers security model. No automatic release or helper update is performed by
the app. Do not replace an old release asset under the same version number.

## Unsigned preview trust

Ad-hoc signatures detect some bundle changes but do not identify a publisher.
The app is not notarized. Give testers the correct architecture and checksum,
and include INSTALLING.md and SECURITY.md. Users may choose the normal macOS
Privacy & Security → Open Anyway path after verifying the source. Never advise
disabling Gatekeeper globally.

The runner labels are checked against GitHub's [hosted runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
Local signing uses temporary storage and packaging reads the clean signed ZIP,
so file-provider Finder metadata in a display copy cannot corrupt the DMG.
