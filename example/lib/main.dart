import "dart:async";

import "package:desktop_updater/desktop_updater.dart";
import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String _platformVersion = "Unknown";
  final _desktopUpdaterPlugin = DesktopUpdater();

  @override
  void initState() {
    super.initState();
    initPlatformState();
  }

  // Platform messages are asynchronous, so we initialize in an async method.
  Future<void> initPlatformState() async {
    String platformVersion;
    // Platform messages may fail, so we use a try/catch PlatformException.
    // We also handle the message potentially returning null.
    try {
      platformVersion = await _desktopUpdaterPlugin.getPlatformVersion() ??
          "Unknown platform version";
    } on PlatformException {
      platformVersion = "Failed to get platform version.";
    }

    // If the widget was removed from the tree while the asynchronous platform
    // message was in flight, we want to discard the reply rather than calling
    // setState to update our non-existent appearance.
    if (!mounted) return;

    setState(() {
      _platformVersion = platformVersion;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text("Plugin example app"),
        ),
        body: Center(
          child: Column(
            children: [
              Text("Running on: $_platformVersion\n"),
              ElevatedButton(
                onPressed: _desktopUpdaterPlugin.restartApp,
                child: const Text("Restart App"),
              ),
              ElevatedButton(
                onPressed: () {
                  _desktopUpdaterPlugin.sayHello().then(print);
                },
                child: const Text("Say Hello"),
              ),
              ElevatedButton(
                onPressed: () async {
                  // timer
                  final time = DateTime.now().millisecondsSinceEpoch;
                  await compute(_generateFileHashes, RootIsolateToken.instance)
                      .then((value) {
                    print(
                      "Time: ${DateTime.now().millisecondsSinceEpoch - time}ms",
                    );
                  });
                },
                child: const Text("Generate hashes"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Add this top-level function outside of any class
Future<void> _generateFileHashes(dynamic token) async {
  BackgroundIsolateBinaryMessenger.ensureInitialized(token);
  await DesktopUpdater().generateFileHashes();
  return;
}