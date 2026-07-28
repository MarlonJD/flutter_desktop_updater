#include <gtest/gtest.h>

#include <array>
#include <string>

#include "windows_helper_diagnostics.h"

namespace desktop_updater::helper {
namespace {

TEST(WindowsHelperDiagnostics, ProtocolV1IdsAndMessagesAreStableAndRedacted) {
  constexpr std::array<const char*, 26> expected = {
      "helper scheduled",
      "waiting for parent process",
      "parent process exited",
      "staging path validation",
      "backup start",
      "backup success",
      "backup failure",
      "move start",
      "move success",
      "move failure",
      "rollback start",
      "rollback success",
      "rollback failure",
      "cleanup start",
      "cleanup success",
      "cleanup failure",
      "relaunch attempt",
      "portable bootstrap failure",
      "portable recovery host failure",
      "portable session failure",
      "portable recovery authority failure",
      "portable recovery source failure",
      "portable recovery storage failure",
      "portable recovery artifact failure",
      "portable authorization failure",
      "portable preparation failure",
  };
  static_assert(expected.size() ==
                static_cast<std::size_t>(WindowsHelperEvent::kCount));
  for (std::size_t index = 0; index < expected.size(); ++index) {
    const auto& descriptor = DescribeWindowsHelperEvent(
        static_cast<WindowsHelperEvent>(index));
    EXPECT_EQ(1000U + index, descriptor.event_id);
    EXPECT_EQ(expected[index], std::string(descriptor.canonical_name));
    EXPECT_EQ(std::string::npos,
              std::string(descriptor.canonical_name).find('%'));
  }
  EXPECT_EQ(EVENTLOG_ERROR_TYPE,
            DescribeWindowsHelperEvent(WindowsHelperEvent::kBackupFailure)
                .event_type);
  EXPECT_EQ(EVENTLOG_ERROR_TYPE,
            DescribeWindowsHelperEvent(WindowsHelperEvent::kMoveFailure)
                .event_type);
  EXPECT_EQ(EVENTLOG_ERROR_TYPE,
            DescribeWindowsHelperEvent(WindowsHelperEvent::kRollbackFailure)
                .event_type);
  EXPECT_EQ(EVENTLOG_ERROR_TYPE,
            DescribeWindowsHelperEvent(WindowsHelperEvent::kCleanupFailure)
                .event_type);
  EXPECT_EQ(
      EVENTLOG_ERROR_TYPE,
      DescribeWindowsHelperEvent(
          WindowsHelperEvent::kPortableBootstrapFailure)
          .event_type);
  EXPECT_EQ(
      EVENTLOG_ERROR_TYPE,
      DescribeWindowsHelperEvent(
          WindowsHelperEvent::kPortableRecoveryHostFailure)
          .event_type);
  EXPECT_EQ(
      EVENTLOG_ERROR_TYPE,
      DescribeWindowsHelperEvent(WindowsHelperEvent::kPortableSessionFailure)
          .event_type);
  EXPECT_EQ(EVENTLOG_ERROR_TYPE,
            DescribeWindowsHelperEvent(
                WindowsHelperEvent::kPortableRecoveryAuthorityFailure)
                .event_type);
  EXPECT_EQ(EVENTLOG_ERROR_TYPE,
            DescribeWindowsHelperEvent(
                WindowsHelperEvent::kPortableRecoverySourceFailure)
                .event_type);
  EXPECT_EQ(EVENTLOG_ERROR_TYPE,
            DescribeWindowsHelperEvent(
                WindowsHelperEvent::kPortableRecoveryStorageFailure)
                .event_type);
  EXPECT_EQ(EVENTLOG_ERROR_TYPE,
            DescribeWindowsHelperEvent(
                WindowsHelperEvent::kPortableRecoveryArtifactFailure)
                .event_type);
  EXPECT_EQ(EVENTLOG_ERROR_TYPE,
            DescribeWindowsHelperEvent(
                WindowsHelperEvent::kPortableAuthorizationFailure)
                .event_type);
  EXPECT_EQ(EVENTLOG_ERROR_TYPE,
            DescribeWindowsHelperEvent(
                WindowsHelperEvent::kPortablePreparationFailure)
                .event_type);
  EXPECT_THROW(
      DescribeWindowsHelperEvent(WindowsHelperEvent::kCount),
      std::out_of_range);
}

}  // namespace
}  // namespace desktop_updater::helper
