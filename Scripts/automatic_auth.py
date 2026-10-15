#!/usr/bin/env python3
"""ULiège F5 VPN launcher: browser-based Microsoft MFA and gof5.

Usage: uliege-vpn --headed --refresh  (first test)
       uliege-vpn                    (reuse stored session, otherwise reauthenticate)
       uliege-vpn --auth-only        (test obtaining the cookie, without starting VPN)

Handles Microsoft saved-account tiles (Pick an account) as well as the
ULiège and Microsoft authentication pages.

Uses the macOS Keychain entries uliege-vpn-password and uliege-mfa-totp,
created previously with the `security` command. Keeps the F5 session in
macOS Keychain when run standalone. The bundled app receives the cookie over a
private process pipe; it never prints authentication secrets to user logs.
"""

import argparse
import base64
import hashlib
import hmac
import struct
import getpass
import os
import re
import subprocess
import sys
import time
import unicodedata
from pathlib import Path
from urllib.parse import urlsplit

import keyring
from playwright.sync_api import Error as PlaywrightError
from playwright.sync_api import sync_playwright

PORTAL = "https://vpn.uliege.be/mfa"
SERVER = "vpn-2fa.uliege.be"
PROFILE = Path.home() / ".config/uliege-vpn/browser"
F5_HOSTS = {"vpn.uliege.be", "vpn-2fa.uliege.be"}
F5_SESSION_SERVICE = "uliege-vpn-MRHSession"
# Explicit labels for the ULiège / Microsoft / F5 screens we encounter.
# Keep these scoped by page host and action: never use a broad search that
# could choose Belgium's federal itsme/eID authentication by mistake.
# These are known or plausible UI variants; an unfamiliar page still needs
# browser confirmation rather than an unverified click.
ULIEGE_MICROSOFT_CHOICES = (
    "Microsoft MFA Authentification",       # English ULiège page
    "Microsoft MFA Authentication",
    "Authentification Forte Microsoft",     # French ULiège page (observed)
    "Authentification forte Microsoft",
    "Authentification renforcée Microsoft",
    "Microsoft strong authentication",
)
ULIEGE_PASSWORD_CHOICES = (
    "Username and Password",                # English ULiège page
    "Identifiant et mot de passe",
    "Identifiant et Mot de passe",
    "Nom d’utilisateur et mot de passe",
    "Nom d'utilisateur et mot de passe",
)
ULIEGE_SIGNIN_CHOICES = ULIEGE_MICROSOFT_CHOICES + ULIEGE_PASSWORD_CHOICES
ULIEGE_SUBMIT_CHOICES = ("Continuer", "Continue", "Se connecter", "Connexion", "Sign in")

MS_ACCOUNT_PICKER_HEADINGS = (
    "Pick an account", "Choose an account", "Choisir un compte",
    "Choisissez un compte", "Sélectionner un compte", "Sélectionnez un compte",
)
MS_OTHER_ACCOUNT = ("Use another account", "Utiliser un autre compte", "Utilisez un autre compte")
MS_PASSWORD_INSTEAD = (
    "Use your password instead", "Sign in with a password",
    "Utiliser votre mot de passe", "Utiliser plutôt votre mot de passe",
    "Utiliser mon mot de passe", "Utiliser un mot de passe à la place",
    "Se connecter avec un mot de passe",
)
MS_VERIFICATION_CODE = (
    "Use a verification code", "Use a code from my authenticator",
    "Use a verification code from my mobile app", "Use a code", "Enter a code",
    "Utiliser un code de vérification", "Entrer un code de vérification",
    "Saisir un code de vérification", "Code de vérification",
    "Utiliser un code", "Entrer un code", "Saisir un code",
    "Utiliser un code de mon application Microsoft Authenticator",
    "Utiliser un code de mon application d’authentification",
    "Utiliser un code de mon application d'authentification",
    "Utiliser un code de mon application mobile",
    "Utiliser un code provenant de mon application",
    "Utiliser un code de l'application Microsoft Authenticator",
    "Utiliser un code de l’application Microsoft Authenticator",
    "Utiliser un code de mon application d'authentification",
    "Utiliser un code de l'application mobile",
)
MS_OTHER_METHODS = (
    "Sign in another way", "Use a different verification option",
    "Use another method", "I can't use my Microsoft Authenticator",
    "I can't use my Authenticator app right now",
    "Se connecter d'une autre manière", "Se connecter autrement",
    "Utiliser une autre méthode", "Choisir une autre méthode",
    "Autres façons de se connecter", "Autres méthodes de connexion",
    "Je ne peux pas utiliser mon application Microsoft Authenticator",
    "Je ne peux pas utiliser Microsoft Authenticator pour l'instant",
    "Je ne peux pas utiliser mon application d'authentification",
    "Je n'ai pas accès à Microsoft Authenticator",
    "Autres méthodes de vérification", "Autres options de connexion",
    "Essayer une autre méthode",
)
MS_STAY_SIGNED_IN_HEADINGS = (
    "Stay signed in", "Rester connecté", "Rester connectée", "Rester connectés",
)
MS_CONFIRM_YES = ("Yes", "Oui")
F5_SKIP_INSPECTION = (
    "Skip Inspection", "Skip inspection",
    "Ignorer l'inspection", "Ignorer l’inspection",
    "Passer l'inspection", "Passer l’inspection",
    "Ignorer la vérification", "Ignorer les vérifications",
    "Ignorer l'analyse", "Ignorer l’analyse",
)

USER = getpass.getuser()


def host(url):
    parsed = urlsplit(url)
    return (parsed.hostname or "").lower() if parsed.scheme == "https" else ""


def microsoft_host(url):
    hostname = host(url)
    return hostname == "microsoftonline.com" or hostname.endswith(".microsoftonline.com")


def keychain_password(service):
    return subprocess.check_output(
        ["security", "find-generic-password", "-a", USER, "-s", service, "-w"],
        text=True,
        stderr=subprocess.DEVNULL,
    ).strip()


def otp():
    """Generate a Microsoft-compatible RFC 6238 TOTP without oath-toolkit.

    Base32 seed belongs to the current user and is retrieved from Keychain.
    Never log the seed or the generated one-time code.
    """
    while time.time() % 30 > 23:
        time.sleep(0.4)
    secret = re.sub(r"[\s-]+", "", keychain_password("uliege-mfa-totp")).upper()
    secret += "=" * ((-len(secret)) % 8)
    key = base64.b32decode(secret, casefold=True)
    counter = struct.pack(">Q", int(time.time() // 30))
    digest = hmac.new(key, counter, hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    value = struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF
    return f"{value % 1_000_000:06d}"


def frames(context):
    result = []
    for page in list(context.pages):
        if not page.is_closed():
            try:
                result.extend(list(page.frames))
            except PlaywrightError:
                pass
    return result


def visible_field(frame, selectors):
    for selector in selectors:
        try:
            item = frame.locator(selector).first
            if item.is_visible() and item.is_enabled():
                return item
        except PlaywrightError:
            pass
    return None


def click_label(frame, label):
    """Click visible controls by accessible name, input value, or rendered text.

    Some ULiège choices are styled form controls, not normal HTML buttons.
    A disappearing node during navigation is normal and retried by the caller.
    """
    regex = re.compile(
        r"^\s*" + re.escape(label).replace(r"\ ", r"\s+").replace("'", r"['’‘]") + r"\s*$", re.I
    )
    candidates = [
        frame.get_by_role("button", name=regex),
        frame.get_by_role("link", name=regex),
        frame.get_by_text(regex),
    ]
    for candidate in candidates:
        try:
            for i in range(min(candidate.count(), 8)):
                element = candidate.nth(i)
                if element.is_visible() and element.is_enabled():
                    element.click(timeout=1800)
                    return True
        except PlaywrightError:
            # The click may already have caused a navigation.
            pass

    # The fallback works with styled <input>, clickable <div>, and <label>.
    # It inspects what's actually displayed, instead of assuming a tag type.
    try:
        return bool(frame.evaluate(r"""(label) => {
          const norm = s => (s || '').normalize('NFKD')
            .replace(/[\u0300-\u036f]/g, '').replace(/[’‘]/g, "'")
            .replace(/\s+/g, ' ').trim().toLowerCase();
          const wanted = norm(label);
          const visible = el => {
            const s = getComputedStyle(el), r = el.getBoundingClientRect();
            return s.display !== 'none' && s.visibility !== 'hidden' &&
                   r.width > 0 && r.height > 0;
          };
          const nodes = [...document.querySelectorAll(
            'button, a, input[type=submit], input[type=button], [role=button], [onclick], label, div, span'
          )].filter(visible);
          const text = el => el instanceof HTMLInputElement ? el.value :
            (el.innerText || el.textContent || el.getAttribute('aria-label') || '');
          const choices = nodes.map(el => ({el, text: norm(text(el))}))
            .filter(o => o.text === wanted);
          if (!choices.length) return false;
          // Prefer an actual control over a descendant or parent wrapper.
          const rank = o => /^(BUTTON|A|INPUT)$/.test(o.el.tagName) ? 0 :
            o.el.matches('[role=button], [onclick]') ? 1 : 2;
          choices.sort((a, b) => rank(a) - rank(b));
          const matched = choices[0].el;
          const target = matched.closest('button, a, input, [role=button], [onclick], label') || matched;
          target.click();
          return true;
        }""", label))
    except PlaywrightError:
        return False


def click_saved_account(frame, email):
    """Pick only the Microsoft account matching ULIEGE_EMAIL.

    Microsoft's account picker uses clickable tiles that often have no
    button/link role, so generic `get_by_role`-only helpers miss them.
    """
    email_pattern = re.compile(r"^\s*" + re.escape(email) + r"\s*$", re.I)
    candidates = [
        frame.locator('[data-test-id="accountTile"]').filter(has_text=email_pattern),
        frame.locator('[data-test-id="signInName"]').filter(has_text=email_pattern),
        frame.locator('#tilesHolder').get_by_text(email_pattern),
        frame.get_by_text(email_pattern),
    ]
    for candidate in candidates:
        try:
            for i in range(min(candidate.count(), 5)):
                item = candidate.nth(i)
                if item.is_visible() and item.is_enabled():
                    item.click(timeout=2500)
                    return True
        except PlaywrightError:
            # The click may have initiated a full-page redirect.
            # Other candidates are tried if no click was acknowledged.
            pass

    # Fallback for account tiles rendered with unusual nested elements.
    # Only click when the *configured* email is found, never a random tile.
    try:
        return bool(frame.evaluate(r"""(email) => {
          const normalize = value => (value || '').trim().toLowerCase();
          const expected = normalize(email);
          const visible = node => {
            const style = getComputedStyle(node), rect = node.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0 &&
              style.visibility !== 'hidden' && style.display !== 'none';
          };
          const nodes = [...document.querySelectorAll('*')];
          const target = nodes.find(el =>
            el.children.length === 0 && visible(el) &&
            normalize(el.textContent) === expected
          );
          if (!target) return false;
          const tile = target.closest('[data-test-id="accountTile"], button, [role=button], a') || target;
          tile.click();
          return true;
        }""", email))
    except PlaywrightError:
        return False


def visible_signin_actions(frame):
    """Summarize visible form controls for debugging without logging secrets."""
    try:
        return frame.evaluate(r"""() => {
          const nodes = document.querySelectorAll(
            'a, button, input[type=submit], input[type=button], [role=button]'
          );
          return [...nodes].filter(el => {
            const r = el.getBoundingClientRect(), s = getComputedStyle(el);
            return r.width > 0 && r.height > 0 && s.display !== 'none';
          }).map(el => (el instanceof HTMLInputElement ? el.value :
            el.innerText || el.getAttribute('aria-label') || '')
              .trim().replace(/\s+/g,' ').slice(0,100))
            .filter(Boolean).filter(t =>
              /microsoft|authenti|username|password|mot de passe|continuer|continue|connexion/i.test(t)
            ).slice(0,10);
        }""")
    except PlaywrightError:
        return []


def click_any(frame, labels):
    for label in labels:
        if click_label(frame, label):
            return label
    return None


def submit(frame, field):
    button = visible_field(frame, [
        "#idSubmit_SAOTCC_Continue",
        "#idSIButton9",
        "button[type=submit]",
        "input[type=submit]",
    ])
    if button:
        try:
            button.click(timeout=3500)
            return
        except PlaywrightError:
            pass
    try:
        field.press("Enter", timeout=2000)
    except PlaywrightError:
        pass


def f5_session(context):
    try:
        cookies = context.cookies(["https://vpn-2fa.uliege.be", "https://vpn.uliege.be"])
    except PlaywrightError:
        return None
    # Prefer cookies scoped to the actual tunnel server.
    for domain in ("vpn-2fa.uliege.be", "vpn.uliege.be"):
        for c in cookies:
            if c["name"] == "MRHSession" and c["value"] and c["domain"].lstrip(".") in {domain, "uliege.be"}:
                return c["value"]
    return None


def authenticated_f5_frame(frame):
    url = urlsplit(frame.url)
    return host(frame.url) in F5_HOSTS and (url.path == "/vdesk" or url.path.startswith("/vdesk/"))


def label_visible(frame, labels):
    """Test whether an action label is visible without clicking it.

    Match only actionable elements, not incidental documentation or headings.
    """
    for label in labels:
        regex = re.compile(re.escape(label).replace(r"\ ", r"\s+"), re.I)
        for role in ("button", "link"):
            try:
                if frame.get_by_role(role, name=regex).first.is_visible():
                    return True
            except PlaywrightError:
                continue
        try:
            item = frame.get_by_text(re.compile(r"^\s*" + re.escape(label) + r"\s*$", re.I)).first
            if item.is_visible() and item.is_enabled():
                return True
        except PlaywrightError:
            continue
    return False


def endpoint_inspection_visible(frame):
    """Observe an F5 inspection choice in either language.

    Seeing the choice isn't proof that VPN authorization succeeded.
    """
    return label_visible(frame, F5_SKIP_INSPECTION)


def normalize_ui_text(text):
    """Compare French UI strings regardless of accents and apostrophe style."""
    text = unicodedata.normalize("NFKD", text)
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    return " ".join(text.replace("’", "'").replace("‘", "'").casefold().split())


def microsoft_stay_signed_in_prompt(frame):
    """Only click Yes/Oui when Microsoft's stay-signed-in question is shown.

    A generic 'Oui' on another confirmation page must not be clicked blindly.
    """
    try:
        body = normalize_ui_text(frame.locator("body").inner_text(timeout=1200))
    except PlaywrightError:
        return False
    return any(normalize_ui_text(label) in body for label in MS_STAY_SIGNED_IN_HEADINGS)


class F5Completion:
    """Shared manual/automatic portal completion; early SAML cookies aren't success."""
    def __init__(self):
        self.saw_inspection = False
        self.candidate = None
        self.since = None

    def observe(self, context, current_frames=None, now=None):
        current_frames = frames(context) if current_frames is None else current_frames
        now = time.monotonic() if now is None else now
        session = f5_session(context)
        inspection = any(host(f.url) in F5_HOSTS and endpoint_inspection_visible(f)
                         for f in current_frames)
        if inspection:
            self.saw_inspection = True
        if session and not inspection and any(authenticated_f5_frame(f) for f in current_frames):
            return session
        # /my.policy is accepted only after an actual inspection choice was
        # observed and disappeared. ACS navigation alone proves nothing.
        landing = any(host(f.url) in F5_HOSTS and urlsplit(f.url).path == "/my.policy"
                      for f in current_frames)
        identity_page = any(microsoft_host(f.url) or host(f.url) == "idp.uliege.be"
                            for f in current_frames)
        if session and self.saw_inspection and not inspection and landing and not identity_page:
            if session != self.candidate:
                self.candidate, self.since = session, now
            if now - self.since >= 2:
                return session
        else:
            self.candidate, self.since = None, None
        return None


def auth(headless, email, username=None, timeout=240):
    PROFILE.mkdir(parents=True, exist_ok=True)
    PROFILE.chmod(0o700)

    with sync_playwright() as playwright:
        context = playwright.chromium.launch_persistent_context(
            str(PROFILE), channel="chrome", headless=headless
        )
        try:
            # Leave Microsoft SSO intact; do not trust old F5 portal cookies.
            context.clear_cookies(name=re.compile(
                r"^(MRHSession|F5_ST|LastMRH_Session|MRHSequence)$"
            ))
            # Remove any restored tabs; otherwise an old ULiège selector can
            # repeatedly steal priority from the new Microsoft login tab.
            for old_page in list(context.pages):
                try:
                    old_page.close()
                except PlaywrightError:
                    pass
            page = context.new_page()
            print("Opening ULiège VPN authentication...", flush=True)
            page.goto(PORTAL, wait_until="domcontentloaded", timeout=60000)

            last_stage = None
            last_click = {}
            last_host_state = None
            completion = F5Completion()
            deadline = time.monotonic() + timeout

            def cooldown(key, seconds=3):
                now = time.monotonic()
                if now - last_click.get(key, 0) < seconds:
                    return False
                last_click[key] = now
                return True

            def announce(stage):
                nonlocal last_stage
                if stage != last_stage:
                    print(stage, flush=True)
                    last_stage = stage

            while time.monotonic() < deadline:
                fs = frames(context)
                hosts = tuple(sorted({host(f.url) for f in fs if host(f.url)}))
                if hosts != last_host_state:
                    print("Browser hosts:", ", ".join(hosts), flush=True)
                    last_host_state = hosts

                session = completion.observe(context, fs)
                if session:
                    print("Authenticated F5 portal reached; session acquired.", flush=True)
                    return session

                # F5 endpoint check is an explicit choice in the portal.
                # The university itself offers Skip Inspection, with possible
                # resource restrictions; do not claim this passes inspection.
                selected = False
                for f in fs:
                    if host(f.url) not in F5_HOSTS:
                        continue
                    if cooldown("f5-skip", 5) and click_any(f, F5_SKIP_INSPECTION):
                        announce("Selecting the portal's Skip Inspection option...")
                        selected = True
                        break
                if selected:
                    time.sleep(0.8)
                    continue

                # Microsoft Entra login, including passwordless sign-in and
                # switching from push notification to verification codes.
                for f in fs:
                    if not microsoft_host(f.url):
                        continue

                    # 0. Microsoft may first show "Pick an account" instead
                    # of a username field. Select the configured saved account.
                    # Account tiles are often <div>s, not accessible buttons.
                    try:
                        picker_visible = label_visible(f, MS_ACCOUNT_PICKER_HEADINGS) or any(
                            f.get_by_text(re.compile(re.escape(heading), re.I)).first.is_visible()
                            for heading in MS_ACCOUNT_PICKER_HEADINGS
                        )
                    except PlaywrightError:
                        picker_visible = False
                    if picker_visible and cooldown("account-picker", 3):
                        if click_saved_account(f, email):
                            announce("Selecting saved Microsoft university account...")
                            selected = True
                            break
                        # If the account is not on this device, proceed with
                        # normal sign-in rather than choosing a different user.
                        if click_any(f, MS_OTHER_ACCOUNT):
                            announce("Using a different Microsoft account entry...")
                            selected = True
                            break
                        announce("Microsoft account picker visible; waiting for account tile...")

                    # 1. Switch off the phone-approval/passwordless screen (EN/FR).
                    if cooldown("passwordless", 5):
                        label = click_any(f, MS_PASSWORD_INSTEAD)
                        if label:
                            announce("Selected password instead of phone approval.")
                            selected = True
                            break

                    # 2. If TOTP entry is visible, generate a fresh code.
                    otpfield = visible_field(f, [
                        'input[name="otc"]', '#idTxtBx_SAOTCC_OTC',
                        'input[autocomplete="one-time-code"]',
                    ])
                    if otpfield and cooldown("otp", 12):
                        announce("Submitting verification code...")
                        otpfield.fill(otp())
                        submit(f, otpfield)
                        selected = True
                        break

                    # 3. Password and username fields.
                    password = visible_field(f, ['#i0118', 'input[name="passwd"]'])
                    if password and cooldown("ms-password", 8):
                        announce("Entering Microsoft password...")
                        password.fill(keychain_password("uliege-vpn-password"))
                        submit(f, password)
                        selected = True
                        break
                    user = visible_field(f, ['#i0116', 'input[name="loginfmt"]', 'input[type="email"]'])
                    if user and cooldown("ms-username", 8):
                        announce("Entering Microsoft username...")
                        user.fill(email)
                        submit(f, user)
                        selected = True
                        break

                    # 4. Choose verification code rather than mobile approval (EN/FR).
                    if cooldown("totp-option", 4):
                        label = click_any(f, MS_VERIFICATION_CODE)
                        if label:
                            announce("Selected Microsoft verification code method.")
                            selected = True
                            break
                    if cooldown("other-option", 7):
                        label = click_any(f, MS_OTHER_METHODS)
                        if label:
                            announce("Opening other Microsoft verification methods...")
                            selected = True
                            break

                    if cooldown("stay", 5):
                        if microsoft_stay_signed_in_prompt(f) and click_any(f, MS_CONFIRM_YES):
                            announce("Confirming Microsoft sign-in...")
                            selected = True
                            break

                if selected:
                    time.sleep(0.7)
                    continue

                # ULiège's idp hosts MORE THAN ONE screen. The first screen
                # offers "Microsoft MFA Authentification", while another screen
                # offers "Username and Password". Never assume every idp page
                # is the first screen: inspect the available controls instead.
                for f in fs:
                    if host(f.url) != "idp.uliege.be":
                        continue

                    # If we're already on the local username/password form,
                    # fill it BEFORE trying any provider-selection button.
                    pw = visible_field(f, ['input[type="password"]'])
                    if pw:
                        if username and cooldown("local-password", 8):
                            userfield = visible_field(f, [
                                'input[placeholder*="Identifiant"]',
                                'input[placeholder*="identifiant"]',
                                'input[placeholder*="Username"]',
                                'input[placeholder*="Nom d"]',
                                'input[name="username"]',
                                'input[name="user"]',
                                'input[type="text"]',
                            ])
                            if userfield:
                                announce("Entering ULiège credentials...")
                                userfield.fill(username)
                                pw.fill(keychain_password("uliege-vpn-password"))
                                if not click_any(f, ULIEGE_SUBMIT_CHOICES):
                                    submit(f, pw)
                                selected = True
                                break
                        elif not username:
                            raise RuntimeError(
                                "ULiège requested an identifier. Set ULIEGE_USERNAME "
                                "to your ULiège username (e.g. s123456), then retry."
                            )
                        continue

                    if cooldown("uliege-choice", 3):
                        # ULiège localizes its authentication-provider selector.
                        # The English-language screen uses "Microsoft MFA
                        # Authentification" while the French one currently
                        # uses "Authentification Forte Microsoft". Match both
                        # without selecting the unrelated federal eID/itsme option.
                        # At the primary chooser, prefer Microsoft; the local
                        # username/password option is a later federated step.
                        choice = click_any(f, ULIEGE_MICROSOFT_CHOICES)
                        if not choice:
                            choice = click_any(f, ULIEGE_PASSWORD_CHOICES)
                        if choice:
                            announce(f"Selected ULiège option: {choice}")
                            selected = True
                            break
                        if cooldown("uliege-debug", 15):
                            address = urlsplit(f.url)
                            print(
                                "ULiège page has no clickable matching option at",
                                address.path,
                                flush=True,
                            )
                            print(
                                "Visible login actions:", visible_signin_actions(f),
                                flush=True,
                            )
                if selected:
                    time.sleep(0.7)
                    continue

                time.sleep(0.5)

            if f5_session(context):
                print(
                    "F5 session cookie was present but the authenticated portal could not be confirmed.",
                    flush=True,
                )
            else:
                print("F5 session cookie was never received.", flush=True)
            print("Timed out during authentication. Current page locations:", flush=True)
            for f in frames(context):
                info = urlsplit(f.url)
                print("  ", info.hostname, info.path, flush=True)  # No sensitive query strings
            raise RuntimeError(
                "Authentication did not finish. Try --headed --refresh. "
                "The script never prints passwords, TOTP secrets, or cookies."
            )
        finally:
            context.close()


HELPER = "/Library/PrivilegedHelperTools/be.uliege.vpn/helper"


def helper_status():
    result = subprocess.run(["/usr/bin/sudo", "-n", HELPER, "status"],
                            capture_output=True, text=True, timeout=5)
    return result.stdout.strip() if result.returncode == 0 else "UNKNOWN"


def start_tunnel(session, timeout=8):
    result = subprocess.run(["/usr/bin/sudo", "-n", HELPER, "start"],
                            input=session + "\n", capture_output=True, text=True, timeout=15)
    if result.returncode != 0:
        raise RuntimeError("VPN support could not start. Check one-time setup.")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = helper_status()
        if state != "STOPPED":
            print("VPN process started; routing is unverified. Only explicit Ctrl+C disconnects.", flush=True)
            return True
        time.sleep(0.5)
    return False


def wait_for_tunnel():
    try:
        while True:
            if helper_status() == "STOPPED":
                return
            time.sleep(2)
    except KeyboardInterrupt:
        # A status timeout must never initiate stop. Only the user's interrupt can.
        subprocess.run(["/usr/bin/sudo", "-n", HELPER, "stop"], check=True, timeout=25)


def main():
    parser = argparse.ArgumentParser(description="ULiège VPN via Microsoft MFA + gof5")
    parser.add_argument("--headed", action="store_true", help="Show Chrome login for debugging")
    parser.add_argument("--refresh", action="store_true", help="Force a new Microsoft sign-in")
    parser.add_argument("--auth-only", action="store_true", help="Authenticate but do not connect VPN")
    parser.add_argument("--emit-session", action="store_true", help="Return session over a private parent-process pipe")
    parser.add_argument("--timeout", type=int, default=240, help="Browser authentication timeout (seconds)")
    args = parser.parse_args()
    email = os.environ.get("ULIEGE_EMAIL", "").strip()
    if not email:
        parser.error("Set ULIEGE_EMAIL to your university Microsoft email address")
    username = os.environ.get("ULIEGE_USERNAME", "").strip() or None
    if not args.auth_only and helper_status() != "STOPPED":
        print("An existing or unverified VPN session may be running. Use the menu bar app to manage it.", flush=True)
        return

    if not args.refresh and not args.auth_only:
        saved = keyring.get_password(F5_SESSION_SERVICE, USER)
        if saved:
            print("Trying the previously authenticated F5 session...", flush=True)
            proc = start_tunnel(saved, timeout=30)
            if proc:
                print("VPN connected. Ctrl+C disconnects.", flush=True)
                wait_for_tunnel()
                return
            print("Saved session failed; opening Microsoft sign-in.", flush=True)

    session = auth(headless=not args.headed, email=email, username=username, timeout=args.timeout)
    if args.auth_only:
        if args.emit_session:
            # Private stdout pipe read by Swift; do not log this line.
            encoded = base64.b64encode(session.encode("utf-8")).decode("ascii")
            print("ULIEGE_F5_SESSION_B64:" + encoded, flush=True)
            return
        try:
            keyring.set_password(F5_SESSION_SERVICE, USER, session)
        except Exception:
            print("Keychain error: could not save the authenticated F5 session.", file=sys.stderr)
            raise SystemExit(1)
        print("Authenticated session stored in macOS Keychain; VPN not started.", flush=True)
        return
    proc = start_tunnel(session)
    if not proc:
        raise SystemExit("Could not connect using the authenticated session. Try --headed --refresh.")
    try:
        keyring.set_password(F5_SESSION_SERVICE, USER, session)
    except Exception:
        print("Session couldn't be saved for reuse; VPN left running.", flush=True)
    print("VPN running (routing unverified). Ctrl+C disconnects.", flush=True)
    wait_for_tunnel()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        raise SystemExit(130)
    except subprocess.CalledProcessError as e:
        print(f"A required command failed: {e.cmd[0]}", file=sys.stderr)
        raise SystemExit(1)
