#!/usr/bin/env python3
"""Update the sideloader feed only after a real IPA release has been uploaded."""
import argparse
import datetime
import json
import plistlib
import zipfile
from pathlib import Path
from urllib.parse import urlparse

def update(ipa, url, destination, repository, experimental=False):
    if urlparse(url).scheme != "https":
        raise ValueError("Release asset URL must use HTTPS")
    with zipfile.ZipFile(ipa) as z:
        all_entries = z.namelist()
        names = [n for n in all_entries if n.startswith("Payload/") and n.count("/") == 2 and n.endswith(".app/Info.plist")]
        if len(names) != 1:
            raise ValueError("Expected one main app")
        info = plistlib.loads(z.read(names[0]))
    bundle = info["CFBundleIdentifier"]
    expected = ("com.soum91.amazonmusictimbre.experimental" if experimental
                else "com.amazon.mp3.AmazonCloudPlayer")
    if bundle != expected:
        raise ValueError("Unexpected app identity")
    build = str(info["CFBundleVersion"])
    marketing_version = str(info["CFBundleShortVersionString"])
    raw = f"https://raw.githubusercontent.com/{repository}/main"
    target = Path(destination)
    feed = json.loads(target.read_text()) if target.exists() else {}
    date = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    has_widget = any('/PlugIns/TimbreWidgets.appex/Info.plist' in n for n in all_entries)
    if experimental:
        description = ("Side-by-side experimental Amazon Timbre Lab. Preserves the original "
                       "working app and its data; retains Timbre 19 DSP code with an "
                       "additive playback metadata bridge and player/EQ widgets. "
                       "Restores Amazon's native login/deep-link URL schemes in the Lab build. "
                       "Both installed apps now claim Amazon callback schemes, so iOS may direct "
                       "those links to either app. Separate sign-in may still be required or rejected. "
                       "Native Lock Screen media-card launch remains unverified. "
                       "Unsigned IPA: sign the parent app, widget extension, and "
                       "both embedded dylibs before installation.")
    elif has_widget and info.get('TimbreGUIBuild') == 19:
        description = ("Preserves the working Timbre 19 playback and EQ engine. "
                       "Adds Home and Lock Screen widgets with an app-opening link. "
                       "Unsigned IPA: sign both the main app and widget extension before installing. "
                       "Native Now Playing card tap remains unverified.")
    else:
        description = "Embedded Timbre EQ GUI, parametric bands, effects and native audio processing. Sign before installation."
    version = {"version": marketing_version, "buildVersion": build, "date": date,
               "localizedDescription": description, "downloadURL": url,
               "size": Path(ipa).stat().st_size,
               "minOSVersion": str(info.get("MinimumOSVersion", "16.0"))}
    old = next((a for a in feed.get("apps", []) if a.get("bundleIdentifier") == bundle), {})
    versions = [dict(v) for v in old.get("versions", []) if v.get("buildVersion") != build]
    for previous in versions:
        # Previous publishers wrote the four-part CFBundleVersion into both fields.
        # Normalize only when the version exactly duplicated the old build string.
        if (previous.get("version") == previous.get("buildVersion") and
                str(previous.get("buildVersion", "")).startswith(marketing_version + ".")):
            previous["version"] = marketing_version
    versions.insert(0, version)
    versions.sort(key=lambda v: tuple(int(x) for x in v["buildVersion"].split(".")), reverse=True)
    versions = versions[:20]
    latest = versions[0]
    app_name = "Amazon Timbre Lab" if experimental else "Amazon Music with Timbre"
    app = {"name": app_name, "bundleIdentifier": bundle,
           "developerName": "Amazon Music; Timbre integration by soum91",
           "subtitle": ("Experimental Home player and Timbre EQ widgets" if experimental
                        else "Parametric EQ inside Amazon Music"),
           "localizedDescription": description,
           "iconURL": raw + "/assets/icon.png", "tintColor": "#6366F1",
           "category": "music", "versions": versions,
           "version": latest["version"], "buildVersion": latest["buildVersion"],
           "versionDate": latest["date"],
           "versionDescription": latest["localizedDescription"],
           "downloadURL": latest["downloadURL"], "size": latest["size"]}
    feed_name = "Amazon Timbre Lab" if experimental else "Amazon Music with Timbre"
    feed_filename = "source-lab.json" if experimental else "source.json"
    feed.update({"name": feed_name,
                 "identifier": ("com.soum91.amazon-music-with-timbre.lab" if experimental
                                else "com.soum91.amazon-music-with-timbre.source"),
                 "subtitle": ("Side-by-side experimental player" if experimental
                              else "Amazon Music with embedded parametric EQ"),
                 "description": ("Experimental separate-bundle iOS releases; stable app remains installed."
                                 if experimental else
                                 "Non-jailbroken iOS builds. Private GitHub source requires authentication."),
                 "website": f"https://github.com/{repository}", "sourceURL": raw + "/" + feed_filename,
                 "iconURL": raw + "/assets/icon.png",
                 "tintColor": "#6366F1", "apps": [app], "news": feed.get("news", [])})
    target.write_text(json.dumps(feed, indent=2) + "\n")
    return feed

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("ipa"); p.add_argument("download_url"); p.add_argument("output")
    p.add_argument("--repository", default="soum91/amazon-music-with-timbre")
    p.add_argument("--experimental", action="store_true")
    a = p.parse_args()
    update(a.ipa, a.download_url, a.output, a.repository, a.experimental)
