"""Optional real-browser click tests for authentication-choice labels.

Runs on machines with Playwright and a local Chromium browser; skips in CI
where dependency installation has not happened. Uses local HTML only:
never contacts ULiège/Microsoft or handles real credentials.
"""
import os
import shutil
import sys
import types
import unittest
from pathlib import Path


class LocalizedButtonBrowserTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            from playwright.sync_api import sync_playwright
        except ImportError:
            raise unittest.SkipTest("Playwright not installed")
        executable = os.environ.get("ULIEGE_TEST_CHROMIUM") or shutil.which("chromium") or shutil.which("chromium-browser")

        # Only in test process; avoids the macOS Keychain backend dependency.
        if "keyring" not in sys.modules:
            sys.modules["keyring"] = types.ModuleType("keyring")
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Scripts"))
        import automatic_auth
        cls.auth = automatic_auth
        cls.pw = sync_playwright().start()
        try:
            cls.browser = cls.pw.chromium.launch(**({"executable_path": executable} if executable else {}), headless=True)
        except Exception as e:
            cls.pw.stop()
            if os.environ.get("ULIEGE_REQUIRE_BROWSER_TESTS") == "1":
                raise
            raise unittest.SkipTest(f"Chromium unavailable: {type(e).__name__}")

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, "browser"):
            cls.browser.close()
            cls.pw.stop()

    def setUp(self):
        self.page = self.browser.new_page()

    def tearDown(self):
        self.page.close()

    def check_click(self, label, choices):
        self.page.set_content(f'<button onclick="window.selected=1">{label}</button>')
        self.assertIsNotNone(self.auth.click_any(self.page.main_frame, choices))
        self.assertEqual(self.page.evaluate("window.selected"), 1)

    def test_uliege_french_provider_and_federal_not_selected(self):
        self.page.set_content('''
          <button onclick="window.selected='federal'">Authentification fédérale (itsme, eID...)</button>
          <button onclick="window.selected='microsoft'">Authentification Forte Microsoft</button>
        ''')
        self.assertTrue(self.auth.click_any(self.page.main_frame, self.auth.ULIEGE_MICROSOFT_CHOICES))
        self.assertEqual(self.page.evaluate("window.selected"), "microsoft")

    def test_uliege_english_provider(self):
        self.check_click("Microsoft MFA Authentification", self.auth.ULIEGE_MICROSOFT_CHOICES)

    def test_french_local_password_choice(self):
        self.check_click("Identifiant et mot de passe", self.auth.ULIEGE_PASSWORD_CHOICES)

    def test_french_passwordless(self):
        self.check_click("Utiliser votre mot de passe", self.auth.MS_PASSWORD_INSTEAD)

    def test_french_code(self):
        self.check_click("Utiliser un code de vérification", self.auth.MS_VERIFICATION_CODE)

    def test_french_other_method(self):
        self.check_click("Se connecter d'une autre manière", self.auth.MS_OTHER_METHODS)

    def test_french_f5_inspection(self):
        self.page.set_content('<button>Ignorer l’inspection</button>')
        self.assertTrue(self.auth.endpoint_inspection_visible(self.page.main_frame))
        self.assertIsNotNone(self.auth.click_any(self.page.main_frame, self.auth.F5_SKIP_INSPECTION))

    def test_curly_apostrophe_in_microsoft_labels(self):
        self.check_click("Se connecter d’une autre manière", self.auth.MS_OTHER_METHODS[0:])

    def test_accents_and_case_in_control_labels(self):
        self.check_click("AUTHENTIFICATION FORTE MICROSOFT", self.auth.ULIEGE_MICROSOFT_CHOICES)

    def test_similar_label_is_not_clicked(self):
        self.page.set_content('<button onclick="window.selected=1">Ne pas utiliser votre mot de passe</button>')
        self.assertIsNone(self.auth.click_any(self.page.main_frame, self.auth.MS_PASSWORD_INSTEAD))
        self.assertIsNone(self.page.evaluate("window.selected"))

    def test_saved_account_requires_exact_email(self):
        self.page.set_content('''<button onclick="window.selected='wrong'">xstudent@example.test</button>
            <button onclick="window.selected='correct'">student@example.test</button>''')
        self.assertTrue(self.auth.click_saved_account(self.page.main_frame, "student@example.test"))
        self.assertEqual(self.page.evaluate("window.selected"), "correct")

    def test_french_stay_signed_in_scope(self):
        self.page.set_content('<div>Voulez-vous rester connecté ?</div><button>Oui</button>')
        self.assertTrue(self.auth.microsoft_stay_signed_in_prompt(self.page.main_frame))
        self.page.set_content('<div>Confirmer la suppression ?</div><button>Oui</button>')
        self.assertFalse(self.auth.microsoft_stay_signed_in_prompt(self.page.main_frame))


if __name__ == "__main__":
    unittest.main()
