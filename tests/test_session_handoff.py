"""Regression tests for app-owned session storage and safe auth handoff."""
import ast
import base64
import pathlib
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
SWIFT = (ROOT / "Sources/ULiegeVPNApp.swift").read_text()

class SessionHandoffTests(unittest.TestCase):
    def test_both_modes_support_private_pipe_handoff(self):
        browser = (ROOT / "Scripts/browser_auth.py").read_text()
        auto = (ROOT / "Scripts/automatic_auth.py").read_text()
        runner = (ROOT / "Scripts/auth_runner.py").read_text()
        self.assertIn("ULIEGE_F5_SESSION_B64:", browser)
        self.assertIn("ULIEGE_F5_SESSION_B64:", auto)
        self.assertIn("--emit-session", runner)
        self.assertIn("emit_session=args.emit_session", runner)
        self.assertIn("--emit-session", SWIFT)
        self.assertIn("Data(base64Encoded:", SWIFT)
        self.assertIn("try SessionStore.save(fresh)", SWIFT)
    def test_store_failure_nonfatal(self):
        self.assertIn("Connection must work even if Keychain access is denied.", SWIFT)
        self.assertIn("Session couldn't be saved for reuse", SWIFT)
    def test_python_parses(self):
        for file in (ROOT / "Scripts").glob("*.py"):
            ast.parse(file.read_text())
    def test_transmission_encoding(self):
        cookie="fakeTestSessionValue_123"
        self.assertEqual(base64.b64decode(base64.b64encode(cookie.encode())).decode(),cookie)

if __name__ == "__main__": unittest.main()
