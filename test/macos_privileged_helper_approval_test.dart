import "package:desktop_updater/desktop_updater.dart";
import "dart:io";

import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("recognizes the stable privileged helper approval error", () {
    expect(
      macOSPrivilegedHelperApprovalRequiredErrorCode,
      "PrivilegedHelperApprovalRequired",
    );
    expect(
      isMacOSPrivilegedHelperApprovalRequiredError(
        PlatformException(
          code: "PrivilegedHelperApprovalRequired",
          message: "Administrator approval is required.",
        ),
      ),
      isTrue,
    );
    expect(
      isMacOSPrivilegedHelperApprovalRequiredError(
        StateError("endpoint unavailable"),
      ),
      isFalse,
    );
  });

  test("documents custom and ready UI approval recovery", () {
    final diagnostics = File(
      "docs/diagnostics-and-recovery.md",
    ).readAsStringSync();
    final readyUi = File("docs/ui-widgets.md").readAsStringSync();

    expect(
      diagnostics,
      contains("PrivilegedHelperApprovalRequired"),
    );
    expect(
      diagnostics,
      contains("isMacOSPrivilegedHelperApprovalRequiredError"),
    );
    expect(
      diagnostics,
      contains("openMacOSBackgroundItemsSettings"),
    );
    expect(readyUi, contains("Open settings"));
    expect(readyUi, contains("Try again"));
    expect(readyUi, contains("unprivileged"));
  });
}
