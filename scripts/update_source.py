#!/usr/bin/env python3
"""Update the sideloader feed only after a real IPA release has been uploaded."""
import argparse
import datetime
import json
import plistlib
import zipfile
from pathlib import Path
from urllib.parse import urlparse

def update(ipa, url, destination, repository):
    if urlparse(url).scheme != "https":
        raise ValueError("Release asset URL must use HTTPS")
    with zipfile.ZipFile(ipa) as z:
        names = [n for n in z.namelist() if n.startswith("Payload/") and n.count("/") == 2 and n.endswith(".app/Info.plist")]
        if len(names) != 1:
            raise ValueError("Expected one main app")
        info = plistlib.loads(z.read(names[0]))
    bundle = info["CFBundleIdentifier"]
    if bundle != "com.amazon.mp3.AmazonCloudPlayer":
        raise ValueError("Unexpected app identity")
    build = str(info["CFBundleVersion"])
    raw = f"https://raw.githubusercontent.com/{repository}/main"
    target = Path(destination)
    feed = json.loads(target.read_text()) if target.exists() else {}
    date = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
    description = "Embedded Timbre EQ GUI, parametric bands, effects, native audio processing, and app-private login storage compatibility. Sign before installation."
    version = {"version": build, "buildVersion": build, "date": date,
               "localizedDescription": description, "downloadURL": url,
               "size": Path(ipa).stat().st_size,
               "minOSVersion": str(info.get("MinimumOSVersion", "16.0"))}
    old = next((a for a in feed.get("apps", []) if a.get("bundleIdentifier") == bundle), {})
    versions = [v for v in old.get("versions", []) if v.get("buildVersion") != build]
    versions.insert(0, version)
    versions.sort(key=lambda v: tuple(int(x) for x in v["buildVersion"].split(".")), reverse=True)
    versions = versions[:20]
    latest = versions[0]
    app = {"name": "Amazon Music with Timbre", "bundleIdentifier": bundle,
           "developerName": "Amazon Music; Timbre integration by soum91",
           "subtitle": "Parametric EQ inside Amazon Music",
           "localizedDescription": description,
           "iconURL": raw + "/assets/icon.png", "tintColor": "#6366F1",
           "category": "music", "versions": versions,
           "version": latest["version"], "versionDate": latest["date"],
           "versionDescription": latest["localizedDescription"],
           "downloadURL": latest["downloadURL"], "size": latest["size"]}
    feed.update({"name": "Amazon Music with Timbre",
                 "identifier": "com.soum91.amazon-music-with-timbre.source",
                 "subtitle": "Amazon Music with embedded parametric EQ",
                 "description": "Non-jailbroken iOS builds. Private GitHub source requires authentication.",
                 "website": f"https://github.com/{repository}", "sourceURL": raw + "/source.json",
                 "iconURL": raw + "/assets/icon.png",
                 "tintColor": "#6366F1", "apps": [app], "news": feed.get("news", [])})
    target.write_text(json.dumps(feed, indent=2) + "\n")
    return feed

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("ipa"); p.add_argument("download_url"); p.add_argument("output")
    p.add_argument("--repository", default="soum91/amazon-music-with-timbre")
    a = p.parse_args()
    update(a.ipa, a.download_url, a.output, a.repository)
