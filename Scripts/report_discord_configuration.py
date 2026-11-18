#!/usr/bin/env python3
"""Audit actual generated Info.plist values without publishing configuration values."""
import json
import plistlib
import sys
from pathlib import Path
from configure_discord import configuration


def report(path):
    with Path(path).open("rb") as source:
        info = plistlib.load(source)
    keys = ["DiscordApplicationClientID", "DiscordActivityURL"]
    app_id, url = configuration(str(info.get(keys[0], "")), str(info.get(keys[1], "")))
    return {"bundle_identifier": info.get("CFBundleIdentifier"),
            "plist_keys_present": {key: key in info for key in keys},
            "syntax_configured": bool(app_id and url), "deployment_verified": False,
            "status": "configured_deployment_unverified" if app_id and url else "setup_required"}


if __name__ == "__main__":
    result = report(sys.argv[1])
    text = json.dumps(result, indent=2)
    print(text)
    if len(sys.argv) > 2:
        Path(sys.argv[2]).write_text(text + "\n", encoding="utf-8")
