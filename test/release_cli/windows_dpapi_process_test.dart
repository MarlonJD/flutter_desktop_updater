import "dart:async";
import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/release_cli/keys/release_key_store.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  const profileId = "0123456789abcdef0123456789abcdef";
  const keyId = "release-test";
  final seed = List<int>.generate(32, (index) => index);

  test("DPAPI fake process protects and unprotects a seed", () async {
    final root = await Directory.systemTemp.createTemp("dpapi_fake_");
    addTearDown(() => root.delete(recursive: true));
    final store = WindowsDpapiReleaseKeyStore(
      rootDirectory: root,
      isWindowsHost: () => true,
      startProcess: ({required operation, required environment}) async {
        return _FakeDpapiProcess.echoInput();
      },
    );

    await store.write(profileId: profileId, keyId: keyId, seed: seed);
    expect(await store.read(profileId: profileId, keyId: keyId), seed);
  });

  test("DPAPI compares existing seeds and preserves randomized ciphertext",
      () async {
    final root = await Directory.systemTemp.createTemp("dpapi_idempotent_");
    addTearDown(() => root.delete(recursive: true));
    final dpapi = _RandomizedDpapiState();
    final store = WindowsDpapiReleaseKeyStore(
      rootDirectory: root,
      isWindowsHost: () => true,
      startProcess: ({required operation, required environment}) async {
        return _RequestDpapiProcess(
          transformInput: (input) {
            final bytes = base64Decode(input);
            return switch (operation) {
              "protect" => dpapi.protect(bytes),
              "unprotect" => dpapi.unprotect(bytes),
              _ => throw StateError("unexpected fake operation"),
            };
          },
        );
      },
    );
    final storeFile = File("${root.path}/$profileId.json");

    await store.write(profileId: profileId, keyId: keyId, seed: seed);
    final originalBlob = await storeFile.readAsString();
    expect(dpapi.protectCalls, 1);

    await store.write(profileId: profileId, keyId: keyId, seed: seed);
    expect(await storeFile.readAsString(), originalBlob);
    expect(dpapi.protectCalls, 1);
    expect(dpapi.unprotectCalls, 1);

    final differentSeed = List<int>.of(seed)..[0] ^= 1;
    await expectLater(
      store.write(profileId: profileId, keyId: keyId, seed: differentSeed),
      throwsA(isA<StateError>()),
    );
    expect(await storeFile.readAsString(), originalBlob);
    expect(dpapi.protectCalls, 1);
    expect(dpapi.unprotectCalls, 2);

    dpapi.unprotectedSeedOverride = List<int>.filled(31, 0);
    await expectLater(
      store.write(profileId: profileId, keyId: keyId, seed: seed),
      throwsA(isA<StateError>()),
    );
    expect(await storeFile.readAsString(), originalBlob);
    expect(dpapi.protectCalls, 1);
    expect(dpapi.unprotectCalls, 3);

    dpapi
      ..unprotectedSeedOverride = null
      ..failUnprotect = true;
    await expectLater(
      store.write(profileId: profileId, keyId: keyId, seed: seed),
      throwsA(isA<StateError>()),
    );
    expect(await storeFile.readAsString(), originalBlob);
    expect(dpapi.protectCalls, 1);
    expect(dpapi.unprotectCalls, 4);
  });

  test("DPAPI rejects malformed, non-UTF8, and oversized stdout safely",
      () async {
    for (final output in <List<int>>[
      utf8.encode("not-base64"),
      [0xff, 0xfe, 0xfd],
      List<int>.filled(1024 * 1024 + 1, 65),
    ]) {
      final error = await _runWriteExpectingFailure(
        seed: seed,
        process: _FakeDpapiProcess(stdoutBytes: output),
      );
      expect(error.toString(), isNot(contains("not-base64")));
      expect(error.toString(), isNot(contains("DPAPI_SENTINEL")));
    }
  });

  test("DPAPI drains large stderr without exposing it", () async {
    final sentinel = utf8.encode("DPAPI_SENTINEL ");
    final stderr = List<int>.generate(
      sentinel.length * 100000,
      (index) => sentinel[index % sentinel.length],
    );
    final error = await _runWriteExpectingFailure(
      seed: seed,
      process: _FakeDpapiProcess(
        stderrBytes: stderr,
        exitCode: 1,
      ),
    );
    expect(error.toString(), isNot(contains("DPAPI_SENTINEL")));
    expect(error.toString(), isNot(contains("stderr")));
  });

  test("DPAPI hides exit, stdin, and process-start failures", () async {
    final exitError = await _runWriteExpectingFailure(
      seed: seed,
      process: _FakeDpapiProcess(
        stdoutBytes: base64Encode(seed).codeUnits,
        exitCode: 17,
        stderrBytes: utf8.encode("DPAPI_SENTINEL"),
      ),
    );
    expect(exitError.toString(), isNot(contains("DPAPI_SENTINEL")));
    expect(exitError.toString(), isNot(contains(base64Encode(seed))));

    final stdinError = await _runWriteExpectingFailure(
      seed: seed,
      process: _FakeDpapiProcess(writeError: StateError("STDIN_SENTINEL")),
    );
    expect(stdinError.toString(), isNot(contains("STDIN_SENTINEL")));

    final root = await Directory.systemTemp.createTemp("dpapi_start_");
    addTearDown(() => root.delete(recursive: true));
    final store = WindowsDpapiReleaseKeyStore(
      rootDirectory: root,
      isWindowsHost: () => true,
      startProcess: ({required operation, required environment}) {
        throw StateError("START_SENTINEL");
      },
    );
    await expectLater(
      store.write(profileId: profileId, keyId: keyId, seed: seed),
      throwsA(
        predicate<Object>(
          (error) =>
              !error.toString().contains("START_SENTINEL") &&
              !error.toString().contains(base64Encode(seed)),
        ),
      ),
    );
  });

  test("DPAPI kills and awaits a hanging process", () async {
    final root = await Directory.systemTemp.createTemp("dpapi_hang_");
    addTearDown(() => root.delete(recursive: true));
    late final _FakeDpapiProcess process;
    final store = WindowsDpapiReleaseKeyStore(
      rootDirectory: root,
      isWindowsHost: () => true,
      processTimeout: const Duration(milliseconds: 20),
      startProcess: ({required operation, required environment}) async {
        process = _FakeDpapiProcess.hanging();
        return process;
      },
    );

    await expectLater(
      store.write(profileId: profileId, keyId: keyId, seed: seed),
      throwsA(isA<StateError>()),
    );
    expect(process.killCount, 1);
  });

  test("DPAPI platform guard is injectable for fake tests", () async {
    final root = await Directory.systemTemp.createTemp("dpapi_guard_");
    addTearDown(() => root.delete(recursive: true));
    final store = WindowsDpapiReleaseKeyStore(
      rootDirectory: root,
      isWindowsHost: () => false,
      startProcess: ({required operation, required environment}) async {
        fail("the process must not start off Windows");
      },
    );
    await expectLater(
      store.write(profileId: profileId, keyId: keyId, seed: seed),
      throwsA(isA<UnsupportedError>()),
    );
  });
}

Future<Object> _runWriteExpectingFailure({
  required List<int> seed,
  required _FakeDpapiProcess process,
}) async {
  final root = await Directory.systemTemp.createTemp("dpapi_failure_");
  addTearDown(() => root.delete(recursive: true));
  final store = WindowsDpapiReleaseKeyStore(
    rootDirectory: root,
    isWindowsHost: () => true,
    startProcess: ({required operation, required environment}) async => process,
  );
  try {
    await store.write(
      profileId: "0123456789abcdef0123456789abcdef",
      keyId: "release-test",
      seed: seed,
    );
    fail("expected DPAPI failure");
  } on Object catch (error) {
    return error;
  }
}

final class _FakeDpapiProcess implements WindowsDpapiProcess {
  _FakeDpapiProcess({
    List<int>? stdoutBytes,
    List<int>? stderrBytes,
    int? exitCode = 0,
    this.writeError,
  })  : _stdoutBytes = stdoutBytes ?? base64Encode(<int>[1, 2, 3]).codeUnits,
        _stderrBytes = stderrBytes ?? const [],
        _configuredExitCode = exitCode;

  _FakeDpapiProcess.echoInput()
      : _stdoutBytes = null,
        _stderrBytes = const [],
        _configuredExitCode = 0,
        writeError = null;

  _FakeDpapiProcess.hanging()
      : _stdoutBytes = null,
        _stderrBytes = const [],
        _configuredExitCode = null,
        writeError = null;

  final List<int>? _stdoutBytes;
  final List<int> _stderrBytes;
  final int? _configuredExitCode;
  final Object? writeError;
  String? _input;
  int killCount = 0;
  final _exit = Completer<int>();
  final _stdoutController = StreamController<List<int>>();
  final _stderrController = StreamController<List<int>>();
  bool _started = false;

  @override
  Stream<List<int>> get stdout {
    if (!_started) {
      _started = true;
      if (_stdoutBytes != null) {
        _stdoutController.add(_stdoutBytes);
        _stdoutController.close();
      }
      if (_stderrBytes.isNotEmpty) {
        _stderrController.add(_stderrBytes);
      }
      _stderrController.close();
      if (_configuredExitCode != null) _exit.complete(_configuredExitCode);
    }
    return _stdoutController.stream;
  }

  @override
  Stream<List<int>> get stderr => _stderrController.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Future<void> writeStdin(String value) async {
    final error = writeError;
    if (error is Exception) throw error;
    if (error is Error) throw error;
    if (error != null) throw StateError("fake stdin failure");
    _input = value;
  }

  @override
  Future<void> closeStdin() async {
    if (_stdoutBytes == null && _configuredExitCode == 0) {
      final bytes = base64Decode(_input!);
      _stdoutController.add(base64Encode(bytes).codeUnits);
      await _stdoutController.close();
      if (!_exit.isCompleted) _exit.complete(0);
    }
  }

  @override
  Future<void> killAndWait() async {
    killCount += 1;
    await _stdoutController.close();
    await _stderrController.close();
    if (!_exit.isCompleted) _exit.complete(1);
  }
}

final class _RandomizedDpapiState {
  int protectCalls = 0;
  int unprotectCalls = 0;
  int _nextNonce = 0;
  bool failUnprotect = false;
  List<int>? unprotectedSeedOverride;
  final Map<String, List<int>> _protectedSeeds = <String, List<int>>{};

  List<int> protect(List<int> seed) {
    protectCalls += 1;
    final protected = <int>[_nextNonce++ & 0xff, ...seed];
    _protectedSeeds[base64Encode(protected)] = List<int>.of(seed);
    return protected;
  }

  List<int> unprotect(List<int> protected) {
    unprotectCalls += 1;
    if (failUnprotect) throw StateError("fake authentication failure");
    final seed = _protectedSeeds[base64Encode(protected)];
    if (seed == null) throw StateError("fake authentication failure");
    return unprotectedSeedOverride ?? seed;
  }
}

final class _RequestDpapiProcess implements WindowsDpapiProcess {
  _RequestDpapiProcess({required this.transformInput});

  final List<int> Function(String input) transformInput;
  final _stdout = StreamController<List<int>>();
  final _exit = Completer<int>();
  late String _input;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Future<void> writeStdin(String value) async {
    _input = value;
  }

  @override
  Future<void> closeStdin() async {
    try {
      _stdout.add(base64Encode(transformInput(_input)).codeUnits);
      await _stdout.close();
      _exit.complete(0);
    } on Object {
      await _stdout.close();
      _exit.complete(1);
    }
  }

  @override
  Future<void> killAndWait() async {
    if (!_stdout.isClosed) await _stdout.close();
    if (!_exit.isCompleted) _exit.complete(1);
  }
}
