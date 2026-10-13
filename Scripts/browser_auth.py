#!/usr/bin/env python3
"""Interactive ULiège F5 sign-in for users without locally configured TOTP.

Every user signs in with THEIR OWN Entra/ULiège account, using whichever
second factor their organization permits. This script never requests or saves
passwords, TOTP secrets, or Microsoft Authenticator data. It stores only the
resulting F5 session cookie in the logged-in user's macOS Keychain.
"""
import base64
import getpass
import re
import sys
import time
from pathlib import Path
from urllib.parse import urlsplit

import keyring
from playwright.sync_api import sync_playwright, Error as PlaywrightError

PORTAL = "https://vpn.uliege.be/mfa"
PROFILE = Path.home() / ".config/uliege-vpn/interactive-browser"
SERVICE = "uliege-vpn-MRHSession"
F5_HOSTS = {"vpn.uliege.be", "vpn-2fa.uliege.be"}


def main(emit_session: bool = False) -> int:
    PROFILE.mkdir(mode=0o700, parents=True, exist_ok=True)
    PROFILE.chmod(0o700)
    with sync_playwright() as browser:
        try:
            context = browser.chromium.launch_persistent_context(
                str(PROFILE), channel="chrome", headless=False
            )
        except PlaywrightError as exc:
            print("Could not open Google Chrome. Install Chrome first.", file=sys.stderr)
            return 1
        try:
            context.clear_cookies(name=re.compile(
                r"^(MRHSession|F5_ST|LastMRH_Session|MRHSequence)$"))
            for tab in list(context.pages):
                try: tab.close()
                except PlaywrightError: pass
            tab = context.new_page()
            tab.goto(PORTAL, wait_until="domcontentloaded", timeout=60000)
            print("Sign in to ULiège in the Chrome window with your own account.", flush=True)
            print("Use your existing Authenticator approval or another allowed MFA method.", flush=True)
            print("If F5 offers endpoint inspection, choose the university-permitted option.", flush=True)
            deadline = time.monotonic() + 420
            while time.monotonic() < deadline:
                try:
                    cookies = context.cookies([
                        "https://vpn.uliege.be", "https://vpn-2fa.uliege.be"
                    ])
                    session = next((c["value"] for c in cookies
                                    if c["name"] == "MRHSession" and c["value"]), None)
                    authenticated = False
                    for page in context.pages:
                        if page.is_closed(): continue
                        for frame in page.frames:
                            url = urlsplit(frame.url)
                            if url.hostname in F5_HOSTS and url.path.startswith("/vdesk"):
                                authenticated = True
                                break
                        if authenticated: break
                    if session and authenticated:
                        if emit_session:
                            # Only the parent macOS app reads this private pipe.
                            # Never display, log, or persist this output.
                            encoded = base64.b64encode(session.encode("utf-8")).decode("ascii")
                            print("ULIEGE_F5_SESSION_B64:" + encoded, flush=True)
                            return 0
                        try:
                            keyring.set_password(SERVICE, getpass.getuser(), session)
                        except Exception:
                            print("Keychain error: could not save the authenticated F5 session.", file=sys.stderr)
                            return 1
                        print("Authenticated ULiège VPN session saved in this Mac's Keychain.", flush=True)
                        return 0
                    if all(page.is_closed() for page in context.pages):
                        raise RuntimeError("Login window closed before authentication completed")
                except PlaywrightError:
                    # Navigation may briefly destroy a frame. Continue polling.
                    pass
                time.sleep(0.6)
            print("Sign-in timed out before reaching the authenticated F5 portal.", file=sys.stderr)
            return 1
        finally:
            context.close()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (KeyboardInterrupt, RuntimeError) as exc:
        print("Sign-in cancelled or failed.", file=sys.stderr)
        sys.exit(1)
