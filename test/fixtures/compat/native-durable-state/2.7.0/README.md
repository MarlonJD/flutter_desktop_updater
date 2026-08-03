# Native durable-state compatibility fixtures

These files are exact serialized predecessor bytes. They are not examples and
must not be re-formatted, regenerated, or replaced by an abstract transition
model. SHA256SUMS covers every JSON byte under this directory.

## Provenance

- The macOS directory journal and verified-installer schema 2 bytes were
  emitted by baseline 2f91208f0de95b9656b0ce2a28258e70a2920b86.
- The macOS verified-installer schema 1 byte uses the exact predecessor Codable
  shape from writer commit 73aa730efbf1384eef9b74d7eb87ee655d81c0b5,
  before schema 2 landed in 96cc4ecbb009d5be5a50adcbeeedf8fae2dedfa4.
- Windows and Linux bytes were emitted on their respective GitHub-hosted target
  runners by baseline serializers at
  2f91208f0de95b9656b0ce2a28258e70a2920b86, using test-emitter commit
  fcd767ccfe9140f0787925f80cceb57553c1170a, from Actions run 30794201039:
  https://github.com/MarlonJD/flutter_desktop_updater/actions/runs/30794201039.
  The committed hashes are the verified artifact manifests, not host-created
  stand-ins.

## Reader proof

The macOS test-only writer and reader run as separate Swift test invocations.
The Windows and Linux target-host fixture emitters run a separate --verify
process against this fixture directory in CI; they strict-decode and
byte-reencode the frozen journals. Later v3 native builds reuse those same
reader checks, so a reader cannot silently rewrite predecessor state before
proving it decodes.

The Windows artifact upload manifest uses CRLF because PowerShell produced it.
Its hashes were verified after read-only CRLF normalization; the repository
manifest below uses ordinary LF and the same digest values.
