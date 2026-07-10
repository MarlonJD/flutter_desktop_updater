import "dart:async";
import "dart:convert";
import "dart:io";

const _artifact = "native transport artifact\n";

Future<void> main(List<String> arguments) async {
  var port = 43891;
  for (var index = 0; index < arguments.length; index += 1) {
    if (arguments[index] != "--port" || index + 1 >= arguments.length) {
      throw const FormatException("Usage: --port <port>");
    }
    port = int.parse(arguments[++index]);
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
        request.response.statusCode = HttpStatus.notFound;
    }
    await request.response.close();
  }
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
