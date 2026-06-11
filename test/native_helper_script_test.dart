import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("Linux helper uses bash when the generated script uses bash features",
      () {
    final source = File("linux/desktop_updater_plugin.cc").readAsStringSync();

    expect(source,
        contains('execl("/bin/bash", "bash", script_path.c_str(), nullptr);'));
    expect(source, contains("#!/bin/bash"));
    expect(source, contains("set -euo pipefail"));
    expect(source, contains("removed=("));
  });
}
