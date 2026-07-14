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

The separate native install-helper protocol fixtures live in
`../native-install-helper/v1/`. They freeze protocol v1 requests, strict invalid
cases, canonical JSON, journal transitions, reservations, results, diagnostics,
and redaction rules. Regenerate or check them with:

```sh
dart run tool/generate_native_install_helper_fixtures.dart
dart run tool/generate_native_install_helper_fixtures.dart --check
```

See `docs/native-install-helper-protocol.md` for the normative compatibility and
authority rules. Paths in those fixtures are untrusted hints and never mutation
authority.
