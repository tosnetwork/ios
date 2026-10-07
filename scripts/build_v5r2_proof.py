#!/usr/bin/env python3
"""Generate the pinned source-built proof XCFramework before project builds."""
import fcntl
import filecmp
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def main():
    repo = Path(__file__).resolve().parents[1]
    cache = repo / '.native/v5r2-proof'
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / 'build.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        revision = (repo / 'scripts/v5r2-proof-revision.txt').read_text().strip()
        if not re.fullmatch(r'[0-9a-f]{40}', revision):
            raise RuntimeError('Expected an immutable proof source revision')
        default_source = (cache / 'source').resolve()
        source = Path(os.environ.get('TOS_PROOF_ROOT', default_source)).resolve()
        if not source.exists():
            subprocess.run(['git', 'clone', '--filter=blob:none', '--no-checkout', 'https://github.com/tosnetwork/tos.git', str(source)], check=True)
            subprocess.run(['git', '-C', str(source), 'checkout', '--detach', revision], check=True)
            subprocess.run(['git', '-C', str(source), 'submodule', 'update', '--init', '--recursive'], check=True)
        head = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
        if subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain'], text=True).strip():
            raise RuntimeError('Proof source contains local changes')
        if head != revision and source == default_source:
            subprocess.run(['git', '-C', str(source), 'fetch', 'origin', revision], check=True)
            subprocess.run(['git', '-C', str(source), 'checkout', '--detach', revision], check=True)
            subprocess.run(['git', '-C', str(source), 'submodule', 'update', '--init', '--recursive'], check=True)
            head = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
        if head != revision:
            raise RuntimeError('Provided proof source does not match the pinned revision')
        builds = Path(os.environ.get('TOS_PROOF_BUILD_ROOT', cache / 'build')).resolve()
        host = Path(os.environ.get('TOS_PROOF_HOST_BUILD', builds / 'host')).resolve()
        if not (host / 'CMakeCache.txt').exists():
            subprocess.run(['cmake', '-S', str(source), '-B', str(host), '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', '-DTOS_USE_ROCKSDB=OFF', '-DTOS_USE_ABSEIL=OFF'], check=True)
        files = {}
        for name, sdk, arch in [('device', 'iphoneos', 'arm64'), ('sim-arm64', 'iphonesimulator', 'arm64'), ('sim-x86_64', 'iphonesimulator', 'x86_64')]:
            target = builds / name
            subprocess.run(['python3', str(source / 'scripts/build-embedded-proof-ios.py'), '--host-build', str(host), '--build-dir', str(target), '--sdk', sdk, '--arch', arch], check=True)
            files[name] = target / 'lite-client/proof-verify/libtosproofverify.dylib'
        output = repo / 'LocalPackages/core-swift/Generated/TOSProofVerify.xcframework'
        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='proof-stage-', dir=output.parent) as temporary:
            stage = Path(temporary) / output.name
            subprocess.run(['python3', str(source / 'scripts/package-embedded-proof-xcframework.py'), '--device', str(files['device']), '--sim-arm64', str(files['sim-arm64']), '--sim-x86_64', str(files['sim-x86_64']), '--output', str(stage)], check=True)
            relative = {p.relative_to(stage) for p in stage.rglob('*') if p.is_file()}
            old = {p.relative_to(output) for p in output.rglob('*') if p.is_file()} if output.exists() else set()
            if relative == old and all(filecmp.cmp(stage / p, output / p, shallow=False) for p in relative):
                print('Proof XCFramework bytes unchanged; retaining outputs')
            else:
                if output.exists(): shutil.rmtree(output)
                shutil.copytree(stage, output)


if __name__ == '__main__':
    main()
