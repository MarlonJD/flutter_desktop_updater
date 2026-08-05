import "dart:convert";
import "dart:math";

import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/src/json/strict_json.dart";

const _bundleFormat = "desktop-updater-release-key-bundle";
const _bundleVersion = 1;
const _argonMemory = 65536;
const _argonIterations = 3;
const _argonParallelism = 1;
const _argonHashLength = 32;
const _saltLength = 16;
const _nonceLength = 24;
const _macLength = 16;
const _maxBundleBytes = 1024 * 1024;

/// Encrypts and decrypts portable release-key bundles.
final class ReleaseKeyBundleCodec {
  const ReleaseKeyBundleCodec({Random? random}) : _random = random;

  final Random? _random;

  Future<String> encrypt({
    required Map<String, Object?> payload,
    required String passphrase,
  }) async {
    _checkPassphrase(passphrase);
    final random = _random ?? Random.secure();
    final salt = _randomBytes(random, _saltLength);
    final nonce = _randomBytes(random, _nonceLength);
    final kdf = Argon2id(
      parallelism: _argonParallelism,
      memory: _argonMemory,
      iterations: _argonIterations,
      hashLength: _argonHashLength,
    );
    final passwordKey = SecretKey(utf8.encode(passphrase));
    final derivedKey = await kdf.deriveKey(
      secretKey: passwordKey,
      nonce: salt,
    );
    final cipher = Xchacha20.poly1305Aead();
    final header = _header(salt: salt, nonce: nonce);
    final clearText = utf8.encode(_canonicalJson(payload));
    try {
      final secretBox = await cipher.encrypt(
        clearText,
        secretKey: derivedKey,
        nonce: nonce,
        aad: utf8.encode(_canonicalJson(header)),
      );
      return _encodeEnvelope(
        salt: salt,
        nonce: nonce,
        cipherText: secretBox.cipherText,
        mac: secretBox.mac.bytes,
      );
    } finally {
      clearText.fillRange(0, clearText.length, 0);
      passwordKey.destroy();
      derivedKey.destroy();
    }
  }

  Future<Map<String, Object?>> decrypt({
    required String envelope,
    required String passphrase,
  }) async {
    _checkPassphrase(passphrase);
    if (utf8.encode(envelope).length > _maxBundleBytes) {
      throw const FormatException("Unable to authenticate release key bundle.");
    }
    try {
      final decoded = parseStrictJson(envelope);
      if (decoded is! Map<String, Object?>) throw const FormatException();
      final envelopeMap = _readEnvelope(decoded);
      final kdfMap = envelopeMap["kdf"]! as Map<String, Object?>;
      final cipherMap = envelopeMap["cipher"]! as Map<String, Object?>;
      final salt = _strictBase64Bytes(kdfMap["salt"], _saltLength);
      final nonce = _strictBase64Bytes(cipherMap["nonce"], _nonceLength);
      final cipherText = _strictBase64Bytes(cipherMap["ciphertext"], null);
      final mac = _strictBase64Bytes(cipherMap["mac"], _macLength);
      if (cipherText.length > _maxBundleBytes) throw const FormatException();

      final kdf = Argon2id(
        parallelism: _argonParallelism,
        memory: _argonMemory,
        iterations: _argonIterations,
        hashLength: _argonHashLength,
      );
      final passwordKey = SecretKey(utf8.encode(passphrase));
      final derivedKey = await kdf.deriveKey(
        secretKey: passwordKey,
        nonce: salt,
      );
      final secretBox = SecretBox(
        cipherText,
        nonce: nonce,
        mac: Mac(mac),
      );
      try {
        final clearText = await Xchacha20.poly1305Aead().decrypt(
          secretBox,
          secretKey: derivedKey,
          aad: utf8.encode(
            _canonicalJson(_header(salt: salt, nonce: nonce)),
          ),
        );
        try {
          final payload = parseStrictJson(utf8.decode(clearText));
          if (payload is! Map<String, Object?>) throw const FormatException();
          return payload;
        } finally {
          clearText.fillRange(0, clearText.length, 0);
        }
      } finally {
        passwordKey.destroy();
        derivedKey.destroy();
      }
    } on Object {
      // Do not distinguish wrong passphrases from altered headers/ciphertext.
      throw const FormatException("Unable to authenticate release key bundle.");
    }
  }

  String _encodeEnvelope({
    required List<int> salt,
    required List<int> nonce,
    required List<int> cipherText,
    required List<int> mac,
  }) {
    final envelope = <String, Object?>{
      "format": _bundleFormat,
      "version": _bundleVersion,
      "kdf": <String, Object?>{
        "name": "argon2id",
        "version": 19,
        "memoryKiB": _argonMemory,
        "iterations": _argonIterations,
        "parallelism": _argonParallelism,
        "salt": base64Encode(salt),
        "keyLength": _argonHashLength,
      },
      "cipher": <String, Object?>{
        "name": "xchacha20-poly1305",
        "nonce": base64Encode(nonce),
        "ciphertext": base64Encode(cipherText),
        "mac": base64Encode(mac),
      },
    };
    final encoded = "${const JsonEncoder.withIndent("  ").convert(envelope)}\n";
    if (utf8.encode(encoded).length > _maxBundleBytes) {
      throw const FormatException("Release key bundle is larger than 1 MiB.");
    }
    return encoded;
  }
}

Map<String, Object?> _readEnvelope(Map<String, Object?> value) {
  _expectKeys(value, const {"format", "version", "kdf", "cipher"});
  if (value["format"] != _bundleFormat || value["version"] != _bundleVersion) {
    throw const FormatException();
  }
  final kdf = value["kdf"];
  final cipher = value["cipher"];
  if (kdf is! Map<String, Object?> || cipher is! Map<String, Object?>) {
    throw const FormatException();
  }
  _expectKeys(
    kdf,
    const {
      "name",
      "version",
      "memoryKiB",
      "iterations",
      "parallelism",
      "salt",
      "keyLength",
    },
  );
  _expectKeys(cipher, const {"name", "nonce", "ciphertext", "mac"});
  if (kdf["name"] != "argon2id" ||
      kdf["version"] != 19 ||
      kdf["memoryKiB"] != _argonMemory ||
      kdf["iterations"] != _argonIterations ||
      kdf["parallelism"] != _argonParallelism ||
      kdf["keyLength"] != _argonHashLength ||
      cipher["name"] != "xchacha20-poly1305") {
    throw const FormatException();
  }
  return value;
}

Map<String, Object?> _header({
  required List<int> salt,
  required List<int> nonce,
}) {
  return <String, Object?>{
    "format": _bundleFormat,
    "version": _bundleVersion,
    "kdf": <String, Object?>{
      "name": "argon2id",
      "version": 19,
      "memoryKiB": _argonMemory,
      "iterations": _argonIterations,
      "parallelism": _argonParallelism,
      "salt": base64Encode(salt),
      "keyLength": _argonHashLength,
    },
    "cipher": <String, Object?>{
      "name": "xchacha20-poly1305",
      "nonce": base64Encode(nonce),
    },
  };
}

List<int> _strictBase64Bytes(Object? value, int? exactLength) {
  if (value is! String ||
      !RegExp(r"^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$")
          .hasMatch(value)) {
    throw const FormatException();
  }
  final bytes = base64Decode(value);
  if (exactLength != null && bytes.length != exactLength) {
    throw const FormatException();
  }
  return bytes;
}

void _expectKeys(Map<String, Object?> value, Set<String> allowed) {
  if (value.length != allowed.length ||
      value.keys.any((key) => !allowed.contains(key))) {
    throw const FormatException();
  }
}

String _canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return "{${keys.map((key) => '${jsonEncode(key)}:${_canonicalJson(value[key])}').join(',')}}";
  }
  if (value is List) {
    return "[${value.map(_canonicalJson).join(',')}]";
  }
  return jsonEncode(value);
}

List<int> _randomBytes(Random random, int length) {
  return List<int>.generate(length, (_) => random.nextInt(256));
}

void _checkPassphrase(String passphrase) {
  if (passphrase.runes.length < 12) {
    throw const FormatException(
      "Release key bundle passphrases must contain at least 12 characters.",
    );
  }
}
