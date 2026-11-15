#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Package the user-provided icon.png as loose iOS PNG icon resources."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib

import PIL
from PIL import Image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--manifest', required=True, type=Path)
    args = parser.parse_args()
    if PIL.__version__ != '13.0.0':
        parser.error('Use the Pillow version pinned in requirements-build.txt (13.0.0)')
    source_hash = hashlib.sha256(args.source.read_bytes()).hexdigest()
    with Image.open(args.source) as image:
        if image.format != 'PNG' or image.width != image.height or image.width < 180:
            parser.error('Expected a square PNG of at least 180 pixels; source is never cropped')
        if 'A' in image.getbands() or 'transparency' in image.info:
            if image.convert('RGBA').getchannel('A').getextrema() != (255, 255):
                parser.error('The icon must be opaque; choose its background in the source asset')
        original_size = image.size
        profile = image.info.get('icc_profile')
        rgb = image.convert('RGB')

    # Point sizes and scale suffixes are kept in the names; no rounding or mask
    # is applied here. SpringBoard applies its own icon shape at display time.
    files = {}
    iphone_files = []
    ipad_files = []
    specs = [(20, (1, 2, 3)), (29, (1, 2, 3)), (40, (1, 2, 3)),
             (60, (2, 3)), (76, (1, 2)), (83.5, (2,))]
    for points, scales in specs:
        for scale in scales:
            suffix = '' if scale == 1 else f'@{scale}x'
            name = f'AppIcon{points:g}{suffix}.png'
            pixels = int(points * scale)
            resized = rgb.resize((pixels, pixels), Image.Resampling.LANCZOS)
            destination = args.app / name
            resized.save(destination, format='PNG', optimize=True, icc_profile=profile)
            files[name] = {'pixels': pixels, 'sha256': hashlib.sha256(destination.read_bytes()).hexdigest()}
            if points in (20, 29, 40, 60) and scale in (2, 3):
                iphone_files.append(name)
            if points in (20, 29, 40, 76, 83.5) and scale in (1, 2):
                ipad_files.append(name)

    plist_path = args.app / 'Info.plist'
    info = plistlib.loads(plist_path.read_bytes())
    info['CFBundleIcons'] = {'CFBundlePrimaryIcon': {
        'CFBundleIconFiles': iphone_files, 'UIPrerenderedIcon': True}}
    info['CFBundleIcons~ipad'] = {'CFBundlePrimaryIcon': {
        'CFBundleIconFiles': ipad_files, 'UIPrerenderedIcon': True}}
    plist_path.write_bytes(plistlib.dumps(info))
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_text(json.dumps({
        'source': str(args.source), 'source_sha256': source_hash,
        'source_dimensions': original_size, 'pillow_version': PIL.__version__,
        'resize_filter': 'LANCZOS', 'source_modified': False,
        'appearance_changes': 'Resizing only; no cropping, background change or rounding',
        'files': files,
    }, indent=2) + '\n')
    print(f'App icons: {len(files)} PNG resources from {args.source.name}')


if __name__ == '__main__':
    main()
