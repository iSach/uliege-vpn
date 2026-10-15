"""Portal state tests use synthetic cookies and frames, never an account."""
import ast
import time
import types
import unittest
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
TREE = ast.parse((ROOT / 'Scripts/automatic_auth.py').read_text())
NAMES = {'host', 'microsoft_host', 'authenticated_f5_frame', 'F5Completion'}
NS = dict(urlsplit=urlsplit, time=time, F5_HOSTS={'vpn.uliege.be', 'vpn-2fa.uliege.be'},
          frames=lambda context: context.frames, f5_session=lambda context: context.session,
          endpoint_inspection_visible=lambda frame: frame.inspection)
exec(compile(ast.Module(body=[node for node in TREE.body if isinstance(node, (ast.FunctionDef, ast.ClassDef))
                             and node.name in NAMES], type_ignores=[]), 'auth_states', 'exec'), NS)


class CompletionTests(unittest.TestCase):
    def setUp(self):
        self.flow = NS['F5Completion']()
        self.context = types.SimpleNamespace(session='synthetic-session-only', frames=[])

    def page(self, path='/my.policy', inspection=False, host='vpn.uliege.be', scheme='https'):
        self.context.frames = [types.SimpleNamespace(url=f'{scheme}://{host}{path}', inspection=inspection)]

    def test_early_cookie_and_acs_never_complete(self):
        for path in ['/my.policy', '/saml/sp/profile/post/acs', '/vdeskevil']:
            self.page(path)
            self.assertIsNone(self.flow.observe(self.context, now=10))
            self.assertIsNone(self.flow.observe(self.context, now=20))

    def test_vdesk_completes_only_over_https_on_exact_f5_host(self):
        self.page('/vdesk/webtop.eui')
        self.assertEqual(self.flow.observe(self.context), self.context.session)
        for hostname, scheme in [('vpn.uliege.be.evil.test', 'https'), ('vpn.uliege.be', 'http')]:
            self.page('/vdesk/', host=hostname, scheme=scheme)
            self.assertIsNone(self.flow.observe(self.context))

    def test_manual_inspection_waits_until_choice_disappears_and_settles(self):
        self.page(inspection=True)
        self.assertIsNone(self.flow.observe(self.context, now=0))
        self.page()
        self.assertIsNone(self.flow.observe(self.context, now=1))
        self.assertIsNone(self.flow.observe(self.context, now=2))
        self.assertEqual(self.flow.observe(self.context, now=3), self.context.session)

    def test_cookie_change_resets_settling_window(self):
        self.page(inspection=True)
        self.flow.observe(self.context, now=0)
        self.page()
        self.flow.observe(self.context, now=1)
        self.context.session = 'different-synthetic-session'
        self.assertIsNone(self.flow.observe(self.context, now=4))
        self.assertEqual(self.flow.observe(self.context, now=6), self.context.session)

    def test_identity_page_blocks_policy_completion(self):
        self.page(inspection=True)
        self.flow.observe(self.context, now=0)
        self.page()
        self.context.frames.append(types.SimpleNamespace(url='https://login.microsoftonline.com/login', inspection=False))
        self.assertIsNone(self.flow.observe(self.context, now=10))
        self.assertIsNone(self.flow.observe(self.context, now=20))

    def test_microsoft_host_requires_dot_boundary_and_https(self):
        for url in ['https://evilmicrosoftonline.com', 'http://login.microsoftonline.com',
                    'https://login.microsoftonline.com.evil.test']:
            self.assertFalse(NS['microsoft_host'](url))
        self.assertTrue(NS['microsoft_host']('https://login.microsoftonline.com'))

    def test_health_checks_cannot_stop_session(self):
        swift = (ROOT / 'Sources/ULiegeVPNApp.swift').read_text()
        self.assertNotIn('stopHelper()', swift)
        self.assertEqual(swift.count('VPNConstants.helper, "stop"'), 1)
        self.assertNotIn('stop_tunnel', (ROOT / 'Scripts/automatic_auth.py').read_text())


if __name__ == '__main__':
    unittest.main()
