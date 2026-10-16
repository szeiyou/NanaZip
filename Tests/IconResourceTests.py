"""Check that release branding preserves executable code/data and its source files."""
import importlib.util
from pathlib import Path
import shutil
import struct
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('icons', root / 'Custom/SetExecutableIcon.py')
icons = importlib.util.module_from_spec(spec)
spec.loader.exec_module(icons)


def program_sections(data):
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    assert data[pe:pe + 4] == b'PE\0\0'
    count = struct.unpack_from('<H', data, pe + 6)[0]
    optional_size = struct.unpack_from('<H', data, pe + 20)[0]
    table = pe + 24 + optional_size
    result = {}
    for index in range(count):
        offset = table + index * 40
        name = data[offset:offset + 8].rstrip(b'\0')
        virtual_size, address, size, raw = struct.unpack_from('<IIII', data, offset + 8)
        if name != b'.rsrc':
            # Win32 may move the trailing relocation section when .rsrc grows;
            # its unchanged contents remain located through the PE directory.
            result[name] = (virtual_size, None if name == b'.reloc' else address, data[raw:raw + size])
    return result


source = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='icons-', dir=root / 'Output/Custom/Tests') as temp:
    for name in ('NanaZip.Modern.FileManager.exe', 'NanaZip.Universal.Windows.exe', 'NanaZip.Core.Windows.sfx'):
        original = (source / name).read_bytes()
        copy = Path(temp) / name
        shutil.copyfile(source / name, copy)
        icon = root / 'Assets' / ('NanaZipSfx.ico' if name.endswith('.sfx') else 'NanaZip.ico')
        icons.replace(copy, icon)
        assert program_sections(copy.read_bytes()) == program_sections(original), 'Program code/data changed: ' + name
        assert (source / name).read_bytes() == original, 'Source executable was modified'
        icons.inspect(copy, icons.icon_frames(icon), verify=True)
        first = copy.read_bytes()
        icons.replace(copy, icon)
        assert copy.read_bytes() == first, 'Icon replacement is not idempotent'
        bad = Path(temp) / 'invalid.ico'
        bad.write_bytes(b'\0' * 6)
        try:
            icons.replace(copy, bad)
        except ValueError:
            pass
        else:
            raise AssertionError('Malformed ICO accepted')
        assert copy.read_bytes() == first, 'Malformed icon altered executable'
        print('PASS: release icon, unchanged code/data/source, repeat application and invalid-input rejection: ' + name)
