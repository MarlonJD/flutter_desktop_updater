import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("unused rewrite leftovers are not kept in the repository", () {
    expect(File("example.json").existsSync(), isFalse);
    expect(File("example/output.txt").existsSync(), isFalse);
    expect(File("bin/smoke_update.dart").existsSync(), isFalse);
    expect(Directory("lib/src/platform").existsSync(), isFalse);
    expect(File("lib/widget/update_widget.dart").existsSync(), isFalse);
  });
}
