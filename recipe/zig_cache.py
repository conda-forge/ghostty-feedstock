"""Prepare Ghostty's offline system package directory for Zig 0.17."""
import os
import re
from pathlib import Path
import subprocess
import tarfile
import tempfile


def prepare_cache(src, cache):
    cache.mkdir(parents=True, exist_ok=True)
    os.environ['ZIG_GLOBAL_CACHE_DIR'] = str(cache)
    packages = cache / 'conda-packages'
    packages.mkdir(exist_ok=True)
    # Reuse hashes from the release and already unpacked dependency manifests.
    # Fetch remains the fallback for manifests not yet available locally.
    hashes = {}
    manifests = [src / 'build.zig.zon', *(src / 'pkg').rglob('build.zig.zon'),
                 *packages.rglob('build.zig.zon')]
    for manifest in manifests:
        hashes.update(re.findall(r'\.url\s*=\s*"([^"]+)",\s*\.hash\s*=\s*"([^"]+)"',
                                 manifest.read_text(encoding='utf-8')))
    # Reuse upstream's complete manifest, including transitive dependencies.
    for url in (src / 'build.zig.zon.txt').read_text(encoding='utf-8').splitlines():
        print(f'Fetching: {url}', flush=True)
        package_hash = hashes.get(url)
        if package_hash is None or not (cache / 'p' / (package_hash + '.tar.gz')).is_file():
            package_hash = subprocess.check_output(['zig', 'fetch', url], text=True).strip()
        destination = packages / package_hash
        if destination.is_dir():
            continue
        # Zig 0.17 caches archives, whereas --system requires package directories.
        archive = cache / 'p' / (package_hash + '.tar.gz')
        with tempfile.TemporaryDirectory(dir=cache) as temporary:
            temporary = Path(temporary)
            with tarfile.open(archive) as tar:
                tar.extractall(temporary, filter='data')
            root = temporary / package_hash
            # HTTP archives retain their upstream wrapper beneath the cache's
            # package-hash wrapper; git snapshots have files directly at root.
            entries = list(root.iterdir())
            if not url.startswith('git+') and len(entries) == 1 and entries[0].is_dir():
                root = entries[0]
            try:
                root.rename(destination)
            except OSError:
                # Another output may have populated the shared cache first.
                if not destination.is_dir():
                    raise
    return packages


if __name__ == '__main__':
    src = Path(os.environ['SRC_DIR'])
    cache = Path(os.environ.get('ZIG_GLOBAL_CACHE_DIR', src / 'zig-cache'))
    prepare_cache(src, cache)
