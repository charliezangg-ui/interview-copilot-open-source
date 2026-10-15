#!/usr/bin/env python3
"""Export reviewed source without .git, local data, binaries or signing material."""
import hashlib
import importlib.util
import io
from pathlib import Path
import plistlib
import tarfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('source_check', ROOT / 'scripts/check-public-source.py')
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)
files, failures = check.check(require_license=True)
if failures:
    raise SystemExit('\n'.join(failures))
with (ROOT / 'Resources/Info.plist').open('rb') as stream:
    version = plistlib.load(stream)['CFBundleShortVersionString']
prefix = f'InterviewCopilot-{version}-source'
output = ROOT / 'dist/source'
output.mkdir(parents=True, exist_ok=True)
archive = output / f'{prefix}.tar.gz'
manifest = []
with tarfile.open(archive, 'w:gz') as bundle:
    for relative in files:
        data = (ROOT / relative).read_bytes()
        manifest.append(f'{hashlib.sha256(data).hexdigest()}  {relative.as_posix()}')
        info = tarfile.TarInfo(f'{prefix}/{relative.as_posix()}')
        info.size = len(data)
        info.mode = 0o755 if relative.parts[0] == 'scripts' and relative.suffix in {'.sh', '.py'} else 0o644
        bundle.addfile(info, io.BytesIO(data))
    data = ('\n'.join(manifest) + '\n').encode()
    info = tarfile.TarInfo(f'{prefix}/SOURCE_MANIFEST.sha256')
    info.size = len(data); info.mode = 0o644
    bundle.addfile(info, io.BytesIO(data))
checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
(output / f'{prefix}.sha256').write_text(f'{checksum}  {archive.name}\n')
print(f'Created {archive.relative_to(ROOT)} ({len(files)} source files)')
