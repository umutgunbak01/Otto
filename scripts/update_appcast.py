#!/usr/bin/env python3
"""Prepend a new <item> to docs/appcast.xml.

Called by scripts/release.sh after notarization + EdDSA signing.
Existing items are preserved so older builds can still find their
version on the feed. Sparkle picks the highest version on its own.

Usage:
    update_appcast.py \\
        --version 1.0.1 \\
        --build 2 \\
        --tag v1.0.1 \\
        --zip-size 12345678 \\
        --ed-signature <base64> \\
        --min-system-version 15.4
"""
from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)

REPO = "umutgunbak01/Otto"
APPCAST_PATH = Path(__file__).resolve().parent.parent / "docs" / "appcast.xml"


def rfc822(dt: datetime) -> str:
    # Sparkle parses RFC 822 pubDate. Force GMT to keep entries comparable.
    return dt.astimezone(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")


def build_item(args: argparse.Namespace) -> ET.Element:
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Otto {args.version}"
    ET.SubElement(item, "pubDate").text = rfc822(datetime.now(timezone.utc))
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = str(args.build)
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = args.version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = args.min_system_version

    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set(
        "url",
        f"https://github.com/{REPO}/releases/download/{args.tag}/Otto.app.zip",
    )
    enclosure.set("length", str(args.zip_size))
    enclosure.set("type", "application/octet-stream")
    enclosure.set(f"{{{SPARKLE_NS}}}edSignature", args.ed_signature)
    return item


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True, help="Marketing version, e.g. 1.0.1")
    parser.add_argument("--build", required=True, help="Build number, e.g. 2")
    parser.add_argument("--tag", required=True, help="Git tag, e.g. v1.0.1")
    parser.add_argument("--zip-size", required=True, type=int, help="Bytes")
    parser.add_argument("--ed-signature", required=True, help="EdDSA signature from sign_update")
    parser.add_argument("--min-system-version", default="15.4")
    args = parser.parse_args()

    if not APPCAST_PATH.exists():
        print(f"appcast not found: {APPCAST_PATH}", file=sys.stderr)
        return 1

    tree = ET.parse(APPCAST_PATH)
    channel = tree.getroot().find("channel")
    if channel is None:
        print("appcast missing <channel>", file=sys.stderr)
        return 1

    # Refuse to publish a duplicate version. Catches accidental re-runs.
    existing_versions = {
        e.text for e in channel.findall(f".//{{{SPARKLE_NS}}}shortVersionString")
    }
    if args.version in existing_versions:
        print(f"refusing: appcast already lists version {args.version}", file=sys.stderr)
        return 1

    item = build_item(args)
    # Insert the new item after the metadata children so the newest release
    # appears first in the feed (Sparkle doesn't require ordering but it's
    # nicer to read).
    metadata_tags = {"title", "link", "description", "language"}
    insert_index = 0
    for i, child in enumerate(list(channel)):
        if child.tag in metadata_tags:
            insert_index = i + 1
    channel.insert(insert_index, item)

    ET.indent(tree, space="  ")
    tree.write(APPCAST_PATH, encoding="utf-8", xml_declaration=True)
    # Ensure trailing newline so the committed file ends cleanly.
    data = APPCAST_PATH.read_bytes()
    if not data.endswith(b"\n"):
        APPCAST_PATH.write_bytes(data + b"\n")
    print(f"appcast updated: {args.version} ({args.tag})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
