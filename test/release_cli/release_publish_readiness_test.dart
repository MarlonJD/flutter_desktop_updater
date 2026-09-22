import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "../e2e/release_publish_e2e_helpers.dart";

void main() {
  test("HTTP readiness retries connections closed before response headers",
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    server.listen((request) async {
      requests++;
      if (requests < 3) {
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.destroy();
        return;
      }
      request.response.write("ready");
      await request.response.close();
    });

    await waitForHttpServer(server.port);

    expect(requests, 3);
  });

  test("HTTP readiness waits for a successful response", () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.statusCode =
          requests == 1 ? HttpStatus.serviceUnavailable : HttpStatus.ok;
      await request.response.close();
    });

    await waitForHttpServer(server.port);

    expect(requests, 2);
  });
}
