#!/usr/bin/env python3
"""Write the single-item Sparkle appcast for a release.

Usage: write_appcast.py <appcast.xml> <version> <tag> <min-macos> <ed-signature> <length> [release-notes.md]

The first release of a new major version (feed holds 1.x, release is 2.0.0) is held back,
leaving the feed untouched, unless SPARKLE_MAJOR_UPGRADE_APPROVED equals the new major.
Every item carries minimumAutoupdateVersion <major>.0.0, so Sparkle never installs across
a major version silently. SPARKLE_PHASED_ROLLOUT_INTERVAL (seconds) spreads the update
over 7 groups.
"""
from email.utils import formatdate
import os
from pathlib import Path
import re
import sys
from xml.sax.saxutils import escape, quoteattr

REPO = 'https://github.com/yazinsai/OpenOats'
FEED = 'https://raw.githubusercontent.com/yazinsai/OpenOats/gh-pages/appcast.xml'


def write(path, version, tag, minimum_macos, signature, length, notes=None, env=os.environ):
    path = Path(path)
    major = version.split('.')[0]
    current = re.search(r'<sparkle:version>([^<]+)</sparkle:version>', path.read_text()) if path.exists() else None
    if current and current.group(1).split('.')[0] != major and env.get('SPARKLE_MAJOR_UPGRADE_APPROVED') != major:
        print(f'::warning::Appcast left at {current.group(1)}: {version} is a new major version. '
              f'Set the SPARKLE_MAJOR_UPGRADE_APPROVED repository variable to {major} and rerun to publish it.')
        return False
    extra = ''
    interval = env.get('SPARKLE_PHASED_ROLLOUT_INTERVAL', '')
    if interval:
        if not interval.isdigit():
            sys.exit('SPARKLE_PHASED_ROLLOUT_INTERVAL must be a number of seconds')
        extra += f'\n      <sparkle:phasedRolloutInterval>{interval}</sparkle:phasedRolloutInterval>'
    if notes:
        body = Path(notes).read_text().replace(']]>', ']]]]><![CDATA[>')
        extra += f'\n      <description sparkle:format="markdown"><![CDATA[{body}]]></description>'
    url = f'{REPO}/releases/download/{tag}/OpenOats.dmg'
    path.write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>OpenOats Updates</title>
    <link>{FEED}</link>
    <description>Most recent updates to OpenOats</description>
    <language>en</language>
    <item>
      <title>Version {escape(version)}</title>
      <link>{REPO}/releases/tag/{escape(tag)}</link>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{escape(version)}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(minimum_macos)}</sparkle:minimumSystemVersion>
      <sparkle:minimumAutoupdateVersion>{major}.0.0</sparkle:minimumAutoupdateVersion>{extra}
      <enclosure url={quoteattr(url)}
                 sparkle:edSignature={quoteattr(signature)}
                 length={quoteattr(length)}
                 type="application/octet-stream" />
    </item>
  </channel>
</rss>
''')
    return True


if __name__ == '__main__':
    if len(sys.argv) not in (7, 8):
        sys.exit(__doc__)
    write(*sys.argv[1:])
