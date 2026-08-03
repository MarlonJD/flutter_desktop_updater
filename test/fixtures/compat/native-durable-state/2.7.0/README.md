# Native durable-state compatibility fixtures

These files are exact serialized predecessor bytes. They are not examples and
must not be re-formatted, regenerated, or replaced by an abstract transition
model. SHA256SUMS covers every JSON byte under this directory.

## Provenance

- The macOS directory journal and verified-installer schema 2 bytes were
  emitted by baseline 2f91208f0de95b9656b0ce2a28258e70a2920b86.
- The macOS verified-installer schema 1 byte uses the exact predecessor Codable
  shape from writer commit 73aa730efbf1384eef9b74d7eb87ee655d81c0b5,
  before schema 2 landed in 96cc4ecbb009d5be5a50adcbeeedf8fae2dedfa4. CI
  checks it by copying a test-only emitter into an isolated checkout of that
  exact commit and comparing the historical writer's raw output; it does not
  reconstruct schema 1 from a current type. Current GitHub macOS Xcode imports
  one unrelated XPC reply pointer as non-null, so the isolated checkout applies
  `writers/macos/73aa730-swift-sdk-compat.patch` before compiling. That patch
  changes no journal model, canonicalizer, or writer code; the historical
  writer still has to emit the committed raw schema-1 bytes exactly.
- Windows and Linux bytes were first emitted on their respective GitHub-hosted
  target runners by baseline serializers at
  2f91208f0de95b9656b0ce2a28258e70a2920b86, using the test-emitter overlay
  commit fcd767ccfe9140f0787925f80cceb57553c1170a, from Actions run
  30794201039:
  https://github.com/MarlonJD/flutter_desktop_updater/actions/runs/30794201039.
  The committed hashes are verified artifact manifests, not host-created
  stand-ins.
- Every later native CI run creates an isolated detached worktree at the
  baseline serializer commit, applies only the frozen test-emitter overlay,
  builds that worktree's emitter, and compares every emitted byte to this tree.
  The uploaded provenance records the actual baseline `serializerCommit`, the
  fixed `overlayCommit`, and the current `readerCommit`; it never labels a
  current serializer as baseline output. macOS schema 1 is separately proven
  from its named predecessor worktree rather than from that baseline overlay.

## Reader proof

The macOS test-only writer and reader run as separate Swift test invocations.
The reader additionally starts a fresh XCTest process and verifies that it did
not mutate any frozen byte. The Windows and Linux target-host fixture emitters
run a separate `--verify` process against this fixture directory in CI; they
strict-decode and byte-reencode the frozen journals.

Windows and Linux crash tests also start a writer process that dies immediately
after the prepared journal is durably flushed, then start a separate reader
process that resolves the retained state. Neither parent process hands an
in-memory transaction to the reader. The Windows protected-locator test creates
only a per-test HKCU registry sandbox, has the production registrar apply its
protected ACL, writes the frozen endpoint bytes raw, and starts a fresh process
to load both the endpoint and transaction bindings. It compares the raw values
after the child exits, proving lookup did not rewrite them. Later v3 native
builds reuse these reader and fresh-process checks.

The Windows artifact upload manifest uses CRLF because PowerShell produced it.
Its hashes were verified after read-only CRLF normalization; the repository
manifest below uses ordinary LF and the same digest values.
