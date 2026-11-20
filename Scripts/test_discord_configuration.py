import plistlib
import tempfile
import unittest
from pathlib import Path
from configure_discord import append_configuration, configuration
from report_discord_configuration import report


class DiscordBuildConfigurationTests(unittest.TestCase):
    def test_missing_or_placeholder_values_remain_unconfigured(self):
        for app_id, url in [("", ""), ("YOUR_ID", "https://host.example"),
                            ("123456789012345678", "https://host.example"),
                            ("123456789012345678", "http://activity.test"),
                            ("123456789012345678", "https://[invalid")]:
            self.assertEqual(configuration(app_id, url), ("", ""))

    def test_https_urls_are_not_written_as_xcconfig_comments(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Config.xcconfig"
            self.assertTrue(append_configuration(path, "123456789012345678", "https://activity.test/app"))
            text = path.read_text()
            self.assertIn("https:/$()/activity.test/app", text)
            self.assertNotIn("https://", text)

    def test_actual_plist_report_distinguishes_missing_keys_and_valid_syntax(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Info.plist"
            path.write_bytes(plistlib.dumps({"CFBundleIdentifier": "app.test"}))
            self.assertEqual(report(path)["status"], "setup_required")
            path.write_bytes(plistlib.dumps({"DiscordApplicationClientID": "123456789012345678",
                                            "DiscordActivityURL": "https://activity.test"}))
            self.assertTrue(report(path)["syntax_configured"])
            self.assertFalse(report(path)["deployment_verified"])


if __name__ == "__main__":
    unittest.main()
