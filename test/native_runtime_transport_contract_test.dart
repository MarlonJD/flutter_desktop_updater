import "dart:convert";
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
    final header = readRequiredFile(
      "windows/native/src/runtime/update_transport_winhttp.h",
    );
    final transportTest = readRequiredFile(
      "windows/native/test/runtime/transport_fixture_test.cpp",
    );
    final artifactTest = readRequiredFile(
      "windows/native/test/runtime/artifact_stager_test.cpp",
    );
    final fixtureServer = readRequiredFile(
      "tool/native_transport_fixture_server.dart",
    );
    final pathRuntime = [
      readRequiredFile("native_runtime/cpp/artifact_stager.cc"),
      readRequiredFile("native_runtime/cpp/stage_provenance.cc"),
    ].join("\n");

    expect(source, contains("WinHttpOpen"));
    expect(source, contains("WINHTTP_OPTION_DISABLE_FEATURE"));
    expect(source, contains("WINHTTP_DISABLE_REDIRECTS"));
    expect(source, contains("Content-Range"));
    expect(source, contains("maximum_metadata_bytes"));
    expect(source, contains("expected_sha256"));
    expect(source, contains(".part"));
    expect(source, contains("WinHttpCrackUrl"));
    expect(source, contains("WinHttpCreateUrl"));
    expect(source, contains("std::filesystem::u8path"));
    expect(source, isNot(contains("GetFileAttributesA")));
    expect(source, isNot(contains("DeleteFileA")));
    expect(source, isNot(contains("std::remove")));
    expect(source, isNot(contains("std::rename")));
    expect(pathRuntime, contains("GetFileAttributesW"));
    expect(pathRuntime, contains("CreateFileW"));
    expect(pathRuntime, contains("_wfopen"));
    expect(pathRuntime, contains("mz_zip_reader_extract_to_callback"));
    expect(pathRuntime, isNot(contains("GetFileAttributesA")));
    expect(pathRuntime, isNot(contains("DeleteFileA")));
    expect(pathRuntime, isNot(contains("_mkdir")));
    expect(pathRuntime, isNot(contains("mz_zip_reader_extract_to_file")));
    expect(
      header,
      contains(
        "std::string ResolveRedirectURL(const std::string& source,\n"
        "                               const std::string& location);",
      ),
    );
    expect(transportTest, contains("güncelleme-日本"));
    expect(transportTest, contains("/redirect/root"));
    expect(transportTest, contains("/redirect/parent/child"));
    expect(transportTest, contains("/redirect/scheme-relative"));
    expect(transportTest, contains("HTTPS redirect downgrade is forbidden"));
    expect(transportTest, contains("Update redirect limit exceeded"));
    expect(artifactTest, contains("güncelleme-日本"));
    expect(fixtureServer, contains('"/redirect/root"'));
    expect(fixtureServer, contains('"/redirect/parent/child"'));
    expect(fixtureServer, contains('"/redirect/scheme-relative"'));
    expect(fixtureServer, contains('"/redirect/downgrade"'));
    expect(fixtureServer, contains('"/redirect/loop"'));
    expect(fixtureServer, contains('"../metadata"'));
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

  test("native fixture server exposes relative redirect policies", () async {
    final process = await Process.start("dart", [
      "run",
      "tool/native_transport_fixture_server.dart",
      "--port",
      "0",
    ]);
    try {
      final ready = await process.stdout
          .transform(systemEncoding.decoder)
          .transform(const LineSplitter())
          .firstWhere((line) => line.startsWith("READY "))
          .timeout(const Duration(seconds: 10));
      final baseUrl = ready.replaceFirst("READY ", "");
      expect(await redirectLocation(baseUrl, "/redirect/root"), "/metadata");
      expect(
        await redirectLocation(baseUrl, "/redirect/parent/child"),
        "../metadata",
      );
      expect(
        await redirectLocation(baseUrl, "/redirect/scheme-relative"),
        startsWith("//127.0.0.1:"),
      );
      expect(
        await redirectLocation(baseUrl, "/redirect/downgrade"),
        startsWith("http://127.0.0.1:"),
      );
      expect(
        await redirectLocation(baseUrl, "/redirect/loop"),
        "/redirect/loop",
      );
    } finally {
      process.kill();
      await process.exitCode;
    }
  });
}

Future<String?> redirectLocation(String baseUrl, String path) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse("$baseUrl$path"));
    request.followRedirects = false;
    final response = await request.close();
    await response.drain<void>();
    expect(response.statusCode, HttpStatus.found);
    return response.headers.value(HttpHeaders.locationHeader);
  } finally {
    client.close(force: true);
  }
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
