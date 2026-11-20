#!/usr/bin/env python3
"""Write optional public Discord build settings without xcconfig // truncation."""
import json
import os
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit


def configuration(application_id, activity_url):
    application_id = application_id.strip()
    activity_url = activity_url.strip()
    try:
        parts = urlsplit(activity_url)
    except ValueError:
        return ("", "")
    valid = bool(
        re.fullmatch(r"[0-9]{17,20}", application_id)
        and parts.scheme == "https" and parts.hostname
        and not parts.username and not parts.password
        and not parts.hostname.endswith((".example", ".invalid"))
        and not any(character.isspace() for character in activity_url)
        and "$(" not in activity_url
    )
    return (application_id, activity_url) if valid else ("", "")


def append_configuration(path, application_id, activity_url):
    application_id, activity_url = configuration(application_id, activity_url)
    # xcconfig treats unescaped // as a comment, even in an HTTPS URL.
    escaped_url = activity_url.replace("//", "/$()/")
    with Path(path).open("a", encoding="utf-8") as output:
        output.write("\nDISCORD_APPLICATION_CLIENT_ID = " + application_id + "\n")
        output.write("DISCORD_ACTIVITY_URL = " + escaped_url + "\n")
    return bool(application_id)


if __name__ == "__main__":
    configured = append_configuration(sys.argv[1], os.getenv("DISCORD_APPLICATION_CLIENT_ID", ""),
                                      os.getenv("DISCORD_ACTIVITY_URL", ""))
    print(json.dumps({"discord_build_settings_valid": configured, "deployment_verified": False,
                      "note": "A deployed Discord Activity is required; unconfigured builds show setup information."}))
