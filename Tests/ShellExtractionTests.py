"""Invoke actual Shell COM commands, then replay into the retained GUI with real mapped archive names."""
import ctypes as C
import mmap
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

interface, shell, probe, capture = map(lambda value: Path(value).resolve(), sys.argv[1:])
test_root = Path(__file__).resolve().parents[1] / 'Output/Custom/Tests'
k = C.WinDLL('kernel32', use_last_error=True)
k.CreateEventW.argtypes = [C.c_void_p, C.c_int, C.c_int, C.c_wchar_p]
k.CreateEventW.restype = C.c_void_p
k.CloseHandle.argtypes = [C.c_void_p]
shell32 = C.WinDLL('shell32', use_last_error=True)
shell32.CommandLineToArgvW.argtypes = [C.c_wchar_p, C.POINTER(C.c_int)]
shell32.CommandLineToArgvW.restype = C.POINTER(C.c_wchar_p)
k.LocalFree.argtypes = [C.c_void_p]
startup = subprocess.STARTUPINFO()
startup.dwFlags = subprocess.STARTF_USESHOWWINDOW
startup.wShowWindow = 0
with tempfile.TemporaryDirectory(prefix='shell-extract-', dir=test_root) as temporary:
    work = Path(temporary)
    runtime = work / 'capture-runtime'
    runtime.mkdir()
    for path in interface.iterdir():
        if path.suffix.lower() in ('.dll', '.pri'):
            shutil.copyfile(path, runtime / path.name)
    shutil.copyfile(shell, runtime / 'NanaZip.ShellExtension.dll')
    shutil.copyfile(capture, runtime / 'NanaZip.Universal.Windows.exe')
    for selection_count in (1, 2):
        folder = work / f'Chinese space \u4e2d\u6587 & [files] {selection_count}'
        folder.mkdir()
        archives = [folder / f'archive {index}.zip' for index in range(selection_count)]
        for archive in archives:
            with zipfile.ZipFile(archive, 'w') as z:
                z.writestr('initial.txt', b'initial')
        prefix = folder / 'captured'
        subprocess.run([str(probe), str(runtime / shell.name), str(prefix), *map(str, archives)], check=True, timeout=30)
        for index in range(1, 5):
            command = Path(str(prefix) + f'_{index}').read_text(encoding='utf-16-le')
            expected_executable = f'"{runtime / "NanaZip.Universal.Windows.exe"}" '
            assert command.startswith(expected_executable), command
            arguments = command[len(expected_executable):]
            assert arguments.startswith('x '), arguments
            match = re.search(r' -ai#([^: ]+):(\d+):([^ ]+)', arguments)
            assert match, arguments
            mapping_name, size, event_name = match.groups()
            data = Path(str(prefix) + f'_{index}.names').read_bytes()
            assert len(data) == int(size)
            assert data.decode('utf-16-le').split('\0') == ['', *map(str, archives), '']
            # A unique member for each invocation prevents earlier successful
            # extractions from masking a failed operation.
            for number, archive in enumerate(archives):
                with zipfile.ZipFile(archive, 'w') as z:
                    z.writestr(f'marker-{index}-{number}.txt', f'contents {index} {number}'.encode())
            mapping = mmap.mmap(-1, len(data), tagname=mapping_name)
            mapping.write(data)
            event = k.CreateEventW(None, True, False, event_name)
            assert event
            try:
                # Suppress prompts; the dialog command uses the same parser but
                # must not wait for a human to choose its destination in CI.
                arguments = arguments.replace(' -ad', '')
                arguments = 'x -y' + arguments[1:]
                gui_command = f'"{interface / "NanaZip.Universal.Windows.exe"}" {arguments}'
                result = subprocess.run(gui_command, startupinfo=startup, timeout=30)
                assert result.returncode == 0, f'Menu {index}, {selection_count} archive(s): GUI exit {result.returncode}; {arguments}'
                count = C.c_int()
                tokens = shell32.CommandLineToArgvW(gui_command, C.byref(count))
                assert tokens
                try:
                    output_directory = next(tokens[i][2:] for i in range(count.value) if tokens[i].startswith('-o'))
                finally:
                    k.LocalFree(tokens)
                expected_files = []
                for number in range(selection_count):
                    expected = (Path(output_directory.replace('*', archives[number].stem)) / f'marker-{index}-{number}.txt').resolve()
                    assert expected.is_relative_to(folder), expected
                    assert expected.read_bytes() == f'contents {index} {number}'.encode(), expected
                    expected_files.append(expected)
                # The same spelling must work with the current source parser,
                # not only the retained GUI's older ZS parser.
                for expected in expected_files:
                    expected.unlink()
                console = Path(__file__).resolve().parents[1] / 'Output/Binaries/Release/x64/NanaZip.Universal.Console.exe'
                console_command = f'"{console}" {arguments}'
                result = subprocess.run(console_command, capture_output=True, timeout=30)
                assert result.returncode == 0, result.stdout + result.stderr
                for number, expected in enumerate(expected_files):
                    assert expected.read_bytes() == f'contents {index} {number}'.encode(), expected
            finally:
                mapping.close()
                k.CloseHandle(event)
        print(f'PASS: real Shell Invoke -> shared archive list -> retained GUI extraction, four commands, {selection_count} archive(s), Unicode/spaces/&')
