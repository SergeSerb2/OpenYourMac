#!/usr/bin/env python3
"""Extract the exact release section and describe the published signing status."""
import argparse
from datetime import date
from pathlib import Path
import re
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--version", required=True)
parser.add_argument("--changelog", type=Path, default=Path("CHANGELOG.md"))
parser.add_argument("--signing-kind", required=True, choices=("ad-hoc", "notarized"))
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
try:
    text = args.changelog.read_text(encoding="utf-8")
except OSError as error:
    sys.exit(f"release-notes: {error}")
sections = list(re.finditer(r"^## \[" + re.escape(args.version) + r"\](?:[^\n]*)$", text, re.M))
if len(sections) != 1:
    sys.exit(f"release-notes: expected one ## [{args.version}] section in {args.changelog}")
section = sections[0]
dated = re.fullmatch(r"## \[" + re.escape(args.version) + r"\] - (\d{4}-\d{2}-\d{2})", section.group())
if not dated:
    sys.exit(f"release-notes: expected a dated ## [{args.version}] - YYYY-MM-DD section")
try:
    date.fromisoformat(dated[1])
except ValueError:
    sys.exit(f"release-notes: invalid release date: {dated[1]}")
end = re.search(r"^## ", text[section.end():], re.M)
body = text[section.end():section.end() + end.start() if end else len(text)].strip()
if not body:
    sys.exit(f"release-notes: empty ## [{args.version}] section")
status = (
    "This build is **ad-hoc signed and not notarized**. macOS Gatekeeper can block first launch. "
    "For a trusted download, use System Settings > Privacy & Security > Open Anyway."
    if args.signing_kind == "ad-hoc" else
    "This build is signed with Developer ID and notarized by Apple."
)
args.output.write_text(
    f"OpenYourMac {args.version} for Apple silicon, macOS 13 or later.\n\n"
    f"{status}\n\n{body}\n\n"
    "Verify the ZIP with its SHA-256 file before installation. "
    "See the [release guide](https://github.com/SergeSerb2/OpenYourMac/blob/"
    f"v{args.version}/docs/releasing.md) for installation and first-launch steps.\n",
    encoding="utf-8",
)
