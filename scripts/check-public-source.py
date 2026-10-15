#!/usr/bin/env python3
"""Check publishable files; report locations, never matched secret values.

This is a project-specific guard, used alongside Gitleaks and human review.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
TOP_FILES = {'.gitignore', 'Package.swift', 'Package.resolved', 'README.md', 'LICENSE',
             'SECURITY.md', 'CONTRIBUTING.md', 'CHANGELOG.md', 'SOURCE_MANIFEST.sha256'}
PUBLIC_DIRS = {'Sources', 'Tests', 'Resources', 'scripts', '.github', 'docs'}
EXCLUDED_DIRS = {'.git', '.build', 'dist', 'private-data', 'release-output', '__pycache__'}
FORBIDDEN_PARTS = {'sessions', 'imports', 'backups', 'qasessions', 'qa'}
ALLOWED_EXTENSIONS = {'.swift', '.json', '.md', '.txt', '.plist', '.entitlements', '.sh', '.py', '.yml', '.yaml'}
PATTERNS = {
    'private key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'access token': re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|sk-(?:proj-)?[A-Za-z0-9_-]{32,}|hf_[A-Za-z0-9]{30,})\b'),
    'personal absolute path': re.compile(r'/' + r'Users/[^/\s<>"\']+/'),
    'credential in URL': re.compile(r'https?://[^\s/:@]+:[^\s/@]+@'),
}

def paths():
    if (ROOT / '.git').exists():
        raw = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT)
        return sorted({Path(name) for name in raw.decode().split('\0')
                       if name and ((ROOT / name).exists() or (ROOT / name).is_symlink())})
    found = []
    for folder, directories, files in os.walk(ROOT):
        directories[:] = [d for d in directories if d not in EXCLUDED_DIRS]
        found.extend((Path(folder) / name).relative_to(ROOT) for name in files)
    return sorted(found)

def public_files():
    return [p for p in paths() if p.as_posix() in TOP_FILES or p.parts[0] in PUBLIC_DIRS]

def check(require_license=False):
    failures = []
    files = public_files()
    for relative in paths():
        if relative not in files:
            failures.append(f'{relative}: file is outside the public source allowlist')
    for relative in files:
        path = ROOT / relative
        if path.is_symlink() or not path.is_file():
            failures.append(f'{relative}: symlinks and non-regular files are not publishable'); continue
        if any(part.lower() in FORBIDDEN_PARTS for part in relative.parts):
            failures.append(f'{relative}: local data or internal QA path'); continue
        if len(relative.parts) > 1 and relative.suffix not in ALLOWED_EXTENSIONS:
            failures.append(f'{relative}: unexpected file type'); continue
        if path.stat().st_size > 1_000_000:
            failures.append(f'{relative}: source file exceeds 1 MB'); continue
        try:
            content = path.read_text(encoding='utf-8')
        except UnicodeDecodeError:
            failures.append(f'{relative}: binary files require explicit review'); continue
        for label, pattern in PATTERNS.items():
            for match in pattern.finditer(content):
                # A negative URL-validation fixture has deliberately fake credentials.
                if label == 'credential in URL' and relative.as_posix() == 'Tests/CopilotCoreTests/HireTests.swift':
                    continue
                line = content.count('\n', 0, match.start()) + 1
                failures.append(f'{relative}:{line}: {label}')
    if require_license and not (ROOT / 'LICENSE').is_file():
        failures.append('LICENSE: choose the license and copyright holder before release')
    return files, failures

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--require-license', action='store_true')
    args = parser.parse_args()
    files, failures = check(args.require_license)
    if failures:
        print('\n'.join(failures), file=sys.stderr)
        return 1
    print(f'Public source checks passed: {len(files)} files. No candidate data or accounts accessed.')
    return 0

if __name__ == '__main__':
    sys.exit(main())
