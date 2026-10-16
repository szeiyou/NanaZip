# Custom ZIP parallel processing

This change independently implements observable ZIP performance strategies. It
does not incorporate Bandizip code or claim knowledge of its closed-source
implementation.

## Extraction

Ordinary unencrypted Store/Deflate ZIP members are decoded ahead by up to eight
workers. Each worker owns its decoder, CRC calculation, input position and
progress counters. Seek/read pairs on the original input stream are serialized.
The shared input position is restored before returning, preserving the archive
reader's cached-position bookkeeping.

Decoded data shares a bounded memory pool (at most 512 MiB and half the
decompression memory limit). The current member drains to its output stream;
later members block when the pool is full. Extraction callbacks remain on the
calling thread, in the existing item order. File metadata and operation results
are committed only after that member's worker finishes and its output is flushed.
Workers are stopped and joined on cancellation, callback errors and I/O errors.

The existing serial implementation remains in use for single-file archives,
small workloads (less than 32 MiB total or 1 MiB average member size), single-thread
requests, insufficient memory, encryption, split archives, symbolic links,
unsupported methods and detected header errors. ZIP integrity tests also use the
parallel path when eligible.

## Compression

The existing ZIP compressor already operates on multiple files concurrently, but
commits members in order. Later workers can run out of shared output buffers while
an earlier file is still compressing. The output pool now scales with average
input size for Deflate/Deflate64: up to 128 MiB per worker, subject to a 2 GiB total
cap and one eighth of the compression memory limit. Smaller workloads retain the
existing allocation. The algorithm, compression level, file order and ZIP output
remain unchanged.

## Measured results

2026-10-14, Ryzen 7 9700X (8 cores / 16 logical processors), NVMe SSD. The input
contains 102 MP4 and 3 MP3 files, 6,542,525,759 bytes (6.09 GiB). Baseline and modified
NanaZip were built from the same checkout (7.0 Preview 2609.3, 7-Zip core 26.04).
Bandizip bz.exe reports 7.47 Beta. Two rounds reversed the program order.

| Operation | Baseline NanaZip | Modified NanaZip | Bandizip |
| --- | ---: | ---: | ---: |
| ZIP compression, round 1 | 23.73 s | 18.77 s | 13.24 s |
| ZIP compression, round 2 | 25.41 s | 20.25 s | 14.32 s |
| Same ZIP extraction, round 1 | 12.78 s | 3.36 s | 5.63 s |
| Same ZIP extraction, round 2 | 12.54 s | 3.16 s | 5.18 s |

All six extraction runs matched the source files' SHA-256 hashes. Both modified
compression runs produced the same 6,380,811,881-byte ZIP and SHA-256 digest as
the baseline. Compression improved about 21%; extraction improved about 3.9x.
The compression gap to Bandizip remains.

Measurements include process startup and exclude validation/cleanup. OS caches
were not cleared, antivirus was not disabled, and all results use the local NVMe
drive. They do not establish performance on HDDs, network streams or arbitrary
file collections. The last memory-budget and stream-position fixes do not change
the selected parameters for this dataset; the final build was checked again.

## Validation

`Tests/ZipParallelTests.py` covers Store/Deflate mixtures, Unicode paths,
directories, empty files, extraction and integrity testing, thread limits,
bounded-buffer pressure, low-memory fallback, selected indices, overwrite skips,
duplicate members, damaged compressed data and serial-method fallback.

`Tests/ZipCallbackTests.cpp` directly calls the ZIP archive API with a small memory
budget. It checks callback order and thread identity, repeated extraction,
partial reads and writes, cancellation, read/write errors, zero-byte writes, and
failures in each extraction callback. Compile it in a Visual Studio x64 developer
terminal and supply absolute paths to the built Core DLL and a ZIP with at least
two ordinary members, at least 32 MiB total and at least 1 MiB average size:

```powershell
cl /EHsc /std:c++17 Tests\ZipCallbackTests.cpp /Fe:ZipCallbackTests.exe /link ole32.lib
python Tests\ZipParallelTests.py Output\Binaries\Release\x64\NanaZip.Universal.Console.exe
```

The maintained local build and modern-interface packaging entry point is
`Custom/Build.ps1`. See `Custom/README.md` for prerequisites, package provenance
and the distinction between compiling the runtime and reusing the existing GUI.
