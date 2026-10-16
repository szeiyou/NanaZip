"""Create a deterministic ZIP eligible for parallel archive API tests."""
from pathlib import Path
import random
import sys
import zipfile

path = Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
rng = random.Random(42)
with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_STORED) as archive:
    for index in range(3):
        archive.writestr(f'{index}.bin', rng.randbytes(16 * 1024**2))
print(f'Created callback test fixture: {path}')
