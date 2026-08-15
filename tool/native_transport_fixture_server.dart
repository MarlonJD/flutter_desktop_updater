import "dart:async";
import "dart:convert";
import "dart:io";

import "package:path/path.dart" as path;

const _artifact = "native transport artifact\n";

Future<void> main(List<String> arguments) async {
  var port = 43891;
  Directory? staticRoot;
  for (var index = 0; index < arguments.length; index += 1) {
    if (index + 1 >= arguments.length) {
      throw const FormatException(
        "Usage: --port <port> [--root <directory>]",
      );
    }
    switch (arguments[index]) {
      case "--port":
        port = int.parse(arguments[++index]);
      case "--root":
        staticRoot = Directory(arguments[++index]).absolute;
      default:
        throw const FormatException(
          "Usage: --port <port> [--root <directory>]",
        );
    }
  }
  if (staticRoot != null && !await staticRoot.exists()) {
    throw FileSystemException(
      "Static fixture root does not exist.",
      staticRoot.path,
    );
  }

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  var retryCount = 0;
  var missingLocationCount = 0;
  stdout.writeln("READY http://${server.address.address}:${server.port}");
  await stdout.flush();

  await for (final request in server) {
    switch (request.uri.path) {
      case "/health":
        request.response.write("ok");
      case "/metadata":
        if (request.headers.value(HttpHeaders.authorizationHeader) !=
            "Bearer fixture") {
          request.response.statusCode = HttpStatus.unauthorized;
        } else {
          request.response.write("metadata");
        }
      case "/redirect":
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          "http://${server.address.address}:${server.port}/metadata",
        );
      case "/redirect/root":
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, "/metadata");
      case "/redirect/parent/child":
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          "../metadata",
        );
      case "/redirect/metadata":
        if (request.headers.value(HttpHeaders.authorizationHeader) !=
            "Bearer fixture") {
          request.response.statusCode = HttpStatus.unauthorized;
        } else {
          request.response.write("metadata");
        }
      case "/redirect/scheme-relative":
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          "//${server.address.address}:${server.port}/metadata",
        );
      case "/redirect/downgrade":
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          "http://${server.address.address}:${server.port}/metadata",
        );
      case "/redirect/loop":
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          "/redirect/loop",
        );
      case "/redirect/empty":
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, "");
      case "/redirect/missing-location":
        missingLocationCount += 1;
        if (missingLocationCount == 1) {
          request.response.statusCode = HttpStatus.found;
        } else {
          writeMetadata(request);
        }
      case "/redirect/query":
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, "?new=2");
      case "/redirect/fragment":
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, "#next");
      case "/redirect/query-fragment":
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          "?new=2#next",
        );
      case "/redirect/five/0":
        redirect(request, "/redirect/five/1");
      case "/redirect/five/1":
        redirect(request, "/redirect/five/2");
      case "/redirect/five/2":
        redirect(request, "/redirect/five/3");
      case "/redirect/five/3":
        redirect(request, "/redirect/five/4");
      case "/redirect/five/4":
        redirect(request, "/redirect/five/5");
      case "/redirect/five/5":
        writeMetadata(request);
      case "/redirect/six/0":
        redirect(request, "/redirect/six/1");
      case "/redirect/six/1":
        redirect(request, "/redirect/six/2");
      case "/redirect/six/2":
        redirect(request, "/redirect/six/3");
      case "/redirect/six/3":
        redirect(request, "/redirect/six/4");
      case "/redirect/six/4":
        redirect(request, "/redirect/six/5");
      case "/redirect/six/5":
        redirect(request, "/redirect/six/6");
      case "/redirect/six/6":
        writeMetadata(request);
      case "/redirect/cross-authority":
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          "http://localhost:${server.port}/metadata",
        );
      case "/retry":
        retryCount += 1;
        if (retryCount < 3) {
          request.response.statusCode = HttpStatus.serviceUnavailable;
        } else {
          request.response.write("metadata");
        }
      case "/oversize":
        request.response.write("x" * 64);
      case "/artifact":
        final bytes = utf8.encode(_artifact);
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (range != null && range.startsWith("bytes=")) {
          final start = int.parse(
            range.substring("bytes=".length).split("-").first,
          );
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            "bytes $start-${bytes.length - 1}/${bytes.length}",
          );
          request.response.add(bytes.sublist(start));
        } else {
          request.response.add(bytes);
        }
      default:
        if (staticRoot == null) {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          await _serveStaticFile(request, staticRoot);
        }
    }
    await request.response.close();
  }
}

Future<void> _serveStaticFile(HttpRequest request, Directory root) async {
  final segments = request.uri.pathSegments;
  if (segments.isEmpty ||
      segments.any(
        (segment) =>
            segment.isEmpty ||
            segment == "." ||
            segment == ".." ||
            segment.contains("/") ||
            segment.contains("\\"),
      )) {
    request.response.statusCode = HttpStatus.badRequest;
    return;
  }

  final rootPath = path.normalize(path.absolute(root.path));
  final candidatePath = path.normalize(
    path.absolute(path.joinAll(<String>[rootPath, ...segments])),
  );
  if (!path.isWithin(rootPath, candidatePath)) {
    request.response.statusCode = HttpStatus.badRequest;
    return;
  }
  final type = await FileSystemEntity.type(candidatePath, followLinks: false);
  if (type != FileSystemEntityType.file) {
    request.response.statusCode = HttpStatus.notFound;
    return;
  }

  final file = File(candidatePath);
  request.response.headers.contentLength = await file.length();
  await request.response.addStream(file.openRead());
}

void redirect(HttpRequest request, String location) {
  request.response.statusCode = HttpStatus.found;
  request.response.headers.set(HttpHeaders.locationHeader, location);
}

void writeMetadata(HttpRequest request) {
  if (request.headers.value(HttpHeaders.authorizationHeader) !=
      "Bearer fixture") {
    request.response.statusCode = HttpStatus.unauthorized;
  } else {
    request.response.write("metadata");
  }
}
