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
    final redirectHeader = readRequiredFile(
      "native_runtime/cpp/redirect_url.h",
    );
    final redirectTests = readRequiredFile(
      "native_runtime/cpp/redirect_url_tests.cc",
    );
    final provenanceHeader = readRequiredFile(
      "native_runtime/cpp/stage_provenance.h",
    );
    final transportHeader = readRequiredFile(
      "native_runtime/cpp/update_transport.h",
    );
    final lifecycleHeader = readRequiredFile(
      "native_runtime/cpp/client_lifecycle.h",
    );
    final runtimeC = readRequiredFile(
      "windows/native/src/runtime/desktop_updater_runtime_c.cpp",
    );

    expect(source, contains("WinHttpOpen"));
    expect(source, contains("WINHTTP_OPTION_DISABLE_FEATURE"));
    expect(source, contains("WINHTTP_DISABLE_REDIRECTS"));
    expect(source, contains("Content-Range"));
    expect(source, contains("maximum_metadata_bytes"));
    expect(source, contains("expected_sha256"));
    expect(source, contains(".part"));
    expect(source, contains("WinHttpCrackUrl"));
    expect(source, contains("HTTPRequestTarget"));
    expect(source, contains("std::filesystem::u8path"));
    expect(source, contains("std::optional<std::wstring> QueryHeader"));
    expect(
      source,
      contains("Redirect response is missing a Location header."),
    );
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
    expect(header, contains('#include "redirect_url.h"'));
    expect(redirectHeader, contains("ResolveRedirectURL"));
    expect(redirectHeader, contains("HTTPRequestTarget"));
    expect(redirectTests, contains('ResolveRedirectURL(base, "")'));
    expect(redirectTests, contains('ResolveRedirectURL(base, "#next")'));
    expect(redirectTests, contains("/a//metadata"));
    expect(redirectTests, contains("[2001:db8::1]"));
    expect(redirectTests, contains("user@example.com"));
    expect(provenanceHeader, contains("struct FilesystemOwnedStage"));
    expect(provenanceHeader, contains("CanonicalStageDirectory"));
    expect(
      provenanceHeader,
      contains("const std::filesystem::path& parent_path"),
    );
    expect(transportTest, contains("güncelleme-日本"));
    expect(transportTest, contains("/redirect/root"));
    expect(transportTest, contains("/redirect/parent/child"));
    expect(transportTest, contains("/redirect/scheme-relative"));
    expect(transportTest, contains("HTTPS redirect downgrade is forbidden"));
    expect(transportTest, contains("Update redirect limit exceeded"));
    expect(transportTest, contains("/redirect/five/0"));
    expect(transportTest, contains("/redirect/six/0"));
    expect(transportTest, contains("/redirect/cross-authority"));
    expect(transportTest, contains("/redirect/missing-location"));
    expect(transportTest, contains("/redirect/empty"));
    expect(
      transportTest,
      contains("Redirect response is missing a Location header."),
    );
    expect(
      transportHeader,
      contains("std::filesystem::path destination_filesystem_path"),
    );
    expect(lifecycleHeader, contains("staged_filesystem_path"));
    expect(
      runtimeC,
      contains("download.destination_filesystem_path = artifact_path"),
    );
    expect(runtimeC, isNot(contains("artifact_path.u8string()")));
    expect(runtimeC, contains("snapshot.staged_filesystem_path"));
    expect(runtimeC, contains("install_handoff.staged_filesystem_path"));
    expect(
      runtimeC,
      isNot(contains("Utf8ToWide(install_handoff.staged_path)")),
    );
    expect(artifactTest, contains("güncelleme-日本"));
    expect(fixtureServer, contains('"/redirect/root"'));
    expect(fixtureServer, contains('"/redirect/parent/child"'));
    expect(fixtureServer, contains('"/redirect/scheme-relative"'));
    expect(fixtureServer, contains('"/redirect/downgrade"'));
    expect(fixtureServer, contains('"/redirect/loop"'));
    expect(fixtureServer, contains('"../metadata"'));
    expect(fixtureServer, contains('"/redirect/five/0"'));
    expect(fixtureServer, contains('"/redirect/six/0"'));
    expect(fixtureServer, contains('"/redirect/cross-authority"'));
    expect(fixtureServer, contains('"/redirect/missing-location"'));
    expect(cmake.toLowerCase(), contains("winhttp"));
    expect(cmake, contains("update_transport_winhttp.cpp"));
    expect(cmake, contains("redirect_url.cc"));
    expect(cmake, contains("desktop_updater_runtime_redirect_url_test"));
    expect(cmake, contains("desktop_updater_runtime_stage_path_test"));
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
      expect(await redirectLocation(baseUrl, "/redirect/empty"), "");
      expect(await redirectLocation(baseUrl, "/redirect/query"), "?new=2");
      expect(
        await redirectLocation(baseUrl, "/redirect/fragment"),
        "#next",
      );
      expect(
        await redirectLocation(baseUrl, "/redirect/query-fragment"),
        "?new=2#next",
      );
      expect(
        await redirectLocation(baseUrl, "/redirect/five/0"),
        "/redirect/five/1",
      );
      expect(
        await redirectLocation(baseUrl, "/redirect/six/0"),
        "/redirect/six/1",
      );
      expect(
        await redirectLocation(baseUrl, "/redirect/cross-authority"),
        startsWith("http://localhost:"),
      );
      expect(
        await redirectLocation(baseUrl, "/redirect/missing-location"),
        isNull,
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
