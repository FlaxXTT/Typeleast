#!/usr/bin/env python3
"""Exercise the Mac bootstrap with mocked downloads/auth; never use real credentials."""
import hashlib
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import zipfile

root = Path(__file__).resolve().parents[1]
source = (root / 'scripts/setup-publisher-on-mac.sh').read_text()
official_arm_sha = '23b12706219b9892e44236f988444a24adcf29284e16b35e03ba5b863fb6eb8e'

with tempfile.TemporaryDirectory(prefix='typeleast-publisher-proof-') as folder:
    work = Path(folder)
    fixture_bin = work / 'bin'
    fixture_bin.mkdir()

    def executable(path, content):
        path.write_text(content)
        path.chmod(0o700)

    executable(fixture_bin / 'uname', '#!/bin/bash\nif [ "$1" = -s ]; then echo Darwin; else echo arm64; fi\n')
    gh = '''#!/usr/bin/env python3
import os, sys
from pathlib import Path
args = sys.argv[1:]
state = Path(os.environ['FIXTURE_STATE'])
if args == ['--version']:
    sys.exit(1 if os.environ.get('INSTALL_CLI') == '1' else 0)
if args[:2] == ['auth', 'status']:
    sys.exit(1 if os.environ.get('REQUIRE_LOGIN') == '1' and not (state/'login').exists() else 0)
if args[:2] == ['auth', 'login']:
    assert '--web' in args and args[args.index('--hostname')+1] == 'github.com'
    (state/'login').touch()
    sys.exit(0)
assert args[:2] in [['secret', 'list'], ['secret', 'set']], args
assert args[args.index('--repo')+1] == 'FlaxXTT/Typeleast'
if args[1] == 'list':
    print(len(list(state.glob('MACOS_SIGNING_*'))))
else:
    assert args[2] in ['MACOS_SIGNING_CERTIFICATE_BASE64', 'MACOS_SIGNING_CERTIFICATE_PASSWORD']
    assert len(sys.stdin.buffer.read()) > 0
    (state/args[2]).touch()
'''
    executable(fixture_bin / 'gh', gh)
    archive = work / 'cli.zip'
    with zipfile.ZipFile(archive, 'w') as z:
        entry = zipfile.ZipInfo('gh_2.104.0_macOS_arm64/bin/gh')
        entry.external_attr = 0o100755 << 16
        z.writestr(entry, gh)
    fixture_sha = hashlib.sha256(archive.read_bytes()).hexdigest()
    bootstrap = work / 'bootstrap.sh'
    assert source.count(official_arm_sha) == 1
    # Only the immutable archive digest changes for this fake executable.
    # All download, checksum enforcement, install and authentication code is real.
    bootstrap.write_text(source.replace(official_arm_sha, fixture_sha))
    executable(fixture_bin / 'curl', '''#!/usr/bin/env python3
import os, shutil, sys
from pathlib import Path
args = sys.argv[1:]
url = next(a for a in args if a.startswith('https://'))
out = Path(args[args.index('-o')+1])
state = Path(os.environ['FIXTURE_STATE'])
with (state/'downloads').open('a') as log: log.write(url+'\\n')
if url == 'https://github.com/cli/cli/releases/download/v2.104.0/gh_2.104.0_macOS_arm64.zip':
    shutil.copyfile(os.environ['FIXTURE_ARCHIVE'], out)
    if os.environ.get('CORRUPT_ARCHIVE') == '1':
        with out.open('ab') as f: f.write(b'changed')
elif url == 'https://raw.githubusercontent.com/FlaxXTT/Typeleast/d283d868aa92824e8d1ae2ffdd3d1c68bcb3b642/apps/macos/scripts/configure-publisher-signing.sh':
    if os.environ.get('CORRUPT_HELPER') == '1': out.write_text('changed')
    else: shutil.copyfile(os.environ['FIXTURE_HELPER'], out)
else: raise AssertionError('unexpected network destination')
''')

    def run_case(name, **options):
        case = work / name
        case.mkdir()
        state = case / 'state'
        state.mkdir()
        env = dict(os.environ)
        for key in ('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN'):
            env.pop(key, None)
        env.update(PATH=str(fixture_bin) + os.pathsep + env['PATH'], FIXTURE_STATE=str(state),
                   FIXTURE_ARCHIVE=str(archive), FIXTURE_HELPER=str(root/'scripts/configure-publisher-signing.sh'),
                   TYPELEAST_SIGNING_TOOLS_DIR=str(case/'tools'), TYPELEAST_SIGNING_BACKUP_DIR=str(case/'backup'))
        env.update(options)
        result = subprocess.run(['bash', str(bootstrap)], env=env, capture_output=True, timeout=60)
        return case, state, env, result

    for name, options in [('existing-cli', {}), ('install-cli', {'INSTALL_CLI': '1', 'REQUIRE_LOGIN': '1'})]:
        case, state, env, result = run_case(name, **options)
        assert result.returncode == 0, result.stderr.decode()
        backup = case / 'backup'
        assert stat.S_IMODE(backup.stat().st_mode) == 0o700
        assert stat.S_IMODE((backup/'password').stat().st_mode) == 0o600
        assert (backup/'root-key.enc.pem').is_file() and (backup/'identity.p12').is_file()
        assert not (backup/'leaf-key.pem').exists()
        assert (backup/'password').read_bytes() not in result.stdout + result.stderr
        assert len(list(state.glob('MACOS_SIGNING_*'))) == 2
        if options:
            assert (state/'login').exists()
            assert (case/'tools/gh-2.104.0-arm64/bin/gh').is_file()
        original_identity = (backup/'identity.p12').read_bytes()
        repeated = subprocess.run(['bash', str(bootstrap)], env=env, capture_output=True, timeout=60)
        assert repeated.returncode != 0 and b'Refusing to rotate or overwrite' in repeated.stderr
        assert (backup/'identity.p12').read_bytes() == original_identity
        assert (state/'downloads').read_text().count('/cli/cli/releases/') == (1 if options else 0)
        print('PASS:', name, 'sets both secrets, keeps private backup, and refuses identity rotation')

    for name, options in [('changed-cli', {'INSTALL_CLI': '1', 'CORRUPT_ARCHIVE': '1'}),
                          ('changed-helper', {'CORRUPT_HELPER': '1'})]:
        case, state, env, result = run_case(name, **options)
        assert result.returncode != 0
        assert not (case/'backup').exists() and not list(state.glob('MACOS_SIGNING_*'))
        print('PASS:', name, 'fails checksum validation before creating or uploading keys')
