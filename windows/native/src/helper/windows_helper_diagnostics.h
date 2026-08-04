#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_HELPER_DIAGNOSTICS_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_HELPER_DIAGNOSTICS_H_

#include <windows.h>

#include <cstddef>

namespace desktop_updater::helper {

enum class WindowsHelperEvent : std::size_t {
  kHelperScheduled,
  kWaitingForParentProcess,
  kParentProcessExited,
  kStagingPathValidation,
  kBackupStart,
  kBackupSuccess,
  kBackupFailure,
  kMoveStart,
  kMoveSuccess,
  kMoveFailure,
  kRollbackStart,
  kRollbackSuccess,
  kRollbackFailure,
  kCleanupStart,
  kCleanupSuccess,
  kCleanupFailure,
  kRelaunchAttempt,
  kPortableBootstrapFailure,
  kPortableRecoveryHostFailure,
  kPortableSessionFailure,
  kPortableRecoveryAuthorityFailure,
  kPortableRecoverySourceFailure,
  kPortableRecoveryStorageFailure,
  kPortableRecoveryArtifactFailure,
  kPortableAuthorizationFailure,
  kPortablePreparationFailure,
  kPortableRequestValidationFailure,
  kPortableCallerIdentityFailure,
  kPortableTargetAuthorityFailure,
  kPortableStageAuthorizationFailure,
  kPortableTargetRequestFailure,
  kPortableTargetExecutableIdentityFailure,
  kPortableTargetCallerRootFailure,
  kPortableTargetReadAuthorityFailure,
  kPortableParentMutationAuthorityFailure,
  kPortableTargetMarkerFailure,
  kPortableDirectoryHandleFailure,
  kPortableSecurityDescriptorFailure,
  kPortableCallerTokenFailure,
  kPortableImpersonationTokenFailure,
  kPortableAccessCheckFailure,
  kPortableDirectoryAccessDenied,
  kPortableStageProvenanceFailure,
  kPortableStageManifestFailure,
  kPortableStageRequestBindingFailure,
  kPortableStageRestageFailure,
  kPortableStagePayloadIdentityFailure,
  kCount,
};

struct WindowsHelperEventDescriptor {
  DWORD event_id;
  WORD event_type;
  const char* canonical_name;
  const wchar_t* event_message;
};

const WindowsHelperEventDescriptor& DescribeWindowsHelperEvent(
    WindowsHelperEvent event);

// Best-effort support evidence only. The sink accepts no caller-controlled
// fields, paths, tokens, or free-form text and never affects update outcome.
void RecordWindowsHelperEvent(WindowsHelperEvent event) noexcept;

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_HELPER_DIAGNOSTICS_H_
