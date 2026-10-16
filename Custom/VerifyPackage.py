"""Read-only verification of a custom bundle, its file blocks and provenance."""
import base64
import hashlib
import io
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
import zipfile

directory = Path(sys.argv[1])
info = json.loads((directory / 'build-info.json').read_text(encoding='utf-8-sig'))
package = directory / info['PackageName']
assert package.parent.resolve() == directory.resolve() and package.suffix == '.msixbundle'
assert hashlib.sha256(package.read_bytes()).hexdigest().upper() == info['PackageSHA256'], 'Bundle SHA-256 mismatch'

def xml(archive, name):
    return ET.fromstring(archive.read(name))

def blocks(archive, additional=()):
    ns = '{http://schemas.microsoft.com/appx/2010/blockmap}'
    count = 0
    names = archive.namelist()
    assert len(names) == len({name.lower() for name in names}), 'Duplicate package members'
    covered = set()
    assert archive.testzip() is None
    for file in xml(archive, 'AppxBlockMap.xml').findall(ns + 'File'):
        name = file.attrib['Name'].replace('\\', '/')
        covered.add(name)
        data = archive.read(name)
        assert len(data) == int(file.attrib['Size'])
        block_list = file.findall(ns + 'Block')
        assert len(block_list) == (len(data) + 65535) // 65536
        for index, block in enumerate(block_list):
            chunk = data[index * 65536:(index + 1) * 65536]
            assert base64.b64encode(hashlib.sha256(chunk).digest()).decode() == block.attrib['Hash']
        count += 1
    footprint = {'AppxBlockMap.xml', '[Content_Types].xml', 'AppxSignature.p7x', 'AppxMetadata/CodeIntegrity.cat'}
    assert not (set(names) - covered - footprint - set(additional)), 'Unsigned/unmapped package members'
    return count

with zipfile.ZipFile(package) as bundle:
    bns = '{http://schemas.microsoft.com/appx/2013/bundle}'
    manifest = xml(bundle, 'AppxMetadata/AppxBundleManifest.xml')
    identity = manifest.find(bns + 'Identity').attrib
    for key, expected in [('Name', info['PackageIdentity']), ('Publisher', info['Publisher']), ('Version', info['Version'])]:
        assert identity[key] == expected, key
    packages = manifest.find(bns + 'Packages').findall(bns + 'Package')
    assert len(packages) == 1 and packages[0].attrib['Architecture'] == 'x64'
    assert packages[0].attrib['Type'] == 'application'
    assert packages[0].attrib['Version'] == info['Version']
    bundle_count = blocks(bundle, [item.attrib['FileName'] for item in packages])
    inner_bytes = bundle.read(packages[0].attrib['FileName'])
    assert len(inner_bytes) == int(packages[0].attrib['Size'])
    with zipfile.ZipFile(io.BytesIO(inner_bytes)) as inner:
        app_count = blocks(inner)
        app = xml(inner, 'AppxManifest.xml')
        ans = '{http://schemas.microsoft.com/appx/manifest/foundation/windows10}'
        app_identity = app.find(ans + 'Identity').attrib
        for key in ('Name', 'Publisher', 'Version'):
            assert app_identity[key] == identity[key], key
        assert app_identity['ProcessorArchitecture'] == 'x64'
        assert info['RuntimeSHA256']['NanaZip.Core.dll'] == info['OptimizedCoreSHA256']
        for group in ('RuntimeSHA256', 'PreservedInterfaceSHA256'):
            for name, expected in info[group].items():
                assert hashlib.sha256(inner.read(name)).hexdigest().upper() == expected, name
print(f'PASS: bundle/app identities, x64, {bundle_count}/{app_count} block-map files, runtime and preserved interface hashes.')
