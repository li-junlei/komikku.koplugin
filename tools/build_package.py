"""Package only plugin files; never bundle downloaded references or personal data."""
from pathlib import Path
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]
version = re.search(r'version\s*=\s*"([\d.]+)"', (ROOT / '_meta.lua').read_text(encoding='utf8')).group(1)
target = ROOT / 'dist' / f'komikku-koplugin-{version}.zip'
target.parent.mkdir(exist_ok=True)
files = sorted(ROOT.glob('*.lua')) + [ROOT / 'README.md'] + sorted((ROOT / 'docs').glob('*.md'))
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
