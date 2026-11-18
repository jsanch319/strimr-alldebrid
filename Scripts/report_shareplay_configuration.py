#!/usr/bin/env python3
"""Report GroupActivities declarations without claiming an unsigned IPA supports FaceTime."""
import argparse
import json
import plistlib
import shutil
import subprocess
from pathlib import Path

KEY = "com.apple.developer.group-session"


def parse_plist(data):
    start = data.find(b"<?xml")
    end = data.find(b"</plist>")
    if start < 0 or end < 0:
        return None
    try:
        return plistlib.loads(data[start:end + len(b"</plist>")])
    except (ValueError, plistlib.InvalidFileException):
        return None


def command_plist(command):
    try:
        result = subprocess.run(command, capture_output=True, timeout=15, check=False)
        if result.returncode != 0:
            return None
        return parse_plist(result.stdout) or parse_plist(result.stderr)
    except (OSError, subprocess.TimeoutExpired):
        return None


def configuration_report(info, declared, signed, profile):
    signed_value = None if signed is None else signed.get(KEY) is True
    profile_value = None if profile is None else profile.get("Entitlements", {}).get(KEY) is True
    return {
        "bundleIdentifier": info.get("CFBundleIdentifier"),
        "projectDeclaresGroupActivities": declared.get(KEY) is True,
        "signedGroupSessionEntitlement": signed_value,
        "profileGroupSessionEntitlement": profile_value,
        "entitlementPresentInSignatureAndProfile": signed_value is True and profile_value is True,
        "runtimeSharePlayVerified": False,
        "note": "Unsigned builds cannot verify SharePlay. Audit the app after SideStore signing; FaceTime requires compatible signing and a physical-device test.",
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--project-entitlements", type=Path, default=Path("Strimr-iOS/Strimr-iOS.entitlements"))
    args = parser.parse_args()
    with (args.app / "Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    with args.project_entitlements.open("rb") as handle:
        declared = plistlib.load(handle)
    signed = command_plist(["codesign", "-d", "--entitlements", ":-", str(args.app)]) if shutil.which("codesign") else None
    provision = args.app / "embedded.mobileprovision"
    profile = command_plist(["security", "cms", "-D", "-i", str(provision)]) if provision.exists() and shutil.which("security") else None
    report = configuration_report(info, declared, signed, profile)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    if not report["projectDeclaresGroupActivities"]:
        raise SystemExit("Group Activities is missing from the project entitlements.")


if __name__ == "__main__":
    main()
