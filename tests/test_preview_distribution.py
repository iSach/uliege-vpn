"""Static regression checks for preview packaging. Native tests run on CI macOS."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent


class PreviewDistribution(unittest.TestCase):
    def test_opt_out_does_not_overwrite_local_installation(self):
        build = (ROOT / "build.sh").read_text()
        self.assertIn('INSTALL_APP="${INSTALL_APP:-0}"', build)
        self.assertIn('if [[ "$INSTALL_APP" == 1 ]]; then', build)
        self.assertIn('Contents/Resources', build)

    def test_dmg_requires_both_vpn_and_auth_runtime(self):
        script = (ROOT / "Packaging/create-dmg.sh").read_text()
        self.assertIn('AuthRuntime/uliege-auth', script)
        self.assertIn('VPNRuntime/gof5', script)
        self.assertIn('hdiutil create', script)
        self.assertIn('UNSIGNED', script)

    def test_user_visible_support_installer_bundled(self):
        build = (ROOT / "build.sh").read_text()
        self.assertIn('Install VPN Support.command', build)
        model = (ROOT / "Sources/ULiegeVPNApp.swift").read_text()
        self.assertIn('openSupportInstaller()', model)
        self.assertIn('Button("Install VPN Support…")', model)

    def test_privileged_installer_uses_fixed_path_for_go5(self):
        script = (ROOT / "install-helper.sh").read_text()
        self.assertIn('VPNRuntime/gof5', script)
        privileged = (ROOT / 'Helper/install-root.sh').read_text()
        self.assertIn('visudo -cf', privileged)
        self.assertIn('NOPASSWD: NOSETENV:', privileged)  # explicit, documented release blocker

    def test_release_is_only_a_draft(self):
        action = (ROOT / ".github/workflows/draft-release.yml").read_text()
        self.assertIn('--draft', action)
        self.assertIn('release-preview-', action)


if __name__ == "__main__":
    unittest.main()
