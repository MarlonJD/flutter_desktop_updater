#include <gtest/gtest.h>

#include <windows.h>

#include <filesystem>
#include <fstream>
#include <memory>
#include <string>

#include "windows_file_transaction.h"
#include "windows_recovery_service.h"
#include "windows_relaunch_service.h"

namespace desktop_updater::helper {
namespace {

WindowsVerifiedPayloadIdentity Payload(const std::string& version) {
  const char digit = version == "new" ? 'b' : version == "old" ? 'a' : 'f';
  return {"com.example.app", "Example Software LLC", std::string(64, digit),
          std::string(64, 'c'), std::string(64, 'd'), L"bin\\example.exe",
          std::string(64, 'e')};
}

class FixtureVerifier final : public WindowsInstallPayloadVerifier {
 public:
  WindowsVerifiedPayloadIdentity Verify(
      HANDLE parent,
      const std::wstring& leaf) override {
    return Payload(ReadUtf8FileRelative(parent, leaf + L"\\version.txt", 32));
  }
};

class OneShotFault final : public WindowsTransactionFaultInjector {
 public:
  explicit OneShotFault(WindowsTransactionFaultPoint point) : point_(point) {}
  void Hit(WindowsTransactionFaultPoint candidate) override {
    if (!thrown_ && candidate == point_) {
      thrown_ = true;
      throw WindowsFileTransactionError(
          WindowsFileTransactionError::Code::kInjectedFailure, "crash");
    }
  }

 private:
  WindowsTransactionFaultPoint point_;
  bool thrown_ = false;
};

class FixedLiveness final : public WindowsProcessLivenessChecker {
 public:
  explicit FixedLiveness(bool alive) : alive_(alive) {}
  bool IsSameProcessAlive(DWORD, std::uint64_t) override { return alive_; }

 private:
  bool alive_;
};

class Fixture {
 public:
  Fixture() {
    root = std::filesystem::temp_directory_path() /
           (L"desktop-updater-recovery-" +
            std::to_wstring(GetCurrentProcessId()) + L"-" +
            std::to_wstring(GetTickCount64()));
    target = root / L"Example.app";
    stage = root / L"Stage.app";
    std::filesystem::create_directories(target);
    std::filesystem::create_directories(stage);
    Write(target, "old");
    Write(stage, "new");
  }
  ~Fixture() {
    std::error_code ignored;
    std::filesystem::remove_all(root, ignored);
  }
  void Write(const std::filesystem::path& directory,
             const std::string& value) {
    std::ofstream(directory / L"version.txt", std::ios::binary) << value;
  }
  std::string Read(const std::filesystem::path& directory) {
    std::ifstream input(directory / L"version.txt", std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(input),
                       std::istreambuf_iterator<char>());
  }
  std::unique_ptr<WindowsFileTransaction> Transaction(
      WindowsTransactionFaultInjector* fault) {
    return std::make_unique<WindowsFileTransaction>(
        target, stage, transaction_id, GetCurrentProcessId(), Payload("new"),
        verifier, fault);
  }
  WindowsRecoveryService Recovery(WindowsProcessLivenessChecker& liveness) {
    return WindowsRecoveryService(target, transaction_id, Payload("new"),
                                  verifier, liveness);
  }

  const std::string transaction_id =
      "00000000-0000-4000-8000-000000000008";
  std::filesystem::path root;
  std::filesystem::path target;
  std::filesystem::path stage;
  FixtureVerifier verifier;
};

TEST(WindowsCrashRecovery, RecoversEveryRenameAndJournalBoundary) {
  for (const auto point : WindowsTransactionCrashInjectionPoints()) {
    Fixture fixture;
    OneShotFault fault(point);
    auto transaction = fixture.Transaction(&fault);
    EXPECT_THROW(transaction->Execute(), WindowsFileTransactionError);
    transaction.reset();

    FixedLiveness dead(false);
    const auto outcome = fixture.Recovery(dead).Recover();
    EXPECT_TRUE(outcome == WindowsRecoveryOutcome::kRecovered ||
                outcome == WindowsRecoveryOutcome::kNothingToRecover ||
                outcome == WindowsRecoveryOutcome::kManualActionRequired);
    if (outcome == WindowsRecoveryOutcome::kRecovered) {
      EXPECT_EQ("new", fixture.Read(fixture.target));
    }
  }
}

TEST(WindowsCrashRecovery, RecoversExternalStageAfterPreparedJournal) {
  Fixture fixture;
  const auto external_parent = fixture.root / L"owned-stage";
  const auto external_stage = external_parent / L"Stage.app";
  std::filesystem::create_directories(external_parent);
  std::filesystem::rename(fixture.stage, external_stage);
  fixture.stage = external_stage;
  OneShotFault fault(WindowsTransactionFaultPoint::kBeforeStageRename);
  auto transaction = fixture.Transaction(&fault);
  EXPECT_THROW(transaction->Execute(), WindowsFileTransactionError);
  transaction.reset();
  FixedLiveness dead(false);

  EXPECT_EQ(WindowsRecoveryOutcome::kRecovered,
            fixture.Recovery(dead).Recover());
  EXPECT_EQ("new", fixture.Read(fixture.target));
}

TEST(WindowsCrashRecovery, TornJournalIsManualWithoutCleanup) {
  Fixture fixture;
  const auto paths = WindowsTransactionPaths::Create(L"Example.app",
                                                     fixture.transaction_id);
  std::ofstream(fixture.root / paths.lock_name, std::ios::binary) << "lock";
  std::ofstream(fixture.root / paths.journal_name, std::ios::binary)
      << "{\"state\":\"pre";
  FixedLiveness dead(false);

  EXPECT_EQ(WindowsRecoveryOutcome::kManualActionRequired,
            fixture.Recovery(dead).Recover());
  EXPECT_EQ("old", fixture.Read(fixture.target));
  EXPECT_TRUE(std::filesystem::exists(fixture.root / paths.journal_name));
}

TEST(WindowsCrashRecovery, AmbiguousNextJournalIsManualWithoutCleanup) {
  Fixture fixture;
  const auto paths = WindowsTransactionPaths::Create(L"Example.app",
                                                     fixture.transaction_id);
  std::ofstream(fixture.root / paths.lock_name, std::ios::binary) << "lock";
  std::ofstream(fixture.root / paths.journal_next_name, std::ios::binary)
      << "partial";
  FixedLiveness dead(false);

  EXPECT_EQ(WindowsRecoveryOutcome::kManualActionRequired,
            fixture.Recovery(dead).Recover());
  EXPECT_EQ("old", fixture.Read(fixture.target));
  EXPECT_TRUE(std::filesystem::exists(fixture.root /
                                      paths.journal_next_name));
}

TEST(WindowsCrashRecovery, InvalidBackupIdentityIsManual) {
  Fixture fixture;
  OneShotFault fault(WindowsTransactionFaultPoint::kAfterBackupRename);
  auto transaction = fixture.Transaction(&fault);
  EXPECT_THROW(transaction->Execute(), WindowsFileTransactionError);
  const auto backup = fixture.root / transaction->paths().backup_name;
  transaction.reset();
  std::filesystem::remove_all(backup);
  std::filesystem::create_directories(backup);
  fixture.Write(backup, "attacker");
  FixedLiveness dead(false);

  EXPECT_EQ(WindowsRecoveryOutcome::kManualActionRequired,
            fixture.Recovery(dead).Recover());
  EXPECT_TRUE(std::filesystem::exists(backup));
}

TEST(WindowsCrashRecovery, LiveOwnerPreventsRecoveryOwnership) {
  Fixture fixture;
  OneShotFault fault(WindowsTransactionFaultPoint::kAfterPreparedJournalFlush);
  auto transaction = fixture.Transaction(&fault);
  EXPECT_THROW(transaction->Execute(), WindowsFileTransactionError);
  FixedLiveness alive(true);

  EXPECT_EQ(WindowsRecoveryOutcome::kLiveOwner,
            fixture.Recovery(alive).Recover());
  EXPECT_EQ("old", fixture.Read(fixture.target));
}

TEST(WindowsCrashRecovery, RecoveryIsIdempotent) {
  Fixture fixture;
  OneShotFault fault(WindowsTransactionFaultPoint::kAfterActivationRename);
  auto transaction = fixture.Transaction(&fault);
  EXPECT_THROW(transaction->Execute(), WindowsFileTransactionError);
  transaction.reset();
  FixedLiveness dead(false);
  auto recovery = fixture.Recovery(dead);

  EXPECT_EQ(WindowsRecoveryOutcome::kRecovered, recovery.Recover());
  EXPECT_EQ(WindowsRecoveryOutcome::kNothingToRecover, recovery.Recover());
  EXPECT_EQ("new", fixture.Read(fixture.target));
}

class RecordingLauncher final : public WindowsProcessLauncher {
 public:
  void Launch(const std::filesystem::path& executable) override {
    launched = executable;
  }
  std::filesystem::path launched;
};

TEST(WindowsCrashRecovery, RelaunchRequiresFullPayloadVerification) {
  Fixture fixture;
  RecordingLauncher launcher;
  WindowsRelaunchService service(Payload("new"), fixture.verifier, launcher);

  EXPECT_THROW(service.Relaunch(fixture.target), WindowsRelaunchError);
  EXPECT_TRUE(launcher.launched.empty());
}

}  // namespace
}  // namespace desktop_updater::helper
