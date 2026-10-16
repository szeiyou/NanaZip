"""Replace only group-1 icon resources in a copied Windows PE, never program code."""
import ctypes as C
from ctypes import wintypes as W
from pathlib import Path
import struct
import sys

k = C.WinDLL('kernel32', use_last_error=True)
for name, args, result in (
    ('LoadLibraryExW', [W.LPCWSTR, W.HANDLE, W.DWORD], W.HMODULE),
    ('FreeLibrary', [W.HMODULE], W.BOOL),
    ('FindResourceExW', [W.HMODULE, C.c_void_p, C.c_void_p, W.WORD], W.HANDLE),
    ('LoadResource', [W.HMODULE, W.HANDLE], W.HANDLE),
    ('LockResource', [W.HANDLE], C.c_void_p),
    ('SizeofResource', [W.HMODULE, W.HANDLE], W.DWORD),
    ('BeginUpdateResourceW', [W.LPCWSTR, W.BOOL], W.HANDLE),
    ('UpdateResourceW', [W.HANDLE, C.c_void_p, C.c_void_p, W.WORD, C.c_void_p, W.DWORD], W.BOOL),
    ('EndUpdateResourceW', [W.HANDLE, W.BOOL], W.BOOL),
):
    function = getattr(k, name)
    function.argtypes, function.restype = args, result
LANG_CALLBACK = C.WINFUNCTYPE(W.BOOL, W.HMODULE, C.c_void_p, C.c_void_p, W.WORD, C.c_ssize_t)
k.EnumResourceLanguagesW.argtypes = [W.HMODULE, C.c_void_p, C.c_void_p, LANG_CALLBACK, C.c_ssize_t]
k.EnumResourceLanguagesW.restype = W.BOOL


def checked(value):
    if not value:
        raise C.WinError(C.get_last_error())
    return value


def read_resource(module, kind, name, language):
    resource = checked(k.FindResourceExW(module, kind, name, language))
    size = checked(k.SizeofResource(module, resource))
    return C.string_at(checked(k.LockResource(checked(k.LoadResource(module, resource)))), size)


def icon_frames(path):
    data = Path(path).read_bytes()
    reserved, kind, count = struct.unpack_from('<HHH', data)
    if reserved or kind != 1 or not count or len(data) < 6 + count * 16:
        raise ValueError('Invalid ICO directory')
    frames = []
    for index in range(count):
        entry = data[6 + index * 16:22 + index * 16]
        size, offset = struct.unpack_from('<II', entry, 8)
        if not size or offset < 6 + count * 16 or offset + size > len(data):
            raise ValueError('Invalid ICO frame bounds')
        frames.append((entry[:12], data[offset:offset + size]))
    return frames


def inspect(path, frames, verify=False):
    module = checked(k.LoadLibraryExW(str(Path(path).resolve()), None, 0x22))
    try:
        languages = []
        callback = LANG_CALLBACK(lambda _m, _t, _n, language, _p: languages.append(language) or True)
        checked(k.EnumResourceLanguagesW(module, 14, 1, callback, 0))
        replacements = []
        for language in languages:
            group = read_resource(module, 14, 1, language)
            if struct.unpack_from('<HHH', group) != (0, 1, len(frames)) or len(group) != 6 + 14 * len(frames):
                raise ValueError('Unexpected group-1 icon layout; refusing to alter this executable')
            updated = group[:6]
            for index, (descriptor, image) in enumerate(frames):
                identifier = struct.unpack_from('<H', group, 6 + index * 14 + 12)[0]
                if verify:
                    assert group[6 + index * 14:18 + index * 14] == descriptor, 'Icon descriptor mismatch'
                    assert read_resource(module, 3, identifier, language) == image, 'Icon image mismatch'
                replacements.append((3, identifier, language, image))
                updated += descriptor + struct.pack('<H', identifier)
            replacements.append((14, 1, language, updated))
        return replacements
    finally:
        k.FreeLibrary(module)


def replace(path, icon):
    frames = icon_frames(icon)
    replacements = inspect(path, frames)
    handle = checked(k.BeginUpdateResourceW(str(Path(path).resolve()), False))
    try:
        for kind, identifier, language, data in replacements:
            buffer = C.create_string_buffer(data)
            checked(k.UpdateResourceW(handle, kind, identifier, language, buffer, len(data)))
    except BaseException:
        k.EndUpdateResourceW(handle, True)
        raise
    else:
        checked(k.EndUpdateResourceW(handle, False))
    inspect(path, frames, verify=True)


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == '--verify':
        inspect(sys.argv[2], icon_frames(sys.argv[3]), verify=True)
    elif len(sys.argv) == 3:
        replace(sys.argv[1], sys.argv[2])
    else:
        raise SystemExit('Usage: SetExecutableIcon.py [--verify] executable icon.ico')
    print('PASS: executable icon matches ' + Path(sys.argv[-1]).name)
