"""Ensure an altered signed ZIP cannot pass even with an updated outer hash."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile

root = Path(__file__).resolve().parents[1]
original = Path(sys.argv[1]).resolve()
test_root = root / 'Output/Custom/Tests'
test_root.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='tamper-', dir=test_root) as temporary:
    target = Path(temporary)
    for name in ['build-info.json', 'NanaZip-ZipPerformance-Test.cer']:
        shutil.copy2(original / name, target / name)
    info = json.loads((target / 'build-info.json').read_text(encoding='utf-8-sig'))
    package = target / info['PackageName']
    shutil.copy2(original / info['PackageName'], package)
    with zipfile.ZipFile(package, 'a') as bundle:
        bundle.writestr('unsigned-test-file.txt', b'tamper test')
    # A build-info hash alone is not proof of a valid Windows package signature.
    info['PackageSHA256'] = hashlib.sha256(package.read_bytes()).hexdigest().upper()
    (target / 'build-info.json').write_text(json.dumps(info), encoding='utf-8')
    result = subprocess.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', str(root / 'Custom/Verify.ps1'), '-DistributionDirectory', str(target)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode != 0, 'A modified signed bundle was accepted'
    print('PASS: altered signed bundle rejected even when outer build-info hash is updated.')
