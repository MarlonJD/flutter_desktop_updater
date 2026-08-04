#include <gtest/gtest.h>

#include <string>

#include "windows_recovery_host.h"

namespace desktop_updater::helper {
namespace {

ProtectedWindowsHelperEndpointV1 Endpoint() {
  return {ProtectedWindowsHelperEndpointV1::kSchemaVersion,
          "com.example.desktop-updater.privileged",
          "com.example.app",
          "com.example.desktop-updater.helper",
          std::filesystem::path(
              L"C:\\Program Files\\Common Files\\DesktopUpdater\\Example\\1"
              L"\\desktop_updater_install_helper.exe"),
          std::filesystem::path(
              L"C:\\Program Files\\Common Files\\DesktopUpdater\\Example\\1"
              L"\\desktop_updater_helper_policy.json"),
          std::string(64, 'a'),
          std::string(64, 'b')};
}

TEST(WindowsRecoveryHost, DefinitionIsExactSystemBootAuthority) {
  const std::string transaction_id =
      "00000000-0000-4000-8000-000000000025";
  const auto definition =
      BuildWindowsRecoveryHostTaskDefinition(Endpoint(), transaction_id,
                                               std::string(43, 'A'));

  EXPECT_EQ(transaction_id, definition.transaction_id);
  EXPECT_EQ(Endpoint().helper_path, definition.executable_path);
  EXPECT_EQ(L"--recover-current 00000000-0000-4000-8000-000000000025",
            definition.arguments);
  EXPECT_EQ(L"O:SYG:SYD:P(A;;GA;;;SY)(A;;GA;;;BA)",
            definition.security_descriptor);
  EXPECT_NE(std::wstring::npos,
            definition.ready_event_name.find(L"RecoveryReady"));
  EXPECT_EQ(L"SYSTEM", definition.principal_user_id);
  EXPECT_EQ(TASK_LOGON_SERVICE_ACCOUNT, definition.logon_type);
  EXPECT_EQ(TASK_RUNLEVEL_HIGHEST, definition.run_level);
  EXPECT_EQ(TASK_TRIGGER_BOOT, definition.trigger_type);
  EXPECT_EQ(TASK_CREATE | TASK_DONT_ADD_PRINCIPAL_ACE,
            definition.registration_flags);
  EXPECT_EQ(0, definition.run_flags);
  EXPECT_EQ(std::wstring::npos, definition.task_path.find(L"Program Files"));
  EXPECT_EQ(std::wstring::npos, definition.arguments.find(L"--target"));
  EXPECT_EQ(std::wstring::npos, definition.arguments.find(L"--command"));
}

TEST(WindowsRecoveryHost, DefinitionRejectsNonCanonicalTransaction) {
  EXPECT_THROW(BuildWindowsRecoveryHostTaskDefinition(
                   Endpoint(), "00000000-0000-4000-8000-00000000002A",
                   std::string(43, 'A')),
               WindowsRecoveryHostError);
}

}  // namespace
}  // namespace desktop_updater::helper
