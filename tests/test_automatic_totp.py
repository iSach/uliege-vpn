"""RFC 6238 known-answer check for the bundled pure-Python TOTP function.

Extracts only the otp function so Playwright and keyring are not required on CI.
"""
import ast
import base64
import hashlib
import hmac
import re
import struct
import time
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'Scripts' / 'automatic_auth.py'


class TotpTests(unittest.TestCase):
    def test_rfc_6238_seed(self):
        tree = ast.parse(SCRIPT.read_text())
        function = next(x for x in tree.body if isinstance(x, ast.FunctionDef) and x.name == 'otp')
        ns = dict(time=time, base64=base64, hashlib=hashlib, hmac=hmac,
                  struct=struct, re=re, keychain_password=lambda _:
                  base64.b32encode(b'12345678901234567890').decode())
        exec(compile(ast.Module(body=[function], type_ignores=[]), str(SCRIPT), 'exec'), ns)
        with patch.object(time, 'time', side_effect=[60, 59]):
            self.assertEqual(ns['otp'](), '287082')


if __name__ == '__main__':
    unittest.main()
