"""Check the complete EN/FR authentication path without account credentials.

Read the source AST so these tests can run in CI before Playwright is installed.
The optional HTML click tests are in test_localized_browser.py.
"""
import ast
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1] / "Scripts" / "automatic_auth.py"
TREE = ast.parse(SOURCE.read_text(encoding="utf-8"))


def labels(name):
    assignment = next(n for n in TREE.body if isinstance(n, ast.Assign)
                      and any(isinstance(target, ast.Name) and target.id == name
                              for target in n.targets))
    return ast.literal_eval(assignment.value)


def function_source(name):
    node = next(n for n in TREE.body if isinstance(n, ast.FunctionDef) and n.name == name)
    return ast.get_source_segment(SOURCE.read_text(encoding="utf-8"), node)


class LocalizedSigninTests(unittest.TestCase):
    def test_provider_languages(self):
        self.assertIn("Microsoft MFA Authentification", labels("ULIEGE_MICROSOFT_CHOICES"))
        self.assertIn("Authentification Forte Microsoft", labels("ULIEGE_MICROSOFT_CHOICES"))

    def test_username_password_languages(self):
        self.assertIn("Username and Password", labels("ULIEGE_PASSWORD_CHOICES"))
        self.assertIn("Identifiant et mot de passe", labels("ULIEGE_PASSWORD_CHOICES"))
        self.assertIn("Continuer", labels("ULIEGE_SUBMIT_CHOICES"))

    def test_microsoft_account_picker(self):
        self.assertIn("Pick an account", labels("MS_ACCOUNT_PICKER_HEADINGS"))
        self.assertIn("Choisir un compte", labels("MS_ACCOUNT_PICKER_HEADINGS"))
        self.assertIn("Use another account", labels("MS_OTHER_ACCOUNT"))
        self.assertIn("Utiliser un autre compte", labels("MS_OTHER_ACCOUNT"))

    def test_passwordless_to_password(self):
        self.assertIn("Use your password instead", labels("MS_PASSWORD_INSTEAD"))
        self.assertIn("Utiliser votre mot de passe", labels("MS_PASSWORD_INSTEAD"))

    def test_microsoft_totp_and_other_methods(self):
        self.assertIn("Use a verification code", labels("MS_VERIFICATION_CODE"))
        self.assertIn("Utiliser un code de vérification", labels("MS_VERIFICATION_CODE"))
        self.assertIn("Sign in another way", labels("MS_OTHER_METHODS"))
        self.assertIn("Se connecter d'une autre manière", labels("MS_OTHER_METHODS"))

    def test_stay_signed_in_requires_question(self):
        self.assertIn("Stay signed in", labels("MS_STAY_SIGNED_IN_HEADINGS"))
        self.assertIn("Rester connecté", labels("MS_STAY_SIGNED_IN_HEADINGS"))
        self.assertIn("microsoft_stay_signed_in_prompt(f)", function_source("auth"))

    def test_f5_inspection(self):
        self.assertIn("Skip Inspection", labels("F5_SKIP_INSPECTION"))
        self.assertIn("Ignorer l'inspection", labels("F5_SKIP_INSPECTION"))
        self.assertIn("F5_SKIP_INSPECTION", function_source("endpoint_inspection_visible"))

    def test_flow_wires_all_translations(self):
        source = function_source("auth")
        for name in (
            "ULIEGE_MICROSOFT_CHOICES", "ULIEGE_PASSWORD_CHOICES", "ULIEGE_SUBMIT_CHOICES",
            "MS_ACCOUNT_PICKER_HEADINGS", "MS_OTHER_ACCOUNT", "MS_PASSWORD_INSTEAD",
            "MS_VERIFICATION_CODE", "MS_OTHER_METHODS", "MS_CONFIRM_YES", "F5_SKIP_INSPECTION",
        ):
            with self.subTest(name=name):
                self.assertIn(name, source)

    def test_federal_identity_never_autoselected(self):
        for label in labels("ULIEGE_MICROSOFT_CHOICES") + labels("ULIEGE_PASSWORD_CHOICES"):
            self.assertNotIn("fédéral", label.casefold())
            self.assertNotIn("itsme", label.casefold())


if __name__ == "__main__":
    unittest.main()
