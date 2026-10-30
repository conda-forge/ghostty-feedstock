"""Use upstream's existing PNGs as a classic app icon for headless Xcode CI."""
import json
import os
from pathlib import Path
import shutil

src = Path(os.environ['SRC_DIR'])
destination = src / 'macos/Assets.xcassets/AppIcon.appiconset'
destination.mkdir(parents=True, exist_ok=True)
images = []
for size in [16, 32, 128, 256, 512]:
    for scale in [1, 2]:
        pixels = size * scale
        source_name = 'icon_32@2x.png' if pixels == 64 else f'icon_{pixels}.png'
        filename = f'icon_{size}' + ('@2x' if scale == 2 else '') + '.png'
        shutil.copyfile(src / 'images/icons' / source_name, destination / filename)
        images.append({'idiom': 'mac', 'size': f'{size}x{size}',
                       'scale': f'{scale}x', 'filename': filename})
(destination / 'Contents.json').write_text(
    json.dumps({'images': images, 'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n',
    encoding='utf-8',
)
