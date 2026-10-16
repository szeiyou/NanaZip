"""Integration checks for the ZIP decode-ahead path. Run against a built console.

python Tests/ZipParallelTests.py Output/Binaries/Release/x64/NanaZip.Universal.Console.exe
"""
import hashlib
from pathlib import Path
import random
import struct
import subprocess
import sys
import tempfile
import zipfile

exe = Path(sys.argv[1]).resolve()
work_root = Path(__file__).resolve().parent.parent / '.benchmarks' / 'zip_parallel_tests'
work_root.mkdir(parents=True, exist_ok=True)
rng = random.Random(42)
# Each member is large enough to exercise buffered and direct-stream writes.
payloads = [rng.randbytes(8 * 1024**2) for _ in range(6)]

def sha(data):
    return hashlib.sha256(data).hexdigest()

def run(args, success=True):
    result = subprocess.run([str(exe), *args], capture_output=True, timeout=60)
    if (result.returncode == 0) != success:
        raise AssertionError((args, result.returncode, result.stdout[-2000:], result.stderr))
    return result

def check(target, expected):
    actual = {p.relative_to(target).as_posix(): sha(p.read_bytes())
              for p in target.rglob('*') if p.is_file()}
    assert actual == {k: sha(v) for k, v in expected.items()}, (actual, expected.keys())

with tempfile.TemporaryDirectory(dir=work_root) as temporary:
    root = Path(temporary)
    archive = root / 'mixed.zip'
    entries = {'目录/': b'', '目录/中文.bin': payloads[0],
               'nested/a.bin': payloads[1], 'b.bin': payloads[2],
               'c.bin': payloads[3], 'd.bin': payloads[4], 'empty.bin': b''}
    with zipfile.ZipFile(archive, 'w', allowZip64=True) as z:
        for index, (name, data) in enumerate(entries.items()):
            z.writestr(name, data, compress_type=zipfile.ZIP_STORED if index == 3 else zipfile.ZIP_DEFLATED)
    expected = {k: v for k, v in entries.items() if not k.endswith('/')}
    for threads in [1, 2, 8]:
        target = root / f'threads_{threads}'
        run(['x', '-y', f'-mmt={threads}', str(archive), f'-o{target}'])
        check(target, expected)
        run(['t', f'-mmt={threads}', str(archive)])
    print('PASS: mixed Store/Deflate, directories, Unicode, empty files, t/x, mmt=1/2/8', flush=True)

    target = root / 'subset'
    selected = ['nested/a.bin', 'b.bin', 'c.bin', 'd.bin']
    run(['x', '-y', str(archive), f'-o{target}', *selected])
    check(target, {k: expected[k] for k in selected})
    print('PASS: selected indices', flush=True)

    target = root / 'low_memory'
    run(['x', '-y', '-mmt=2', '-mmemuse=32m', str(archive), f'-o{target}'])
    check(target, expected)
    run(['t', '-mmemuse=1m', str(archive)])
    print('PASS: bounded-buffer backpressure and low-memory fallback', flush=True)

    target = root / 'skip'
    target.mkdir()
    (target / 'c.bin').write_bytes(b'existing file')
    run(['x', '-aos', str(archive), f'-o{target}'])
    check(target, {**expected, 'c.bin': b'existing file'})
    print('PASS: overwrite skip', flush=True)

    duplicate = root / 'duplicate.zip'
    with zipfile.ZipFile(duplicate, 'w', compression=zipfile.ZIP_DEFLATED) as z:
        for index in range(5):
            z.writestr('same.bin' if index in (0, 4) else f'{index}.bin', payloads[index])
    target = root / 'duplicate'
    run(['x', '-aoa', str(duplicate), f'-o{target}'])
    check(target, {'same.bin': payloads[4], **{f'{i}.bin': payloads[i] for i in (1, 2, 3)}})
    print('PASS: duplicate entry ordering', flush=True)

    corrupted = root / 'corrupted.zip'
    contents = bytearray(archive.read_bytes())
    with zipfile.ZipFile(archive) as z:
        info = z.getinfo('c.bin')
        name_len, extra_len = struct.unpack_from('<HH', contents, info.header_offset + 26)
        data_start = info.header_offset + 30 + name_len + extra_len
        contents[data_start + info.compress_size // 2] ^= 1
    corrupted.write_bytes(contents)
    run(['t', str(corrupted)], success=False)
    run(['x', '-y', str(corrupted), f'-o{root / "bad"}'], success=False)
    print('PASS: corrupted data reports failure without hanging', flush=True)

    fallback = root / 'bzip2.zip'
    with zipfile.ZipFile(fallback, 'w', compression=zipfile.ZIP_BZIP2) as z:
        for name, data in expected.items():
            z.writestr(name, data)
    target = root / 'bzip2'
    run(['x', '-y', str(fallback), f'-o{target}'])
    check(target, expected)
    print('PASS: unsupported parallel methods fall back', flush=True)

    encrypted = root / 'encrypted.zip'
    encrypt_input = root / 'encrypt_input'
    encrypt_input.mkdir()
    encrypted_expected = {f'{i}.bin': payloads[i] for i in range(4)}
    for name, data in encrypted_expected.items():
        (encrypt_input / name).write_bytes(data)
    run(['a', '-tzip', '-ptest-password', str(encrypted), str(encrypt_input / '*.bin')])
    target = root / 'encrypted'
    run(['x', '-y', '-ptest-password', str(encrypted), f'-o{target}'])
    check(target, encrypted_expected)
    print('PASS: encrypted ZIP fallback', flush=True)

    zip64 = root / 'zip64.zip'
    with zipfile.ZipFile(zip64, 'w', compression=zipfile.ZIP_DEFLATED) as z:
        for name, data in encrypted_expected.items():
            with z.open(name, 'w', force_zip64=True) as entry:
                entry.write(data)
    target = root / 'zip64'
    run(['x', '-y', str(zip64), f'-o{target}'])
    check(target, encrypted_expected)
    print('PASS: Zip64 local headers', flush=True)

    truncated = root / 'truncated.zip'
    truncated.write_bytes(archive.read_bytes()[:-8])
    run(['t', str(truncated)], success=False)
    print('PASS: truncated archive reports failure', flush=True)
print('ALL CHECKS PASSED', flush=True)
