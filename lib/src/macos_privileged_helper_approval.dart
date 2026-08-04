import "package:flutter/services.dart";

/// Stable native error code emitted when macOS requires helper approval.
const String macOSPrivilegedHelperApprovalRequiredErrorCode =
    "PrivilegedHelperApprovalRequired";

/// Whether [error] reports the macOS privileged helper approval gate.
bool isMacOSPrivilegedHelperApprovalRequiredError(Object error) {
  return error is PlatformException &&
      error.code == macOSPrivilegedHelperApprovalRequiredErrorCode;
}
