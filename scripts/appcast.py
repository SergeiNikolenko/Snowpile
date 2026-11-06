#!/usr/bin/env python3
"""Sign a release ZIP and DMG with the Sparkle key and add the release to the update feed.

Usage: appcast.py <zip> <dmg> <app> <output> [previous-feed]
The private key (the base64 seed exported by Sparkle's generate_keys) comes from SNOWPILE_SPARKLE_PRIVATE_KEY.
"""
import base64
import datetime
import os
import plistlib
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', NS)
REPO = 'https://github.com/SergeiNikolenko/Snowpile'
SIGNER = Path(__file__).resolve().parent.parent / 'build/sparkle/bin/sign_update'


def sign(path, key):
    result = subprocess.run([str(SIGNER), '--ed-key-file', '-', '-p', str(path)],
                            input=key + '\n', text=True, capture_output=True, check=True)
    signature = result.stdout.strip()
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError('Sparkle returned an invalid signature')
    return signature


def main():
    archive, dmg, app, output = map(Path, sys.argv[1:5])
    previous = Path(sys.argv[5]).read_bytes() if len(sys.argv) > 5 else None
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    if archive.name != f'Snowpile-{version}.zip' or dmg.name != f'Snowpile-{version}.dmg':
        raise ValueError('Asset names must match the app version')

    key = os.environ['SNOWPILE_SPARKLE_PRIVATE_KEY'].strip()
    seed = base64.b64decode(key, validate=True)
    public = subprocess.run(['openssl', 'pkey', '-inform', 'DER', '-pubout', '-outform', 'DER'],
                            input=bytes.fromhex('302e020100300506032b657004220420') + seed,
                            capture_output=True, check=True).stdout[-32:]
    if base64.b64encode(public).decode() != info['SUPublicEDKey']:
        raise ValueError('The signing key does not match the key built into the app')

    signature = sign(archive, key)
    archive.with_name(archive.name + '.ed25519').write_text(signature + '\n')
    dmg.with_name(dmg.name + '.ed25519').write_text(sign(dmg, key) + '\n')

    feed = ET.fromstring(previous) if previous else ET.Element('rss', version='2.0')
    channel = feed.find('channel')
    if channel is None:
        channel = ET.SubElement(feed, 'channel')
        ET.SubElement(channel, 'title').text = 'Snowpile Updates'
    item = ET.Element('item')
    ET.SubElement(item, 'title').text = f'Snowpile {version}'
    ET.SubElement(item, f'{{{NS}}}version').text = build
    ET.SubElement(item, f'{{{NS}}}shortVersionString').text = version
    ET.SubElement(item, f'{{{NS}}}minimumSystemVersion').text = info['LSMinimumSystemVersion']
    if '-' in version:
        ET.SubElement(item, f'{{{NS}}}channel').text = 'beta'
    ET.SubElement(item, 'pubDate').text = datetime.datetime.now(datetime.timezone.utc).strftime('%a, %d %b %Y %H:%M:%S GMT')
    ET.SubElement(item, 'link').text = f'{REPO}/releases/tag/v{version}'
    ET.SubElement(item, 'enclosure', {
        'url': f'{REPO}/releases/download/v{version}/{archive.name}',
        'length': str(archive.stat().st_size), 'type': 'application/octet-stream', f'{{{NS}}}edSignature': signature,
    })
    for old in channel.findall('item'):
        if old.findtext(f'{{{NS}}}version') == build:
            channel.remove(old)
    channel.insert(1, item)
    for old in channel.findall('item')[10:]:
        channel.remove(old)
    output.write_bytes(ET.tostring(feed, encoding='utf-8', xml_declaration=True))


if __name__ == '__main__':
    main()
