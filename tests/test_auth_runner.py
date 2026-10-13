"""Checks the unified auth dispatcher and absence of the uv runtime."""
import ast
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "Scripts"

class AuthPackagingTests(unittest.TestCase):
    def test_imports_are_collectable_by_pyinstaller(self):
        tree = ast.parse((SCRIPTS / "auth_runner.py").read_text())
        imports = {alias.name for node in tree.body
                   if isinstance(node, ast.Import) for alias in node.names}
        self.assertTrue({"automatic_auth", "browser_auth"} <= imports)

    def test_runtime_scripts_do_not_require_uv(self):
        for path in SCRIPTS.glob("*.py"):
            source = path.read_text()
            self.assertNotIn("uv run", source)
            self.assertNotIn('dependencies = ["playwright"', source)

if __name__ == "__main__": unittest.main()
