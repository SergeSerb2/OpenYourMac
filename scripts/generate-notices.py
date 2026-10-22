#!/usr/bin/env python3
"""Generate release notices from locked Cargo inputs; Python 3 stdlib only."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
TARGET = "aarch64-apple-darwin"
NOTICE_NAME = re.compile(r"^(licen[cs]e|copying|copyright|notice|unlicense)([._-]|$)", re.I)


def cargo(*args):
    # This directory selects engine/rust-toolchain.toml, unless explicitly overridden.
    return subprocess.check_output(
        ["cargo", *args, "--locked", "--no-default-features"],
        cwd=ROOT / "engine", text=True,
    )


def packages():
    metadata = json.loads(cargo("metadata", "--format-version", "1", "--filter-platform", TARGET))
    # metadata's resolve graph can unify features outside the release graph.
    # Use Cargo's target-filtered normal tree to select packages, including proc macros
    # conservatively. Build-only/dev dependencies and optional Lua are not selected.
    tree = cargo("tree", "--target", TARGET, "--edges", "normal", "--prefix", "none", "--format", "{p}")
    wanted = set()
    for line in tree.splitlines():
        match = re.match(r"^(\S+) v(\S+)(?: |$)", line)
        if not match:
            raise ValueError(f"Unexpected cargo tree entry: {line}")
        wanted.add(match.groups())
    result = []
    for name, version in sorted(wanted):
        matches = [p for p in metadata["packages"] if (p["name"], p["version"]) == (name, version)]
        if len(matches) != 1:
            raise ValueError(f"Ambiguous or missing metadata for {name} {version}")
        package = matches[0]
        if package["id"] == metadata["resolve"]["root"]:
            continue
        if not package["source"] or not package["source"].startswith("registry+"):
            raise ValueError(f"Review notices for non-registry package {name} {version}")
        result.append(package)
    return result


def selected_license(expression):
    # Legacy Cargo slash syntax means OR. Stop for new terms rather than guess.
    expression = re.sub(r"\s*/\s*", " OR ", expression or "")
    choices = {"MIT", "Apache-2.0", "Zlib", "CC0-1.0", "BSD-2-Clause", "BSD-3-Clause", "Unlicense", "Unicode-3.0"}
    tokens = set(re.findall(r"[\w.-]+", expression))
    if not tokens or tokens - choices - {"AND", "OR"}:
        raise ValueError(f"Review new license expression: {expression}")
    if "AND" in tokens and expression != "(MIT OR Apache-2.0) AND Unicode-3.0":
        raise ValueError(f"Review license conjunction: {expression}")
    if "MIT" in tokens:
        return "MIT AND Unicode-3.0" if "Unicode-3.0" in tokens else "MIT"
    if expression in {"Apache-2.0", "Zlib", "CC0-1.0"}:
        return expression
    raise ValueError(f"Review license selection: {expression}")


def license_texts(package, overrides):
    root = Path(package["manifest_path"]).parent
    key = f"{package['name']}@{package['version']}"
    selected = selected_license(package["license"])
    paths = {p for p in root.rglob("*") if p.is_file() and NOTICE_NAME.match(p.name)}
    if package["license_file"]:
        paths.add(root / package["license_file"])
    texts = []
    for path in sorted(paths):
        name = path.name.upper()
        # Retain additional notices (including Unicode and embedded third-party work),
        # while selecting MIT instead of alternate Apache/BSD/Zlib/Unlicense terms.
        if selected.startswith("MIT") and (
            name == "UNLICENSE" or re.match(r"^LICENSE[-_.](APACHE|BSD|ZLIB)", name)
        ):
            continue
        body = path.read_text(encoding="utf-8")
        label = str(path.relative_to(root))
        # These two crates combine alternate terms in one file. Keep the full MIT
        # grant and all actual attributions; Apache is reproduced for fragile below.
        if key == "chrono@0.4.44" and label == "LICENSE.txt":
            body, separator, _ = body.partition("[2]: <http://www.apache.org/licenses/LICENSE-2.0>")
            if not separator:
                raise ValueError("Review changed chrono license layout")
            label += " (MIT section and attribution)"
        if key == "libm@0.2.16" and label == "LICENSE.txt":
            before, separator, rest = body.partition("As a contributor, you agree")
            _, attribution, after = rest.partition("This Rust library contains the following copyrights:")
            if not separator or not attribution:
                raise ValueError("Review changed libm license layout")
            body = before + attribution + after
            label += " (MIT section and all third-party attributions)"
        if key == "crossbeam-channel@0.5.17" and label == "LICENSE-THIRD-PARTY":
            # The file already includes Rust's MIT option and copyright notice.
            # Its final block repeats only the alternative Apache boilerplate.
            body, separator, alternate = body.partition(
                "The Rust Programming Language\nhttps://github.com/rust-lang/rust/blob/master/LICENSE-APACHE\n"
            )
            if not separator or not alternate.lstrip().startswith("Apache License"):
                raise ValueError("Review changed crossbeam-channel license layout")
            label += " (supplemental notices; Rust MIT option selected)"
        texts.append((label, body))
    note = ""
    if not texts or (selected.startswith("MIT") and not any("Permission is hereby granted" in body for _, body in texts)):
        override = overrides.get(key)
        if not override or override["license"] != package["license"]:
            raise ValueError(f"No license text for {key}; add a reviewed, version-specific snapshot")
        vcs = json.loads((root / ".cargo_vcs_info.json").read_text())
        if vcs["git"]["sha1"] != override["revision"]:
            raise ValueError(f"Upstream revision changed for {key}")
        for entry in override["files"]:
            data = (ROOT / "THIRD_PARTY_LICENSES" / entry["path"]).read_bytes()
            if hashlib.sha256(data).hexdigest() != entry["sha256"]:
                raise ValueError(f"Snapshot hash mismatch: {entry['path']}")
            texts.append((f"{entry['path']} — {entry['source']}", data.decode("utf-8")))
        note = override["note"]
    if not any("Permission is hereby granted" in body for _, body in texts) and selected.startswith("MIT"):
        raise ValueError(f"Missing complete MIT terms for {key}")
    if "Unicode-3.0" in selected and not any("UNICODE" in label.upper() for label, _ in texts):
        raise ValueError(f"Missing Unicode terms for {key}")
    return selected, texts, note


def fenced(text):
    runs = re.findall(r"`+", text)
    fence = "`" * max(3, 1 + max(map(len, runs), default=0))
    return f"{fence}text\n{text.rstrip()}\n{fence}\n"


def generate():
    overrides = json.loads((ROOT / "THIRD_PARTY_LICENSES/manifest.json").read_text())
    output = ["# Third-party notices\n\n## Paneru\n\n",
              "The `engine/` directory derives from [Paneru](https://github.com/karinushka/paneru) "
              "v0.5.2 by Karinushka. Its full MIT license follows.\n\n",
              fenced((ROOT / "engine/LICENSE.txt").read_text()),
              "\n## Rust dependencies\n\nGenerated by `python3 scripts/generate-notices.py` from "
              "`cargo metadata --locked --no-default-features` and the normal dependency tree for "
              "`aarch64-apple-darwin`. Proc-macro inputs are retained conservatively; "
              "build-only/dev dependencies and optional Lua are excluded. "
              "This inventory does not assert that every crate survives linking.\n\n"
              "MIT is selected where available; Unicode-3.0 remains an additional condition. "
              "All supplemental license/notice files are retained. Identical texts are grouped. "
              "For crates whose published archives omit license files, reviewed upstream snapshots "
              "and their provenance are committed under `THIRD_PARTY_LICENSES/`. "
              "The explicit launchctl fallback retains its original MIT declaration and author.\n\n",
              "| Crate | Declared license | Selected terms | Texts |\n| --- | --- | --- | --- |\n"]
    groups = {}
    notes = []
    for package in packages():
        selected, texts, note = license_texts(package, overrides)
        key = f"{package['name']} {package['version']}"
        links = []
        for label, body in texts:
            # Preserve the upstream text, normalizing only file newline/trailing EOF.
            body = body.rstrip() + "\n"
            digest = hashlib.sha256(body.encode()).hexdigest()[:16]
            groups.setdefault(digest, {"body": body, "sources": []})["sources"].append(f"{key}: {label}")
            links.append(f"[text](#text-{digest})")
        output.append(f"| {key} | {package['license']} | {selected} | {', '.join(dict.fromkeys(links))} |\n")
        if note:
            authors = ", ".join(package["authors"]) or "not specified"
            notes.append(f"- **{key}** (manifest authors: {authors}): {note}\n")
    output.extend(["\n### Source notes\n\n", *notes, "\n## License and notice texts\n\n"])
    for digest, group in sorted(groups.items()):
        output.append(f"### Text {digest}\n\n")
        output.extend(f"- {source}\n" for source in sorted(group["sources"]))
        output.extend(["\n", fenced(group["body"]), "\n"])
    return "".join(output).rstrip() + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if committed notices are stale; do not write")
    args = parser.parse_args()
    try:
        expected = generate()
        destination = ROOT / "THIRD_PARTY_NOTICES.md"
        if args.check:
            if not destination.exists() or destination.read_bytes() != expected.encode("utf-8"):
                sys.exit("Notices are stale. Run: python3 scripts/generate-notices.py")
            print("THIRD_PARTY_NOTICES.md is current.")
        else:
            destination.write_bytes(expected.encode("utf-8"))
            print("Generated THIRD_PARTY_NOTICES.md")
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"generate-notices: {error}")


if __name__ == "__main__":
    main()
