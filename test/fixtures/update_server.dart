import "dart:io";

import "package:path/path.dart" as path;

class UpdateServer {
  UpdateServer._(this._server, this.root);

  final HttpServer _server;
  final Directory root;

  Uri get uri => Uri.parse("http://127.0.0.1:${_server.port}/");

  static Future<UpdateServer> bind(Directory root) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = UpdateServer._(server, root);
    fixture._serve();
    return fixture;
  }

  Future<void> close() {
    return _server.close(force: true);
  }

  void _serve() {
    _server.listen((request) async {
      final relative = request.uri.pathSegments.join("/");
      final file = File(path.join(root.path, relative));
      if (!await file.exists()) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      request.response.headers.contentLength = await file.length();
      await request.response.addStream(file.openRead());
      await request.response.close();
    });
  }
}
