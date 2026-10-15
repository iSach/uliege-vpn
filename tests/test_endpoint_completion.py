"""Static regression guards for F5 inspection completion handling."""
import unittest
from pathlib import Path
SRC = (Path(__file__).resolve().parents[1] / "Scripts/automatic_auth.py").read_text()
SWIFT = (Path(__file__).resolve().parents[1] / "Sources/ULiegeVPNApp.swift").read_text()

class F5CompletionTests(unittest.TestCase):
    def test_observe_manual_inspection(self):
        self.assertIn("def endpoint_inspection_visible(frame):", SRC)
        self.assertIn("endpoint_inspection_visible(f)", SRC)
        self.assertIn("self.saw_inspection = True", SRC)

    def test_auth_and_tunnel_failures_are_distinguishable(self):
        self.assertIn("F5 session cookie was present but", SRC)
        self.assertIn("F5 session cookie was never received.", SRC)
        self.assertIn("tunnelFailureDiagnosis()", SWIFT)
