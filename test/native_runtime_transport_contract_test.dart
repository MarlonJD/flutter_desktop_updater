import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("Swift transport enforces bounded redirect and download policy", () {
    final source = readRequiredFile(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/Runtime/"
      "UpdateTransport.swift",
    );
    final tests = readRequiredFile(
      "macos/desktop_updater/Tests/DesktopUpdaterKitTests/"
      "UpdateTransportTests.swift",
    );

    expect(source, contains("maximumRedirects = 5"));
    expect(source, contains("HTTPS redirect downgrade"));
    expect(source, contains("requestHeadersProvider"));
    expect(source, contains("maximumMetadataBytes"));
    expect(source, contains("expectedLength"));
    expect(source, contains("expectedSHA256"));
    expect(source, contains(".part"));
    expect(tests, contains("URLProtocol"));
    expect(tests, contains("Content-Range"));
    expect(tests, contains("Authorization"));
  });

  test("Windows WinHTTP transport keeps runtime-only policy explicit", () {
    final source = readDirectory("windows/native/src/runtime");
    final cmake = readRequiredFile("windows/native/CMakeLists.txt");

    expect(source, contains("WinHttpOpen"));
    expect(source, contains("WINHTTP_OPTION_DISABLE_FEATURE"));
    expect(source, contains("WINHTTP_DISABLE_REDIRECTS"));
    expect(source, contains("Content-Range"));
    expect(source, contains("maximum_metadata_bytes"));
    expect(source, contains("expected_sha256"));
    expect(source, contains(".part"));
    expect(cmake, contains("Winhttp"));
    expect(cmake, contains("update_transport_winhttp.cpp"));
  });

  test("Linux libcurl transport keeps TLS and limits fail closed", () {
    final source = readDirectory("linux/native/src/runtime");
    final cmake = readRequiredFile("linux/native/CMakeLists.txt");

    expect(source, contains("curl_easy_init"));
    expect(source, contains("CURLOPT_FOLLOWLOCATION"));
    expect(source, contains("CURLOPT_SSL_VERIFYPEER"));
    expect(source, contains("CURLOPT_SSL_VERIFYHOST"));
    expect(source, contains("Content-Range"));
    expect(source, contains("maximum_metadata_bytes"));
    expect(source, contains("expected_sha256"));
    expect(source, contains(".part"));
    expect(cmake, contains("find_package(CURL REQUIRED)"));
    expect(cmake, contains("update_transport_curl.cc"));
  });
}

String readRequiredFile(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: "$path must exist");
  return file.existsSync() ? file.readAsStringSync() : "";
}

String readDirectory(String path) {
  final directory = Directory(path);
  expect(directory.existsSync(), isTrue, reason: "$path must exist");
  if (!directory.existsSync()) return "";
  return directory
      .listSync(recursive: true)
      .whereType<File>()
      .map((file) => file.readAsStringSync())
      .join("\n");
}
