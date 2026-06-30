#!/usr/bin/env python3
"""Prepend a release entry to the cumulative Sparkle appcast (issue #57).

Reads everything from the environment so the CI step stays a one-liner (see
.github/workflows/appcast.yml). Creates the appcast on first run, inserts new items newest-first at a
stable `<!--ITEMS-->` marker, and is idempotent — re-running for a version already present is a no-op.

Env:
  VERSION        marketing version, e.g. "1.2.3" (the release tag without the leading "v")
  ENCLOSURE_URL  fixed per-release DMG URL, e.g. .../releases/download/v1.2.3/Bosun.dmg
  SIG_LINE       sign_update output: 'sparkle:edSignature="…" length="…"'
  RELEASE_BODY   release notes (optional; shown as the item description)
  PUBLISHED_AT   ISO-8601 publish time (optional; falls back to now)
  REPO           "owner/name" (for the channel <link>)
  APPCAST        output path (optional; default "appcast.xml")
"""
import datetime
import email.utils
import os
import sys

MARKER = "<!--ITEMS-->"


def main() -> int:
    version = os.environ["VERSION"]
    enclosure_url = os.environ["ENCLOSURE_URL"]
    sig_line = os.environ["SIG_LINE"].strip()
    repo = os.environ.get("REPO", "Jeckerson/bosun")
    notes = os.environ.get("RELEASE_BODY") or f"Bosun {version}"
    path = os.environ.get("APPCAST", "appcast.xml")

    pub = os.environ.get("PUBLISHED_AT") or ""
    try:
        when = datetime.datetime.fromisoformat(pub.replace("Z", "+00:00"))
    except ValueError:
        when = datetime.datetime.now(datetime.timezone.utc)
    pubdate = email.utils.format_datetime(when)

    skeleton = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
        "  <channel>\n"
        "    <title>Bosun</title>\n"
        f"    <link>https://github.com/{repo}</link>\n"
        "    <description>Bosun updates</description>\n"
        "    <language>en</language>\n"
        f"    {MARKER}\n"
        "  </channel>\n"
        "</rss>\n"
    )

    try:
        with open(path, encoding="utf-8") as handle:
            doc = handle.read()
        if MARKER not in doc:
            doc = skeleton
    except FileNotFoundError:
        doc = skeleton

    needle = f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>"
    if needle in doc:
        print(f"Appcast already lists {version}; leaving it unchanged.")
        return 0

    # CDATA keeps release-notes markup intact; only the literal "]]>" must be split to stay well-formed.
    safe_notes = notes.replace("]]>", "]]]]><![CDATA[>")
    item = (
        "<item>\n"
        f"      <title>Version {version}</title>\n"
        f"      <description><![CDATA[{safe_notes}]]></description>\n"
        f"      <pubDate>{pubdate}</pubDate>\n"
        f"      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>\n"
        f"      <sparkle:version>{version}</sparkle:version>\n"
        "      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>\n"
        f'      <enclosure url="{enclosure_url}" type="application/octet-stream" {sig_line} />\n'
        "    </item>"
    )
    doc = doc.replace(MARKER, f"{MARKER}\n    {item}", 1)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(doc)
    print(f"Inserted appcast entry for {version}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
