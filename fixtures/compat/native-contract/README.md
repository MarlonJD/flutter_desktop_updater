# Native Contract Fixtures

These files are generated from the Dart 2.7 contract implementation. Swift and
C++ native SDK tests consume them as cross-language compatibility inputs.

Regenerate after an intentional contract change:

```sh
dart run tool/generate_native_contract_fixtures.dart
```

Check committed bytes without rewriting them:

```sh
dart run tool/generate_native_contract_fixtures.dart --check
```

All timestamps, Ed25519 seeds, URLs, artifact payloads, hashes, and selection
identities are deterministic test data. URLs use `updates.example.test` and do
not identify a production service.
