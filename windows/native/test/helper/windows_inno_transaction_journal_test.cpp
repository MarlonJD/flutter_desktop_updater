#include <gtest/gtest.h>

#include <string>

#include "windows_inno_transaction_journal.h"

namespace desktop_updater::helper {
namespace {

ProtectedWindowsInnoJournal Journal() {
  ProtectedWindowsInnoJournal journal;
  journal.transaction_id = "12345678-1234-4123-8123-123456789abc";
  journal.package_id = "com.example.app";
  journal.target_path = L"C:\\Program Files\\Example";
  journal.installer_leaf =
      L".desktop-updater-inno-12345678-1234-4123-8123-123456789abc.exe";
  journal.installer_sha256 = std::string(64, 'a');
  journal.installer_length = 42;
  journal.descriptor_sha256 = std::string(64, 'b');
  journal.provenance_sha256 = std::string(64, 'c');
  journal.current_version = "3.1.2";
  journal.current_build_number = 312;
  journal.current_executable_sha256 = std::string(64, 'd');
  journal.desired_version = "3.1.3";
  journal.desired_build_number = 313;
  journal.execution.silent_arguments = {L"/VERYSILENT", L"/NORESTART"};
  journal.execution.inherit_install_directory = true;
  journal.execution.relaunch_after_install = true;
  journal.execution.installed_executable_relative_path = L"bin\\Example.exe";
  journal.execution.installed_executable_sha256 = std::string(64, 'e');
  journal.execution.log_file_name = L"desktop-updater-inno.log";
  journal.execution.signer_certificate_sha256 = {std::string(64, 'f')};
  journal.owner_process_id = 42;
  journal.owner_process_start_identity = 99;
  return journal;
}

TEST(WindowsInnoTransactionJournal, RoundTripsStrictCanonicalAuthority) {
  const ProtectedWindowsInnoJournal source = Journal();
  const std::string canonical = source.EncodeCanonical();
  const ProtectedWindowsInnoJournal decoded =
      ProtectedWindowsInnoJournal::DecodeStrict(canonical);
  EXPECT_EQ(canonical, decoded.EncodeCanonical());
  const ProtectedWindowsInnoExpectation expectation =
      decoded.BuildExpectation();
  EXPECT_EQ(source.target_path, expectation.install_root);
  EXPECT_EQ(source.target_path.parent_path() / source.installer_leaf,
            expectation.installer_path);
  EXPECT_EQ(source.execution.installed_executable_sha256,
            expectation.execution.installed_executable_sha256);
  EXPECT_EQ(313, expectation.expected_build_number);
}

TEST(WindowsInnoTransactionJournal, RejectsUnknownAndMutableAuthority) {
  const std::string canonical = Journal().EncodeCanonical();
  const std::size_t closing = canonical.rfind('}');
  ASSERT_NE(std::string::npos, closing);
  const std::string injected = canonical.substr(0, closing) +
                               ",\"unexpected\":true}";
  EXPECT_THROW(ProtectedWindowsInnoJournal::DecodeStrict(injected),
               WindowsInnoTransactionJournalError);

  ProtectedWindowsInnoJournal unsafe = Journal();
  unsafe.execution.installed_executable_relative_path = L"..\\attacker.exe";
  EXPECT_THROW(unsafe.EncodeCanonical(),
               WindowsInnoTransactionJournalError);
  unsafe = Journal();
  unsafe.execution.silent_arguments.push_back(L"/LOADINF=attacker.ini");
  EXPECT_THROW(unsafe.EncodeCanonical(),
               WindowsInnoTransactionJournalError);
}

TEST(WindowsInnoTransactionJournal, RecoveryDecisionFailsClosed) {
  EXPECT_EQ(ProtectedWindowsInnoRecoveryDecision::kRecoveryRequired,
            DecideProtectedWindowsInnoRecovery(true, false, true));
  EXPECT_EQ(ProtectedWindowsInnoRecoveryDecision::kCompleted,
            DecideProtectedWindowsInnoRecovery(false, true, false));
  EXPECT_EQ(ProtectedWindowsInnoRecoveryDecision::kRolledBack,
            DecideProtectedWindowsInnoRecovery(false, false, true));
  EXPECT_EQ(ProtectedWindowsInnoRecoveryDecision::kManualActionRequired,
            DecideProtectedWindowsInnoRecovery(false, false, false));
  EXPECT_EQ(ProtectedWindowsInnoRecoveryDecision::kManualActionRequired,
            DecideProtectedWindowsInnoRecovery(false, true, true));
}

}  // namespace
}  // namespace desktop_updater::helper
