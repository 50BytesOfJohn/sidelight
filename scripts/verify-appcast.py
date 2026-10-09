#!/usr/bin/env python3
"""Validate the generated Sparkle feed against the app and its final DMG."""

import base64
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import xml.etree.ElementTree as ET

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def verify_metadata(plist, archive, feed, version, repo_url):
    """Return the signature only if this feed describes exactly this release."""
    items = ET.parse(feed).getroot().findall("./channel/item")
    if len(items) != 1:
        raise ValueError("appcast must contain exactly one update")
    item = items[0]
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ValueError("appcast has no update enclosure")
    expected = {
        "url": f"{repo_url}/releases/download/v{version}/{archive.name}",
        "length": str(archive.stat().st_size),
        "type": "application/octet-stream",
    }
    for name, value in expected.items():
        if enclosure.get(name) != value:
            raise ValueError(f"appcast {name} does not match the release")
    if item.findtext(SPARKLE + "version") != plist["CFBundleVersion"]:
        raise ValueError("appcast build number does not match the app")
    if item.findtext(SPARKLE + "shortVersionString") != version:
        raise ValueError("appcast version does not match the release")
    if plist["CFBundleShortVersionString"] != version:
        raise ValueError("app version does not match the release")
    if item.findtext(SPARKLE + "minimumSystemVersion") != plist["LSMinimumSystemVersion"]:
        raise ValueError("appcast minimum macOS version does not match the app")
    if item.findtext(SPARKLE + "hardwareRequirements") != "arm64":
        raise ValueError("appcast must require Apple Silicon")
    if len(base64.b64decode(plist.get("SUPublicEDKey", ""), validate=True)) != 32:
        raise ValueError("app has no valid Sparkle public key")
    signature = enclosure.get(SPARKLE + "edSignature", "")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("appcast has no valid EdDSA signature")
    return signature


def main():
    plist_path, archive_path, feed_path, version, repo_url = sys.argv[1:]
    with open(plist_path, "rb") as source:
        plist = plistlib.load(source)
    archive = Path(archive_path)
    signature = verify_metadata(plist, archive, Path(feed_path), version, repo_url)
    command = [".build/artifacts/sparkle/Sparkle/bin/sign_update", "--verify"]
    private_key = os.environ.get("SPARKLE_PRIVATE_KEY")
    if private_key:
        command += ["--ed-key-file", "-"]
    else:
        command += ["--account", "sidelight"]
    command += [str(archive), signature]
    subprocess.run(command, input=private_key, text=True, check=True)
    print("Verified appcast metadata and DMG update signature.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, ET.ParseError, subprocess.CalledProcessError) as error:
        sys.exit(f"error: {error}")
