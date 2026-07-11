# Third-Party Native Runtime Dependencies

Runtime-only dependencies are compiled into the preview non-Flutter runtime
targets. They are not linked by Flutter helper builds.

The complete vendored license texts below are reproduced in
`windows/native/THIRD_PARTY_NOTICES.md` and
`linux/native/THIRD_PARTY_NOTICES.md`. Those notice files ship in the NuGet
package and both installed native SDK trees.

## Monocypher 4.0.3

- Source: `https://monocypher.org/download/monocypher-4.0.3.tar.gz`
- SHA-512: `40904ada5c7ee4f7741733e38b69a30a4b0561cbffba5ffe7c2dce16136d540251ec0d9056ff606510d3b5b708fb8a40db7e0870d4a0b2dc17ba2bfb880f8965`
- License: CC0-1.0 or BSD-2-Clause; retained in
  `monocypher/LICENCE.md`
- Sources: core `monocypher.c` and optional `monocypher-ed25519.c`
- Build: C99, no optional allocation or platform integration layer
- Linking: statically compiled into Windows and Linux native runtime targets
- Purpose: Ed25519 descriptor signature verification only

The archive checksum was verified before extraction. Upstream source files are
unmodified. Runtime tests execute the repository's Dart-generated Ed25519
fixtures against the vendored implementation.

## miniz 3.1.2

- Source: `https://github.com/richgel999/miniz/releases/download/3.1.2/miniz-3.1.2.zip`
- SHA-256: `f0446d863f9c19926ad9483c523fdc42e42b8d4a6a431d27e09d49c79a140d9a`
- License: MIT; retained in `miniz/LICENSE`
- Sources: single-file `miniz.c` and `miniz.h`, unmodified
- Build: C99 with archive APIs enabled and zlib-compatible wrapper APIs
  disabled; Linux enables large-file offsets
- Linking: statically compiled into Windows and Linux native runtime targets
- Purpose: bounded ZIP central-directory inspection and extraction
