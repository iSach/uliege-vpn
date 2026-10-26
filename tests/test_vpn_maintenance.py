"""Maintenance acknowledgment and unchanged older sign-in flows; no credentials."""
import ast
import contextlib
import io
import itertools
import re
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import MagicMock
from urllib.parse import urlsplit

SOURCE = Path(__file__).resolve().parents[1] / 'Scripts/automatic_auth.py'
TREE = ast.parse(SOURCE.read_text())


class BrowserError(Exception):
    pass


def load_functions(names, **extra):
    namespace = dict(re=re, urlsplit=urlsplit, PlaywrightError=BrowserError,
                     F5_HOSTS={'vpn.uliege.be', 'vpn-2fa.uliege.be'}, **extra)
    nodes = [n for n in TREE.body if isinstance(n, ast.FunctionDef) and n.name in names]
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(SOURCE), 'exec'), namespace)
    return namespace


class MaintenanceNoticeTests(unittest.TestCase):
    def setUp(self):
        self.ack = load_functions({'host', 'acknowledge_vpn_maintenance'})['acknowledge_vpn_maintenance']

    def frame(self, text, url='https://idp.uliege.be/idp/login'):
        frame = MagicMock()
        frame.url = url
        frame.locator.return_value.inner_text.return_value = text
        frame.get_by_role.return_value.first.is_visible.return_value = True
        frame.get_by_role.return_value.first.is_enabled.return_value = True
        return frame

    def test_known_english_and_french_notice_on_all_supported_hosts(self):
        for hostname in ('idp.uliege.be', 'vpn.uliege.be', 'vpn-2fa.uliege.be'):
            for date in ('26 October 2026', '26 octobre 2026', '26/10/2026', '2026-10-26'):
                with self.subTest(hostname=hostname, date=date):
                    frame = self.frame('PHP2Shell update '+date, 'https://'+hostname+'/my.policy')
                    self.assertTrue(self.ack(frame))
                    frame.get_by_role.return_value.first.click.assert_called_once()

    def test_http_and_lookalike_hosts_are_not_read_or_clicked(self):
        for url in ('http://idp.uliege.be/', 'https://idp.uliege.be.evil.test/',
                    'https://evil.test/', 'https://login.microsoftonline.com/'):
            with self.subTest(url=url):
                frame = self.frame('PHP2Shell 26 October 2026', url)
                self.assertFalse(self.ack(frame))
                frame.locator.assert_not_called()
                frame.get_by_role.assert_not_called()

    def test_old_pages_generic_consent_and_other_notices_are_ignored(self):
        for text in ('Sign in with Microsoft', 'Click here to continue',
                     'Accept these terms. Click here to continue',
                     'Other security update 26 October 2026', 'PHP2Shell update 27 October 2026'):
            with self.subTest(text=text):
                frame = self.frame(text)
                self.assertFalse(self.ack(frame))
                frame.get_by_role.assert_not_called()

    def test_only_exact_continue_labels_are_selected(self):
        frame = self.frame('PHP2Shell 26 October 2026')
        self.assertTrue(self.ack(frame))
        pattern = frame.get_by_role.call_args.kwargs['name']
        for label in ('Click here to continue', 'Cliquez ici pour continuer'):
            self.assertIsNotNone(pattern.fullmatch(label))
        for label in ('Accept all terms', 'Do not Click here to continue', 'Continue'):
            self.assertIsNone(pattern.fullmatch(label))

    def test_hidden_and_disabled_actions_are_not_clicked(self):
        frame = self.frame('PHP2Shell 26 October 2026')
        frame.get_by_role.return_value.first.is_enabled.return_value = False
        frame.get_by_text.return_value.first.is_visible.return_value = False
        self.assertFalse(self.ack(frame))
        frame.get_by_role.return_value.first.click.assert_not_called()

    def test_text_only_action_fallback(self):
        frame = self.frame('PHP2Shell 26 October 2026')
        frame.get_by_role.return_value.first.is_visible.return_value = False
        self.assertTrue(self.ack(frame))
        frame.get_by_text.return_value.first.click.assert_called_once()

    def test_navigation_errors_are_left_for_normal_flow_retry(self):
        frame = self.frame('PHP2Shell 26 October 2026')
        frame.locator.return_value.inner_text.side_effect = BrowserError()
        self.assertFalse(self.ack(frame))

    def test_unrelated_frame_does_not_consume_notice_cooldown(self):
        allow = MagicMock(return_value=True)
        self.assertFalse(self.ack(self.frame('Normal page'), allow))
        allow.assert_not_called()
        self.assertTrue(self.ack(self.frame('PHP2Shell 26 October 2026'), allow))
        allow.assert_called_once()

    def test_active_cooldown_prevents_click(self):
        frame = self.frame('PHP2Shell 26 October 2026')
        self.assertFalse(self.ack(frame, lambda: False))
        frame.get_by_role.assert_not_called()


class AuthLoopCompatibility(unittest.TestCase):
    def exercise(self, notice):
        page = MagicMock()
        page.url = 'https://idp.uliege.be/idp/login' if notice else 'https://vpn.uliege.be/vdesk/'
        page.locator.return_value.inner_text.return_value = 'PHP2Shell update 26 October 2026' if notice else 'VPN connected'
        def clicked(**kwargs):
            page.url = 'https://vpn.uliege.be/vdesk/'
            page.locator.return_value.inner_text.return_value = 'VPN connected'
        page.get_by_role.return_value.first.click.side_effect = clicked
        context = MagicMock()
        context.pages = []
        context.new_page.return_value = page
        browser = MagicMock()
        browser.chromium.launch_persistent_context.return_value = context
        completion = types.SimpleNamespace(observe=lambda ctx, fs: 'synthetic-session' if '/vdesk/' in page.url else None)
        with tempfile.TemporaryDirectory() as temp:
            namespace = load_functions({'host', 'acknowledge_vpn_maintenance', 'auth'},
                PROFILE=Path(temp), PORTAL='https://vpn.uliege.be/mfa',
                sync_playwright=lambda: contextlib.nullcontext(browser),
                frames=lambda ctx: [page], F5Completion=lambda: completion,
                time=types.SimpleNamespace(monotonic=itertools.count(1000).__next__, sleep=lambda _: None),
                keychain_password=MagicMock(side_effect=AssertionError('No credentials required')))
            with contextlib.redirect_stdout(io.StringIO()):
                # Existing positional calls must continue to work unchanged.
                result = namespace['auth'](True, 'student@example.test', 'student', 240)
        self.assertEqual(result, 'synthetic-session')
        context.close.assert_called_once()
        if notice:
            page.get_by_role.return_value.first.click.assert_called_once()
        else:
            page.get_by_role.assert_not_called()

    def test_existing_portal_without_notice_still_completes(self):
        self.exercise(False)

    def test_notice_then_existing_portal_completes(self):
        self.exercise(True)


if __name__ == '__main__':
    unittest.main()
