"""Package only plugin files; never bundle downloaded references or personal data."""
from pathlib import Path
import re
import zipfile
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
version = re.search(r'version\s*=\s*"([\d.]+)"', (ROOT / '_meta.lua').read_text(encoding='utf8')).group(1)
target = ROOT / 'dist' / f'komikku-koplugin-{version}.zip'
target.parent.mkdir(exist_ok=True)
files = sorted(ROOT.glob('*.lua')) + [ROOT / 'README.md'] + sorted((ROOT / 'docs').glob('*.md'))
assert all(re.fullmatch(r'[\w_]+\.lua|README\.md|docs/[\w_-]+\.md', p.relative_to(ROOT).as_posix()) for p in files), 'Path rejected by installed updater'
assert ROOT / 'main.lua' in files and ROOT / '_meta.lua' in files
local_modules = {p.stem for p in files if p.suffix == '.lua'}
for path in files:
    if path.suffix == '.lua':
        for module in re.findall(r'require\("(km_[^"]+)"\)', path.read_text(encoding='utf8')):
            assert module in local_modules, f'Missing module: {module}'
with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as archive:
    for path in files:
        name = 'komikku.koplugin/' + path.relative_to(ROOT).as_posix()
        archive.write(path, name)
with zipfile.ZipFile(target) as archive:
    assert archive.testzip() is None
    assert all(n.startswith('komikku.koplugin/') and '.reference' not in n and '.private' not in n for n in archive.namelist())
    assert len(archive.namelist()) == len(files)
print(target)
print(f'{len(files)} files, {target.stat().st_size:,} bytes; package checks passed')
manifest = {
    'tag_name': 'v' + version, 'draft': False, 'prerelease': False,
    'assets': [{'name': target.name, 'size': target.stat().st_size,
                'digest': 'sha256:' + hashlib.sha256(target.read_bytes()).hexdigest(),
                'browser_download_url': f'https://github.com/li-junlei/komikku.koplugin/releases/download/v{version}/{target.name}'}],
}
(target.parent / 'update.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf8')
print(target.parent / 'update.json')
