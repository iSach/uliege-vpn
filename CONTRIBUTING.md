# Contributing

This is an experimental, unofficial macOS VPN client. Contributions should be
made in a fork through a pull request after running the checks below.

```
python3 -m unittest discover -s tests -v
python3 -m py_compile Scripts/*.py
bash -n build.sh setup.command install-helper.sh uninstall-helper.sh Helper/helper.sh
./build.sh  # macOS + Xcode Command Line Tools only
```

Never add user passwords, TOTP seeds, F5 cookies, VPN session logs, developer
signing files, or personal login profiles. See SECURITY.md before changes to
privileged code or credential handling. UI and auth protocol changes must be
tested against the actual login stages in headed mode before headless mode.
