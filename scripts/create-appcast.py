#!/usr/bin/env python3
"""Sign a release ZIP and write its signed Sparkle update feed."""

import argparse
import base64
import hashlib
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
from urllib.parse import quote
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parent.parent
ACCOUNT = "com.openyourmac.OpenYourMac"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def create(archive, output):
    tools = ROOT / "app/.build/artifacts/sparkle/Sparkle/bin"
    with zipfile.ZipFile(archive) as source:
        info = plistlib.loads(source.read("OpenYourMac.app/Contents/Info.plist"))
    with (ROOT / "app/Info.plist").open("rb") as source:
        expected = plistlib.load(source)
    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) or not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("The archive must have a release version and positive build number.")
    if version != (ROOT / "VERSION").read_text().strip() or build != (ROOT / "BUILD_NUMBER").read_text().strip():
        raise ValueError("The archive does not match VERSION and BUILD_NUMBER.")
    for key in ("CFBundleIdentifier", "SUPublicEDKey", "SUFeedURL", "OYMUpdateRepository",
                "SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed"):
        if info[key] != expected[key]:
            raise ValueError(f"The archive has an unexpected {key}.")
    public_key = subprocess.check_output(
        [str(tools / "generate_keys"), "--account", ACCOUNT, "-p"], text=True
    ).strip()
    if public_key != info["SUPublicEDKey"]:
        raise ValueError("The Sparkle Keychain key does not match SUPublicEDKey. Import the release key; do not replace it.")
    sign = [str(tools / "sign_update"), "--account", ACCOUNT]
    signature = subprocess.check_output([*sign, "-p", str(archive)], text=True).strip()
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Sparkle returned an invalid EdDSA signature.")
    subprocess.run([*sign, "--verify", str(archive), signature], check=True)

    ET.register_namespace("sparkle", SPARKLE)
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    repository_url = f"https://github.com/{info['OYMUpdateRepository']}"
    ET.SubElement(channel, "title").text = "OpenYourMac Updates"
    ET.SubElement(channel, "link").text = repository_url
    ET.SubElement(channel, "description").text = "Signed OpenYourMac releases for Apple silicon."
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"OpenYourMac {version}"
    ET.SubElement(item, "link").text = f"{repository_url}/releases/tag/v{version}"
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc), usegmt=True)
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = build
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
    minimum_os = info["LSMinimumSystemVersion"].split(".")
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = ".".join(minimum_os + ["0"] * (3 - len(minimum_os)))
    ET.SubElement(item, f"{{{SPARKLE}}}hardwareRequirements").text = "arm64"
    feed_url = urlsplit(info["SUFeedURL"])
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    ET.SubElement(item, "enclosure", {
        "url": f"https://{feed_url.netloc}/releases/{build}/{digest}/{quote(archive.name)}",
        f"{{{SPARKLE}}}edSignature": signature,
        "length": str(archive.stat().st_size),
        "type": "application/octet-stream",
    })
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as scratch:
        staged = Path(scratch) / "appcast.xml"
        ET.indent(rss)
        ET.ElementTree(rss).write(staged, encoding="utf-8", xml_declaration=True)
        subprocess.run([*sign, str(staged)], check=True)
        subprocess.run([*sign, "--verify", str(staged)], check=True)
        staged.replace(output)
    print(f"Created signed feed: {output.name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path, help="The verified release ZIP")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        create(args.archive.resolve(), args.output.resolve())
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        sys.exit(f"create-appcast: {error}")


if __name__ == "__main__":
    main()
