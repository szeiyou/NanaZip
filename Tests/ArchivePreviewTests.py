"""Exercise real metadata readers and their bounded, non-extracting file tree."""
from pathlib import Path
import subprocess
import struct
import sys
import tempfile
import zipfile
import zlib

probe, core, console, shell_probe, shell = map(lambda value: Path(value).resolve(), sys.argv[1:6])
root = Path(__file__).resolve().parents[1] / 'Output/Custom/Tests'
root.mkdir(parents=True, exist_ok=True)

def read(path, budget=350):
    result = subprocess.run([str(probe), str(core), str(path), str(budget)],
        capture_output=True, timeout=10, check=True)
    lines = result.stdout.decode('utf-8').splitlines()
    state, truncated = map(int, lines[0].split('\t'))
    rows = [(int(depth), kind, name) for depth, kind, name in
            (line.split('\t', 2) for line in lines[1:])]
    return state, truncated, rows

with tempfile.TemporaryDirectory(prefix='preview-', dir=root) as temporary:
    work = Path(temporary)
    archive = work / 'tree.zip'
    with zipfile.ZipFile(archive, 'w') as z:
        z.writestr('项目/图片/a.png', b'image')  # no explicit directory entries
        z.writestr('项目/setup.exe', b'program')
        z.writestr('说明.txt', b'readme')
        z.writestr('空文件夹/', b'')
    state, truncated, rows = read(archive)
    assert state == 1 and not truncated, (state, rows)
    assert rows == [(0,'D','项目'),(1,'D','图片'),(2,'F','a.png'),
                    (1,'F','setup.exe'),(0,'F','说明.txt'),(0,'D','空文件夹')], rows
    print('PASS: file/folder icons model, Unicode, inferred folders, depth-first hierarchy, empty folder')
    subprocess.run([str(shell_probe),str(shell),str(archive)],check=True,timeout=15)
    # Names shared by a root file and a directory cannot be silently merged.
    conflict = work / 'conflict.zip'
    with zipfile.ZipFile(conflict, 'w') as z:
        z.writestr('same', b'file')
        z.writestr('same/a.txt', b'child')
    assert read(conflict)[0] == 2
    print('PASS: conflicting file/directory paths rejected')
    empty = work / 'empty.zip'
    with zipfile.ZipFile(empty,'w'): pass
    assert read(empty) == (1, 0, [])
    many = work / 'many.zip'
    with zipfile.ZipFile(many,'w') as z:
        for index in range(30): z.writestr(f'{index}.txt', b'x')
    assert read(many)[1] == 1 and len(read(many)[2]) == 12
    deep = work / 'deep.zip'
    with zipfile.ZipFile(deep,'w') as z: z.writestr('a/b/c/d/e.txt', b'x')
    assert read(deep)[1] == 1 and len(read(deep)[2]) == 3
    assert read(archive, 0)[0] == 3
    print('PASS: empty archive, row/depth limits and time-budget abort')
    broken = work / 'broken.zip'
    broken.write_bytes(b'not a zip')
    assert read(broken)[0] == 2
    truncated = work / 'truncated.zip'
    data = archive.read_bytes()
    second = data.index(b'PK\x03\x04', 4)
    truncated.write_bytes(data[:second + 10])
    assert read(truncated)[0] == 2, 'Recovered partial headers were displayed as a complete tree'
    text = work / 'ordinary.txt'
    text.write_text('not an archive')
    assert read(text)[0] == 0
    unsafe = work / 'unsafe.zip'
    with zipfile.ZipFile(unsafe,'w') as z: z.writestr('../outside.txt', b'x')
    assert read(unsafe)[0] == 2
    print('PASS: invalid/unsupported/unsafe paths fail without extraction or prompts')
    source = work / 'source'
    (source / 'nested').mkdir(parents=True)
    (source / 'nested/a.txt').write_text('test')
    for encrypted in (False, True):
        seven = work / ('encrypted.7z' if encrypted else 'tree.7z')
        command = [str(console),'a','-t7z',str(seven),str(source)]
        if encrypted: command += ['-psecret','-mhe=on']
        subprocess.run(command, capture_output=True, check=True, timeout=30)
        state, _, rows = read(seven)
        if encrypted: assert state == 2, state
        else: assert state == 1 and any(row[2]=='a.txt' and row[0]==2 for row in rows), rows
    print('PASS: 7z metadata and encrypted-header fallback without password UI')
    # Minimal stored RAR4/RAR5 fixtures, built from the local handler layouts.
    # Validate their data CRCs with the real console before testing preview.
    def vint(value):
        result = bytearray()
        while value > 127:
            result.append((value & 127) | 128)
            value >>= 7
        return bytes(result) + bytes([value])
    def rar4_header(kind, flags, data):
        body = struct.pack('<BHH',kind,flags,7+len(data)) + data
        return struct.pack('<H',zlib.crc32(body) & 65535) + body
    def rar5_header(data):
        body = vint(len(data)) + data
        return struct.pack('<I',zlib.crc32(body)) + body
    contents = b'RAR preview fixture'
    name = b'folder/a.txt'
    rar4 = (b'Rar!\x1a\x07\x00' + rar4_header(0x73,0,b'\0'*6) +
        rar4_header(0x74,0x8000,struct.pack('<IIBIIBBHI',len(contents),len(contents),2,
            zlib.crc32(contents),0,20,0x30,len(name),32)+name) + contents + rar4_header(0x7b,0,b''))
    rar5 = (b'Rar!\x1a\x07\x01\x00' + rar5_header(b'\x01\x00\x00') +
        rar5_header(b'\x02\x02'+vint(len(contents))+b'\x04'+vint(len(contents))+b'\x20'+
            struct.pack('<I',zlib.crc32(contents))+b'\x00\x00'+vint(len(name))+name) +
        contents + rar5_header(b'\x05\x00\x00'))
    for version, data in [(4,rar4),(5,rar5)]:
        rar = work / f'v{version}.rar'
        rar.write_bytes(data)
        subprocess.run([str(console),'t',str(rar)],capture_output=True,check=True,timeout=10)
        assert read(rar) == (1,0,[(0,'D','folder'),(1,'F','a.txt')]), read(rar)
    print('PASS: real RAR4/RAR5 stored archives (independently checked by console integrity test)')
    assert not (work / 'outside.txt').exists()
print('ALL ARCHIVE PREVIEW CHECKS PASSED')
