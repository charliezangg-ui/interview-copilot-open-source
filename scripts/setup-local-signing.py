#!/usr/bin/env python3
"""Opt-in local development identity; never an Apple distribution certificate.

Run only after the operator agrees to add a code-signing-only trust entry.
System authentication and keychain access dialogs remain with the operator.
"""
import argparse
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import tempfile

NAME = 'InterviewCopilot Local Development'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--confirm-local-signing', action='store_true')
args = parser.parse_args()
if not args.confirm_local_signing:
    parser.error('需要明确同意本机开发证书及仅限代码签名的信任设置。')
os.umask(0o077)

def run(argv):
    result = subprocess.run(argv, text=True, capture_output=True)
    if result.returncode:
        # Never print command arguments: the PKCS12 passphrase is transient.
        raise SystemExit(result.stderr.strip() or '命令执行失败')
    return result.stdout

valid = run(['security', 'find-identity', '-v', '-p', 'codesigning'])
if f'"{NAME}"' in valid:
    print('固定本机开发签名身份已就绪。')
    raise SystemExit(0)
existing = run(['security', 'find-certificate', '-a'])
if NAME in existing:
    raise SystemExit('同名证书已存在但尚未有效。请在钥匙串中检查其代码签名信任，不自动生成替代身份。')
keychain = shlex.split(run(['security', 'default-keychain', '-d', 'user']))[0]
with tempfile.TemporaryDirectory(prefix='interview-copilot-signing-') as folder:
    root = Path(folder)
    config = root / 'certificate.cnf'
    config.write_text(f'''[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN={NAME}
[ext]
basicConstraints=critical,CA:true
keyUsage=critical,digitalSignature,keyCertSign
extendedKeyUsage=codeSigning
''')
    private, certificate, bundle = [root / name for name in ('key.pem', 'certificate.pem', 'identity.p12')]
    password = secrets.token_hex(32)
    run(['openssl', 'req', '-new', '-x509', '-newkey', 'rsa:3072', '-nodes', '-days', '1825',
         '-config', str(config), '-keyout', str(private), '-out', str(certificate)])
    run(['openssl', 'pkcs12', '-export', '-inkey', str(private), '-in', str(certificate),
         '-out', str(bundle), '-passout', 'pass:' + password])
    run(['security', 'import', str(bundle), '-k', keychain, '-P', password, '-x', '-T', '/usr/bin/codesign'])
    # User domain only. No TLS/SSL trust and no global trust-all or keychain ACL changes.
    # macOS may request authentication; it must be completed by the operator.
    run(['security', 'add-trusted-cert', '-r', 'trustRoot', '-p', 'codeSign', '-k', keychain, str(certificate)])
valid = run(['security', 'find-identity', '-v', '-p', 'codesigning'])
if f'"{NAME}"' not in valid:
    raise SystemExit('证书未通过代码签名校验，停止。未修改应用或录音权限。')
print('本机开发签名身份已就绪；私钥留在用户钥匙串，临时私钥及导出文件已移除。')
