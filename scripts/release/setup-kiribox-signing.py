#!/usr/bin/env python3
"""Create one durable signing identity, then upload it with an authorised gh CLI.

The destination is private local storage, never an artifact or a git directory.
Reruns reuse the same identity. The public fingerprint may be committed.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--repository', default='KiriKira/flutter_server_box')
    parser.add_argument('--upload', action='store_true')
    args = parser.parse_args()
    directory = args.directory.resolve()
    git_root = subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip()
    if directory.is_relative_to(Path(git_root).resolve()):
        raise SystemExit('Store the private signing backup outside the git checkout')
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(directory, 0o700)
    config = directory / 'signing.json'
    keystore = directory / 'kiribox-release.p12'
    if config.exists() != keystore.exists():
        raise SystemExit('Incomplete identity: restore the original pair; do not rotate the key silently')
    if config.exists():
        data = json.loads(config.read_text())
    else:
        password = secrets.token_urlsafe(36)
        data = {'alias': 'kiribox', 'store_password': password, 'key_password': password}
        subprocess.run([
            'keytool', '-genkeypair', '-noprompt', '-keystore', str(keystore),
            '-storetype', 'PKCS12', '-storepass:env', 'KIRIBOX_SETUP_PASSWORD',
            '-keypass:env', 'KIRIBOX_SETUP_PASSWORD', '-alias', data['alias'],
            '-keyalg', 'RSA', '-keysize', '3072', '-validity', '10000',
            '-dname', 'CN=KiriBox, O=KiriKira',
        ], env={**os.environ, 'KIRIBOX_SETUP_PASSWORD': password}, check=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        config.write_text(json.dumps(data, indent=2) + '\n')
    os.chmod(keystore, 0o600)
    os.chmod(config, 0o600)
    certificate = subprocess.check_output([
        'keytool', '-exportcert', '-keystore', str(keystore), '-alias', data['alias'],
        '-storepass:env', 'KIRIBOX_SETUP_PASSWORD',
    ], env={**os.environ, 'KIRIBOX_SETUP_PASSWORD': data['store_password']}, stderr=subprocess.DEVNULL)
    import hashlib
    fingerprint = hashlib.sha256(certificate).hexdigest()
    (directory / 'certificate-sha256.txt').write_text(fingerprint + '\n')
    print('Signing certificate SHA-256:', fingerprint)
    if args.upload:
        values = {
            'KIRIBOX_KEYSTORE_BASE64': base64.b64encode(keystore.read_bytes()).decode(),
            'KIRIBOX_KEYSTORE_PASSWORD': data['store_password'],
            'KIRIBOX_KEY_ALIAS': data['alias'],
            'KIRIBOX_KEY_PASSWORD': data['key_password'],
        }
        # Check access before uploading a partial configuration. Nothing secret
        # is sent in arguments, logged, or committed.
        subprocess.run(['gh', 'api', f'repos/{args.repository}/actions/secrets/public-key',
                        '--silent'], check=True)
        for name, value in values.items():
            subprocess.run(['gh', 'secret', 'set', name, '--repo', args.repository],
                           input=value.encode(), check=True, stdout=subprocess.DEVNULL)
        print('Uploaded all four signing secrets; retain the private directory as a backup.')
    else:
        print('Private identity saved locally. Use --upload with a credential allowed to manage Actions secrets.')


if __name__ == '__main__':
    main()
