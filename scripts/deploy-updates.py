#!/usr/bin/env python3
"""Publish verified downloads first, then atomically replace the signed R2 feed."""

import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
from urllib.error import HTTPError
from urllib.parse import quote, urlsplit
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
BUCKET = "openyourmac-releases"
ACCOUNT = "com.openyourmac.OpenYourMac"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
WRANGLER = ["npx", "--yes", "wrangler@4.152.0"]


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def download(url, target):
    request = Request(url, headers={"Cache-Control": "no-cache", "User-Agent": "OpenYourMac-release"})
    with urlopen(request, timeout=60) as response, target.open("wb") as destination:
        for chunk in iter(lambda: response.read(1024 * 1024), b""):
            destination.write(chunk)


def deploy(archive, feed, dmg):
    for name in ("CLOUDFLARE_API_TOKEN", "CLOUDFLARE_ACCOUNT_ID"):
        if not os.environ.get(name):
            raise ValueError(f"Set {name} before deploying updates.")
    tools = ROOT / "app/.build/artifacts/sparkle/Sparkle/bin"
    with (ROOT / "app/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    key = subprocess.check_output([str(tools / "generate_keys"), "--account", ACCOUNT, "-p"], text=True).strip()
    if key != info["SUPublicEDKey"]:
        raise ValueError("The Keychain key does not match SUPublicEDKey.")
    verify = [str(tools / "sign_update"), "--account", ACCOUNT, "--verify"]
    subprocess.run([*verify, str(feed)], check=True)
    item = ET.parse(feed).find("./channel/item")
    if item is None:
        raise ValueError("The release feed has no update item.")
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ValueError("The release feed has no download enclosure.")
    build = item.findtext(f"{{{SPARKLE}}}version", "")
    if build != (ROOT / "BUILD_NUMBER").read_text().strip():
        raise ValueError("The release feed does not match BUILD_NUMBER.")
    feed_url = urlsplit(info["SUFeedURL"])
    base = f"https://{feed_url.netloc}"
    prefix = f"releases/{build}/{digest(archive)}"
    expected_url = f"{base}/{prefix}/{quote(archive.name)}"
    if enclosure.get("url") != expected_url or enclosure.get("length") != str(archive.stat().st_size):
        raise ValueError("The feed does not reference this archive on the configured update domain.")
    subprocess.run([*verify, str(archive), enclosure.attrib[f"{{{SPARKLE}}}edSignature"]], check=True)
    assets = [archive] + ([dmg] if dmg else [])
    for asset in list(assets):
        checksum = asset.with_name(asset.name + ".sha256")
        fields = checksum.read_text().strip().split()
        if fields != [digest(asset), asset.name]:
            raise ValueError(f"Invalid checksum file: {checksum.name}")
        assets.append(checksum)

    env = dict(os.environ, WRANGLER_SEND_METRICS="false", CI="1")

    def upload(path, object_key, content_type, cache_control):
        subprocess.run(["node", str(ROOT / "r2-storage-budget.mjs"), "exec", BUCKET,
                        object_key, str(path), "--", *WRANGLER, "r2", "object", "put", f"{BUCKET}/{object_key}",
                        "--remote", "--file", str(path), "--content-type", content_type,
                        "--cache-control", cache_control], env=env, check=True, timeout=300)

    with tempfile.TemporaryDirectory(prefix="openyourmac-deploy-") as scratch:
        scratch = Path(scratch)
        live = scratch / "live.xml"
        try:
            download(info["SUFeedURL"], live)
        except HTTPError as error:
            if error.code != 404:
                raise
        else:
            subprocess.run([*verify, str(live)], check=True)
            previous = ET.parse(live).findtext(f"./channel/item/{{{SPARKLE}}}version")
            if previous is None or int(previous) >= int(build):
                if live.read_bytes() == feed.read_bytes():
                    print("This signed feed is already deployed.")
                    return
                raise ValueError("Refusing to replace the live feed with an equal or older build.")

        for asset in assets:
            mime = "application/zip" if asset == archive else "application/x-apple-diskimage" if asset == dmg else "text/plain"
            upload(asset, f"{prefix}/{asset.name}", mime, "public, max-age=31536000, immutable")
            fetched = scratch / asset.name
            download(f"{base}/{prefix}/{quote(asset.name)}", fetched)
            if digest(fetched) != digest(asset):
                raise ValueError(f"Public download checksum mismatch: {asset.name}")
        # The feed is the publication marker. Never expose it before its downloads.
        upload(feed, feed_url.path.lstrip("/"), "application/xml", "no-store, max-age=0")
        download(info["SUFeedURL"], live)
        if live.read_bytes() != feed.read_bytes():
            raise ValueError("The public feed differs from the signed local feed.")
        subprocess.run([*verify, str(live)], check=True)
    print(f"Published verified Sparkle updates: {info['SUFeedURL']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--appcast", type=Path, required=True)
    parser.add_argument("--dmg", type=Path)
    args = parser.parse_args()
    try:
        deploy(args.archive.resolve(), args.appcast.resolve(), args.dmg.resolve() if args.dmg else None)
    except (OSError, ValueError, KeyError, ET.ParseError, subprocess.SubprocessError) as error:
        sys.exit(f"deploy-updates: {error}")


if __name__ == "__main__":
    main()
