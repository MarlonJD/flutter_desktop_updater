# Third-Party Native Runtime Dependencies

Runtime-only dependencies are compiled into the preview non-Flutter runtime
targets. They are not linked by Flutter helper builds.

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
