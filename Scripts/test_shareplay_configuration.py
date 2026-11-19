import unittest
from report_shareplay_configuration import KEY, configuration_report


class SharePlayConfigurationTests(unittest.TestCase):
    def test_declared_capability_does_not_verify_unsigned_ipa(self):
        report = configuration_report({"CFBundleIdentifier": "app.example"}, {KEY: True}, None, None)
        self.assertTrue(report["projectDeclaresGroupActivities"])
        self.assertIsNone(report["signedGroupSessionEntitlement"])
        self.assertFalse(report["entitlementPresentInSignatureAndProfile"])
        self.assertFalse(report["runtimeSharePlayVerified"])

    def test_profile_and_signed_entitlements_are_both_required(self):
        report = configuration_report({}, {KEY: True}, {KEY: True}, {"Entitlements": {KEY: False}})
        self.assertFalse(report["entitlementPresentInSignatureAndProfile"])
        report = configuration_report({}, {KEY: True}, {KEY: True}, {"Entitlements": {KEY: True}})
        self.assertTrue(report["entitlementPresentInSignatureAndProfile"])
        self.assertFalse(report["runtimeSharePlayVerified"])

    def test_signed_app_with_empty_entitlements_reports_absence(self):
        report = configuration_report({}, {KEY: True}, {}, {"Entitlements": {}})
        self.assertFalse(report["signedGroupSessionEntitlement"])
        self.assertFalse(report["profileGroupSessionEntitlement"])

    def test_free_account_limitation_is_not_runtime_authorization(self):
        report = configuration_report({}, {KEY: True}, None, None)
        self.assertFalse(report["freeAppleIDSupportsGroupActivities"])
        self.assertFalse(report["runtimeSharePlayVerified"])
        self.assertIn("paid Apple Developer Program", report["note"])

    def test_audit_omits_private_profile_and_account_fields(self):
        report = configuration_report({"CFBundleIdentifier": "app.example", "token": "private-test"},
                                      {KEY: True}, {KEY: True, "account": "private-test"},
                                      {"Entitlements": {KEY: True}, "TeamName": "private-test"})
        self.assertNotIn("private-test", str(report))


if __name__ == "__main__":
    unittest.main()
