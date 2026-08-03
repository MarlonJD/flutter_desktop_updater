#include <gtest/gtest.h>

#include <windows.h>

#include <filesystem>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "windows_file_transaction.h"
#include "windows_recovery_service.h"
#include "windows_relaunch_service.h"

namespace desktop_updater::helper {
namespace {

WindowsVerifiedPayloadIdentity Payload(const std::string& version) {
  const char digit = version == "new" ? 'b' : version == "old" ? 'a' : 'f';
  return {"com.example.app", "Example Software LLC", std::string(64, digit),
          std::string(64, 'c'), std::string(64, 'd'), L"bin\\example.exe",
          std::string(64, 'e'), std::string(64, 'f')};
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
  explicit OneShotFault(WindowsTransactionFaultPoint point,
                        std::size_t occurrence = 1)
      : point_(point), occurrence_(occurrence) {}
  void Hit(WindowsTransactionFaultPoint candidate) override {
    if (!thrown_ && candidate == point_ && ++observed_ == occurrence_) {
      thrown_ = true;
      throw WindowsFileTransactionError(
          WindowsFileTransactionError::Code::kInjectedFailure, "crash");
    }
  }

 private:
  WindowsTransactionFaultPoint point_;
  std::size_t occurrence_;
  std::size_t observed_ = 0;
  bool thrown_ = false;
};

class ExitAtFault final : public WindowsTransactionFaultInjector {
 public:
  explicit ExitAtFault(WindowsTransactionFaultPoint point) : point_(point) {}

  void Hit(WindowsTransactionFaultPoint point) override {
    if (point == point_) ExitProcess(83);
  }

 private:
  WindowsTransactionFaultPoint point_;
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
  explicit Fixture(std::filesystem::path existing_root = {})
      : owns_root_(existing_root.empty()) {
    root = owns_root_
               ? std::filesystem::temp_directory_path() /
                     (L"desktop-updater-recovery-" +
                      std::to_wstring(GetCurrentProcessId()) + L"-" +
                      std::to_wstring(GetTickCount64()))
               : std::move(existing_root);
    target = root / L"Example.app";
    stage = root / L"Stage.app";
    std::filesystem::create_directories(target);
    std::filesystem::create_directories(stage);
    Write(target, "old");
    Write(stage, "new");
  }
  ~Fixture() {
    if (!owns_root_) return;
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
  WindowsFileIdentity Identity(const std::filesystem::path& directory) {
    UniqueWindowsHandle handle(CreateFileW(
        directory.c_str(),
        FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    if (!handle.valid()) {
      throw std::runtime_error("fixture directory identity unavailable");
    }
    return ReadWindowsFileIdentity(handle.get());
  }
  std::unique_ptr<WindowsFileTransaction> Transaction(
      WindowsTransactionFaultInjector* fault) {
    return std::make_unique<WindowsFileTransaction>(
        target, stage, transaction_id, GetCurrentProcessId(), Payload("new"),
        verifier, fault);
  }
  WindowsRecoveryService Recovery(
      WindowsProcessLivenessChecker& liveness,
      WindowsRecoveryIntent intent =
          WindowsRecoveryIntent::kCompleteCommitted) {
    return WindowsRecoveryService(target, transaction_id, Payload("new"),
                                  verifier, liveness, intent);
  }

  const std::string transaction_id =
      "00000000-0000-4000-8000-000000000008";
  std::filesystem::path root;
  std::filesystem::path target;
  std::filesystem::path stage;
  FixtureVerifier verifier;

 private:
  bool owns_root_;
};

class ScopedEnvironmentVariable {
 public:
  explicit ScopedEnvironmentVariable(std::wstring name) : name_(std::move(name)) {
    const DWORD required = GetEnvironmentVariableW(name_.c_str(), nullptr, 0);
    if (required == 0) return;
    previous_.resize(required);
    const DWORD copied =
        GetEnvironmentVariableW(name_.c_str(), previous_.data(), required);
    if (copied == 0 || copied >= required) {
      throw std::runtime_error("could not read process environment");
    }
    previous_.resize(copied);
    had_value_ = true;
  }

  ~ScopedEnvironmentVariable() {
    (void)SetEnvironmentVariableW(name_.c_str(),
                                  had_value_ ? previous_.c_str() : nullptr);
  }

  void Set(const std::wstring& value) {
    if (!SetEnvironmentVariableW(name_.c_str(), value.c_str())) {
      throw std::runtime_error("could not set process environment");
    }
  }

 private:
  std::wstring name_;
  std::wstring previous_;
  bool had_value_ = false;
};

std::filesystem::path FreshProcessTestExecutable() {
  std::vector<wchar_t> buffer(32'768);
  const DWORD length = GetModuleFileNameW(nullptr, buffer.data(),
                                          static_cast<DWORD>(buffer.size()));
  if (length == 0 || length >= buffer.size()) {
    throw std::runtime_error("fresh-process test executable is unavailable");
  }
  return std::filesystem::path(std::wstring(buffer.data(), length));
}

int RunFreshProcessWorker(const std::wstring& filter,
                          const std::filesystem::path& root) {
  ScopedEnvironmentVariable root_environment(
      L"DESKTOP_UPDATER_FRESH_RECOVERY_ROOT");
  root_environment.Set(root.wstring());
  const std::filesystem::path executable = FreshProcessTestExecutable();
  std::wstring command_line = L"\"" + executable.wstring() + L"\" " +
                              L"--gtest_filter=" + filter;
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(executable.c_str(), command_line.data(), nullptr,
                      nullptr, FALSE, CREATE_UNICODE_ENVIRONMENT, nullptr,
                      executable.parent_path().c_str(), &startup, &process)) {
    return -1;
  }
  CloseHandle(process.hThread);
  if (WaitForSingleObject(process.hProcess, 30'000) != WAIT_OBJECT_0) {
    (void)TerminateProcess(process.hProcess, 124);
    (void)WaitForSingleObject(process.hProcess, 5'000);
    CloseHandle(process.hProcess);
    return -1;
  }
  DWORD exit_code = 0;
  const BOOL has_exit_code = GetExitCodeProcess(process.hProcess, &exit_code);
  CloseHandle(process.hProcess);
  return has_exit_code ? static_cast<int>(exit_code) : -1;
}

std::filesystem::path FreshProcessRoot() {
  return std::filesystem::temp_directory_path() /
         (L"desktop-updater-fresh-recovery-" +
          std::to_wstring(GetCurrentProcessId()) + L"-" +
          std::to_wstring(GetTickCount64()));
}

std::string ReadFile(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

TEST(WindowsCrashRecovery, RecoversEveryRenameAndJournalBoundary) {
  for (const auto point : WindowsTransactionCrashInjectionPoints()) {
    SCOPED_TRACE(static_cast<int>(point));
    Fixture fixture;
    OneShotFault fault(point);
    auto transaction = fixture.Transaction(&fault);
    EXPECT_THROW(transaction->Execute(), WindowsFileTransactionError);
    transaction.reset();

    FixedLiveness dead(false);
    const auto outcome = fixture.Recovery(dead).Recover();
    if (point == WindowsTransactionFaultPoint::kBeforePreparedJournalFlush) {
      EXPECT_EQ(WindowsRecoveryOutcome::kNothingToRecover, outcome);
      EXPECT_EQ("old", fixture.Read(fixture.target));
    } else {
      EXPECT_EQ(WindowsRecoveryOutcome::kRecovered, outcome);
      EXPECT_EQ("new", fixture.Read(fixture.target));
    }
  }
}

TEST(WindowsCrashRecovery, FreshProcessWriterLeavesPreparedJournal) {
  const DWORD required = GetEnvironmentVariableW(
      L"DESKTOP_UPDATER_FRESH_RECOVERY_ROOT", nullptr, 0);
  if (required == 0) {
    GTEST_SKIP() << "run only by the fresh-process recovery orchestrator";
  }
  std::wstring root(required, L'\0');
  const DWORD copied = GetEnvironmentVariableW(
      L"DESKTOP_UPDATER_FRESH_RECOVERY_ROOT", root.data(), required);
  ASSERT_GT(copied, 0U);
  ASSERT_LT(copied, required);
  root.resize(copied);

  Fixture fixture{std::filesystem::path(root)};
  ExitAtFault fault(WindowsTransactionFaultPoint::kAfterPreparedJournalFlush);
  auto transaction = fixture.Transaction(&fault);
  transaction->Execute();
  FAIL() << "prepared-journal crash boundary was not reached";
}

TEST(WindowsCrashRecovery, FreshProcessReaderResolvesPreparedJournal) {
  const DWORD required = GetEnvironmentVariableW(
      L"DESKTOP_UPDATER_FRESH_RECOVERY_ROOT", nullptr, 0);
  if (required == 0) {
    GTEST_SKIP() << "run only by the fresh-process recovery orchestrator";
  }
  std::wstring root(required, L'\0');
  const DWORD copied = GetEnvironmentVariableW(
      L"DESKTOP_UPDATER_FRESH_RECOVERY_ROOT", root.data(), required);
  ASSERT_GT(copied, 0U);
  ASSERT_LT(copied, required);
  root.resize(copied);

  const std::filesystem::path root_path(root);
  const std::filesystem::path target = root_path / L"Example.app";
  ASSERT_TRUE(std::filesystem::exists(target));
  FixtureVerifier verifier;
  FixedLiveness dead(false);
  WindowsRecoveryService recovery(
      target, "00000000-0000-4000-8000-000000000008", Payload("new"),
      verifier, dead);
  ASSERT_EQ(WindowsRecoveryOutcome::kRecovered, recovery.Recover());
  EXPECT_EQ("new", ReadFile(target / L"version.txt"));
  std::ofstream(root_path / L"fresh-reader-proof.txt", std::ios::binary)
      << "resolved-without-writer-state\n";
}

TEST(WindowsCrashRecovery,
     FreshProcessesRecoverPreparedCrashWithoutReencoding) {
  const std::filesystem::path root = FreshProcessRoot();
  struct Cleanup {
    std::filesystem::path root;
    ~Cleanup() {
      std::error_code ignored;
      std::filesystem::remove_all(root, ignored);
    }
  } cleanup{root};

  ASSERT_EQ(83, RunFreshProcessWorker(
                    L"WindowsCrashRecovery.FreshProcessWriterLeavesPreparedJournal",
                    root));
  const WindowsTransactionPaths paths = WindowsTransactionPaths::Create(
      L"Example.app", "00000000-0000-4000-8000-000000000008");
  const std::filesystem::path journal = root / paths.journal_name;
  ASSERT_TRUE(std::filesystem::exists(journal));
  const std::string writer_bytes = ReadFile(journal);
  ASSERT_FALSE(writer_bytes.empty());

  ASSERT_EQ(0, RunFreshProcessWorker(
                   L"WindowsCrashRecovery.FreshProcessReaderResolvesPreparedJournal",
                   root));
  EXPECT_EQ("new", ReadFile(root / L"Example.app" / L"version.txt"));
  EXPECT_EQ("resolved-without-writer-state\n",
            ReadFile(root / L"fresh-reader-proof.txt"));
  EXPECT_FALSE(std::filesystem::exists(journal));
}

TEST(WindowsCrashRecovery,
     PromotesPreparedNextFlushedImmediatelyBeforeRename) {
  Fixture fixture;
  OneShotFault fault(
      WindowsTransactionFaultPoint::kAfterJournalNextFlushBeforeRename);
  auto transaction = fixture.Transaction(&fault);
  EXPECT_THROW(transaction->Execute(), WindowsFileTransactionError);
  const auto paths = transaction->paths();
  transaction.reset();
  ASSERT_TRUE(std::filesystem::exists(fixture.root / paths.journal_next_name));
  ASSERT_FALSE(std::filesystem::exists(fixture.root / paths.journal_name));
  FixedLiveness dead(false);

  EXPECT_EQ(WindowsRecoveryOutcome::kRecovered,
            fixture.Recovery(dead).Recover());
  EXPECT_EQ("new", fixture.Read(fixture.target));
  EXPECT_TRUE(FindWindowsTransactionArtifacts(fixture.root).empty());
}

TEST(WindowsCrashRecovery,
     PromotesBackupCreatedNextFlushedImmediatelyBeforeRename) {
  Fixture fixture;
  OneShotFault fault(
      WindowsTransactionFaultPoint::kAfterJournalNextFlushBeforeRename, 2);
  auto transaction = fixture.Transaction(&fault);
  EXPECT_THROW(transaction->Execute(), WindowsFileTransactionError);
  const auto paths = transaction->paths();
  transaction.reset();
  ASSERT_TRUE(std::filesystem::exists(fixture.root / paths.journal_name));
  ASSERT_TRUE(std::filesystem::exists(fixture.root / paths.journal_next_name));
  ASSERT_TRUE(std::filesystem::exists(fixture.root / paths.backup_name));
  FixedLiveness dead(false);

  EXPECT_EQ(WindowsRecoveryOutcome::kRecovered,
            fixture.Recovery(dead).Recover());
  EXPECT_EQ("new", fixture.Read(fixture.target));
  EXPECT_TRUE(FindWindowsTransactionArtifacts(fixture.root).empty());
}

TEST(WindowsCrashRecovery,
     PromotesCompletedNextFlushedImmediatelyBeforeRename) {
  Fixture fixture;
  OneShotFault fault(
      WindowsTransactionFaultPoint::kAfterJournalNextFlushBeforeRename, 4);
  auto transaction = fixture.Transaction(&fault);
  EXPECT_THROW(transaction->Execute(), WindowsFileTransactionError);
  const auto paths = transaction->paths();
  transaction.reset();
  ASSERT_TRUE(std::filesystem::exists(fixture.root / paths.journal_name));
  ASSERT_TRUE(std::filesystem::exists(fixture.root / paths.journal_next_name));
  ASSERT_TRUE(std::filesystem::exists(fixture.root / paths.backup_name));
  FixedLiveness dead(false);

  EXPECT_EQ(WindowsRecoveryOutcome::kRecovered,
            fixture.Recovery(dead).Recover());
  EXPECT_EQ("new", fixture.Read(fixture.target));
  EXPECT_TRUE(FindWindowsTransactionArtifacts(fixture.root).empty());
}

TEST(WindowsCrashRecovery,
     EmptyInitialNextBeforeFirstWriteDoesNotBrickRetry) {
  Fixture fixture;
  OneShotFault fault(WindowsTransactionFaultPoint::kShortJournalWrite);
  auto transaction = fixture.Transaction(&fault);
  EXPECT_THROW(transaction->Execute(), WindowsFileTransactionError);
  const auto paths = transaction->paths();
  transaction.reset();
  ASSERT_TRUE(std::filesystem::exists(fixture.root / paths.journal_next_name));
  EXPECT_EQ(0U,
            std::filesystem::file_size(fixture.root / paths.journal_next_name));
  FixedLiveness dead(false);

  EXPECT_EQ(WindowsRecoveryOutcome::kNothingToRecover,
            fixture.Recovery(dead).Recover());
  EXPECT_EQ("old", fixture.Read(fixture.target));
  EXPECT_EQ("new", fixture.Read(fixture.stage));
  EXPECT_TRUE(FindWindowsTransactionArtifacts(fixture.root).empty());
}

TEST(WindowsCrashRecovery,
     PartialNextWithValidFinalUsesFinalAndConverges) {
  Fixture fixture;
  auto transaction = fixture.Transaction(nullptr);
  transaction->Prepare();
  const auto paths = transaction->paths();
  std::string final_canonical;
  {
    std::ifstream final_input(fixture.root / paths.journal_name,
                              std::ios::binary);
    final_canonical.assign(std::istreambuf_iterator<char>(final_input),
                           std::istreambuf_iterator<char>());
  }
  ASSERT_GT(final_canonical.size(), 16U);
  std::ofstream(fixture.root / paths.journal_next_name,
                std::ios::binary | std::ios::trunc)
      << final_canonical.substr(0, final_canonical.size() / 2);
  transaction.reset();
  FixedLiveness dead(false);

  EXPECT_EQ(WindowsRecoveryOutcome::kRecovered,
            fixture.Recovery(dead).Recover());
  EXPECT_EQ("new", fixture.Read(fixture.target));
  EXPECT_TRUE(FindWindowsTransactionArtifacts(fixture.root).empty());
}

TEST(WindowsCrashRecovery,
     ValidNextWithChangedImmutableAuthorityFailsClosed) {
  Fixture fixture;
  auto transaction = fixture.Transaction(nullptr);
  transaction->Prepare();
  const auto paths = transaction->paths();
  std::ifstream input(fixture.root / paths.journal_name, std::ios::binary);
  const std::string canonical{std::istreambuf_iterator<char>(input),
                              std::istreambuf_iterator<char>()};
  WindowsTransactionJournal changed =
      WindowsTransactionJournal::DecodeStrict(canonical);
  ++changed.owner_process_start_identity;
  std::ofstream(fixture.root / paths.journal_next_name,
                std::ios::binary | std::ios::trunc)
      << changed.EncodeCanonical();
  transaction.reset();
  FixedLiveness dead(false);

  EXPECT_EQ(WindowsRecoveryOutcome::kManualActionRequired,
            fixture.Recovery(dead).Recover());
  EXPECT_TRUE(std::filesystem::exists(fixture.root / paths.journal_next_name));
  EXPECT_EQ("old", fixture.Read(fixture.target));
}

TEST(WindowsCrashRecovery, HardLinkedNextReplacementFailsClosed) {
  Fixture fixture;
  auto transaction = fixture.Transaction(nullptr);
  transaction->Prepare();
  const auto paths = transaction->paths();
  const auto replacement = fixture.root / L"replacement.bin";
  std::ofstream(replacement, std::ios::binary) << "replacement";
  ASSERT_TRUE(CreateHardLinkW(
      (fixture.root / paths.journal_next_name).c_str(), replacement.c_str(),
      nullptr));
  transaction.reset();
  FixedLiveness dead(false);

  EXPECT_EQ(WindowsRecoveryOutcome::kManualActionRequired,
            fixture.Recovery(dead).Recover());
  EXPECT_TRUE(std::filesystem::exists(fixture.root / paths.journal_next_name));
  EXPECT_EQ("old", fixture.Read(fixture.target));
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

TEST(WindowsCrashRecovery,
     PreparedJournalRejectsDeletedTargetWithoutMovingStage) {
  Fixture fixture;
  OneShotFault fault(WindowsTransactionFaultPoint::kBeforeStageRename);
  auto transaction = fixture.Transaction(&fault);
  EXPECT_THROW(transaction->Execute(), WindowsFileTransactionError);
  const auto paths = transaction->paths();
  transaction.reset();

  const WindowsFileIdentity stage_identity = fixture.Identity(fixture.stage);
  std::filesystem::remove_all(fixture.target);
  ASSERT_FALSE(std::filesystem::exists(fixture.target));
  FixedLiveness dead(false);

  EXPECT_EQ(WindowsRecoveryOutcome::kManualActionRequired,
            fixture.Recovery(dead).Recover());
  ASSERT_TRUE(std::filesystem::exists(fixture.stage));
  EXPECT_EQ(stage_identity, fixture.Identity(fixture.stage));
  EXPECT_EQ("new", fixture.Read(fixture.stage));
  EXPECT_FALSE(std::filesystem::exists(fixture.root / paths.prepared_name));
  EXPECT_FALSE(std::filesystem::exists(fixture.root / paths.backup_name));
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

TEST(WindowsCrashRecovery, RollsBackWhenCommitWasNotDurablyAccepted) {
  Fixture fixture;
  auto transaction = fixture.Transaction(nullptr);
  transaction->Prepare();
  transaction.reset();
  FixedLiveness dead(false);

  EXPECT_EQ(WindowsRecoveryOutcome::kRolledBack,
            fixture
                .Recovery(dead,
                          WindowsRecoveryIntent::kRollBackUncommitted)
                .Recover());
  EXPECT_EQ("old", fixture.Read(fixture.target));
  EXPECT_EQ("new", fixture.Read(fixture.stage));
  EXPECT_TRUE(FindWindowsTransactionArtifacts(fixture.root).empty());
}

TEST(WindowsCrashRecovery, RollbackIntentNeverContinuesStartedMutation) {
  Fixture fixture;
  OneShotFault fault(WindowsTransactionFaultPoint::kAfterBackupRename);
  auto transaction = fixture.Transaction(&fault);
  EXPECT_THROW(transaction->Execute(), WindowsFileTransactionError);
  transaction.reset();
  FixedLiveness dead(false);

  EXPECT_EQ(WindowsRecoveryOutcome::kManualActionRequired,
            fixture
                .Recovery(dead,
                          WindowsRecoveryIntent::kRollBackUncommitted)
                .Recover());
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
