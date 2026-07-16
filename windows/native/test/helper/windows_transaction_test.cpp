#include <gtest/gtest.h>

#include <windows.h>
#include <winternl.h>

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>

#include "json_value.h"
#include "windows_file_transaction.h"

namespace desktop_updater::helper {
namespace {

WindowsVerifiedPayloadIdentity IdentityForVersion(const std::string& version) {
  const char digit = version == "new" ? 'b' : version == "old" ? 'a' : 'f';
  return WindowsVerifiedPayloadIdentity{
      "com.example.app",
      "Example Software LLC",
      std::string(64, digit),
      std::string(64, 'c'),
      std::string(64, 'd'),
      L"bin\\example.exe",
      std::string(64, 'e'),
      std::string(64, 'f'),
  };
}

class FixturePayloadVerifier final : public WindowsInstallPayloadVerifier {
 public:
  WindowsVerifiedPayloadIdentity Verify(
      HANDLE parent,
      const std::wstring& bundle_leaf) override {
    return IdentityForVersion(ReadUtf8FileRelative(
        parent, bundle_leaf + L"\\version.txt", 32));
  }
};

class ThrowingFaultInjector final : public WindowsTransactionFaultInjector {
 public:
  explicit ThrowingFaultInjector(WindowsTransactionFaultPoint point)
      : point_(point) {}

  void Hit(WindowsTransactionFaultPoint point) override {
    if (!thrown_ && point == point_) {
      thrown_ = true;
      throw WindowsFileTransactionError(
          WindowsFileTransactionError::Code::kInjectedFailure,
          "injected failure");
    }
  }

 private:
  WindowsTransactionFaultPoint point_;
  bool thrown_ = false;
};

class WindowsTransactionFixture {
 public:
  WindowsTransactionFixture() {
    root = std::filesystem::temp_directory_path() /
           (L"desktop-updater-桌面-U0001F680-" +
            std::to_wstring(GetCurrentProcessId()) + L"-" +
            std::to_wstring(GetTickCount64()));
    target = root / L"Example.app";
    stage = root / L"Stage-U0001F680.app";
    std::filesystem::create_directories(target);
    std::filesystem::create_directories(stage);
    WriteVersion(target, "old");
    WriteVersion(stage, "new");
  }

  ~WindowsTransactionFixture() {
    std::error_code ignored;
    std::filesystem::remove_all(root, ignored);
    std::filesystem::remove_all(root.wstring() + L".displaced", ignored);
  }

  void WriteVersion(const std::filesystem::path& directory,
                    const std::string& version) {
    std::ofstream(directory / L"version.txt", std::ios::binary) << version;
  }

  std::string ReadVersion(const std::filesystem::path& directory) const {
    std::ifstream input(directory / L"version.txt", std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(input),
                       std::istreambuf_iterator<char>());
  }

  std::unique_ptr<WindowsFileTransaction> MakeTransaction(
      std::string transaction_id =
          "00000000-0000-4000-8000-000000000008",
      WindowsTransactionFaultInjector* fault = nullptr,
      WindowsTransactionTerminalCallbacks callbacks = {}) {
    return std::make_unique<WindowsFileTransaction>(
        target, stage, std::move(transaction_id), GetCurrentProcessId(),
        IdentityForVersion("new"), verifier, fault, std::move(callbacks));
  }

  std::filesystem::path root;
  std::filesystem::path target;
  std::filesystem::path stage;
  FixturePayloadVerifier verifier;
};

UniqueWindowsHandle OpenFixtureParent(const std::filesystem::path& path) {
  HANDLE handle = CreateFileW(
      path.c_str(), GENERIC_READ | GENERIC_WRITE | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (handle == INVALID_HANDLE_VALUE) {
    throw std::runtime_error("fixture parent open failed");
  }
  return UniqueWindowsHandle(handle);
}

TEST(WindowsFileTransaction, SwapsUnicodeTreeAndRemovesDerivedState) {
  WindowsTransactionFixture fixture;
  auto transaction = fixture.MakeTransaction();
  EXPECT_EQ(L".Example.app.desktop-updater-00000000-0000-4000-8000-"
            L"000000000008.prepared",
            transaction->paths().prepared_name);

  EXPECT_EQ(WindowsFileTransactionResult::kCompleted,
            transaction->Execute());

  EXPECT_EQ("new", fixture.ReadVersion(fixture.target));
  EXPECT_FALSE(std::filesystem::exists(fixture.stage));
  EXPECT_TRUE(FindWindowsTransactionArtifacts(fixture.root).empty());
}

TEST(WindowsFileTransaction, PrepareIsDurableAndDoesNotMutateTarget) {
  WindowsTransactionFixture fixture;
  auto transaction = fixture.MakeTransaction();

  transaction->Prepare();

  EXPECT_TRUE(transaction->prepared());
  EXPECT_EQ("old", fixture.ReadVersion(fixture.target));
  EXPECT_FALSE(std::filesystem::exists(fixture.stage));
  EXPECT_EQ("new", fixture.ReadVersion(
                       fixture.root / transaction->paths().prepared_name));
  EXPECT_FALSE(transaction->prepared_journal_canonical().empty());
  const auto artifacts = FindWindowsTransactionArtifacts(fixture.root);
  EXPECT_NE(artifacts.end(),
            std::find(artifacts.begin(), artifacts.end(),
                      transaction->paths().journal_name));
  EXPECT_NE(artifacts.end(),
            std::find(artifacts.begin(), artifacts.end(),
                      transaction->paths().lock_name));
  EXPECT_EQ(artifacts.end(),
            std::find(artifacts.begin(), artifacts.end(),
                      transaction->paths().lock_candidate_name));
}

TEST(WindowsFileTransaction, LockBindingDistinguishesForeignAndMalformed) {
  WindowsTransactionFixture fixture;
  auto parent = OpenFixtureParent(fixture.root);
  const auto paths = WindowsTransactionPaths::Create(
      L"Example.app", "00000000-0000-4000-8000-000000000008");
  auto foreign = OpenRelativeNoReparse(
      parent.get(), L"foreign.lock",
      GENERIC_READ | GENERIC_WRITE | DELETE | SYNCHRONIZE, 0, FILE_CREATE,
      FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT |
          FILE_WRITE_THROUGH);
  WriteWindowsTransactionLockBinding(
      foreign.get(), "00000000-0000-4000-8000-000000000009");
  EXPECT_EQ(WindowsTransactionLockBindingState::kForeign,
            ClassifyWindowsTransactionLockBinding(
                foreign.get(), paths.transaction_id));

  auto malformed = OpenRelativeNoReparse(
      parent.get(), L"malformed.lock",
      GENERIC_READ | GENERIC_WRITE | DELETE | SYNCHRONIZE, 0, FILE_CREATE,
      FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT |
          FILE_WRITE_THROUGH);
  constexpr char partial[] = "partial";
  DWORD written = 0;
  ASSERT_TRUE(WriteFile(malformed.get(), partial, sizeof(partial) - 1,
                        &written, nullptr));
  ASSERT_TRUE(FlushFileBuffers(malformed.get()));
  EXPECT_EQ(WindowsTransactionLockBindingState::kMalformed,
            ClassifyWindowsTransactionLockBinding(
                malformed.get(), paths.transaction_id));
}

TEST(WindowsFileTransaction,
     FrozenJournalExistsBeforeAnyDerivedFilesystemArtifact) {
  WindowsTransactionFixture fixture;
  auto transaction = fixture.MakeTransaction();

  const WindowsTransactionJournal frozen =
      WindowsTransactionJournal::DecodeStrict(
          transaction->initial_journal_canonical());

  EXPECT_EQ(WindowsTransactionState::kPrepared, frozen.state);
  EXPECT_EQ(transaction->paths().transaction_id, frozen.transaction_id);
  EXPECT_EQ("old", fixture.ReadVersion(fixture.target));
  EXPECT_EQ("new", fixture.ReadVersion(fixture.stage));
  EXPECT_TRUE(FindWindowsTransactionArtifacts(fixture.root).empty());
}

TEST(WindowsFileTransaction,
     JournalV2SeparatesCallerProvenanceFromHelperPayloadSeal) {
  WindowsTransactionFixture fixture;
  auto transaction = fixture.MakeTransaction();

  const WindowsTransactionJournal frozen =
      WindowsTransactionJournal::DecodeStrict(
          transaction->initial_journal_canonical());

  EXPECT_EQ(2, frozen.schema_version);
  EXPECT_EQ(std::string(64, 'c'),
            frozen.expected_payload_identity.stage_provenance_sha256);
  EXPECT_EQ(std::string(64, 'f'),
            frozen.expected_payload_identity.payload_seal_sha256);
}

TEST(WindowsFileTransaction, LegacyV1JournalFailsClosedWithoutPayloadSeal) {
  WindowsTransactionFixture fixture;
  auto transaction = fixture.MakeTransaction();
  auto legacy = desktop_updater::runtime::internal::ParseJson(
      transaction->initial_journal_canonical());
  legacy.object()["schemaVersion"] =
      desktop_updater::runtime::internal::JsonValue(
          static_cast<std::int64_t>(1));
  legacy.object()["expectedPayloadIdentity"].object().erase(
      "payloadSealSha256");

  EXPECT_THROW(
      WindowsTransactionJournal::DecodeStrict(
          desktop_updater::runtime::internal::EncodeCanonicalJson(legacy)),
      WindowsTransactionJournalError);
}

TEST(WindowsFileTransaction,
     TerminalCallbacksBracketDurableLockReleaseAfterArtifactCleanup) {
  {
    WindowsTransactionFixture fixture;
    bool before_observed = false;
    bool after_observed = false;
    const std::string transaction_id =
        "00000000-0000-4000-8000-000000000008";
    const WindowsTransactionPaths paths =
        WindowsTransactionPaths::Create(fixture.target.filename(),
                                        transaction_id);
    auto transaction = fixture.MakeTransaction(
        transaction_id, nullptr,
        {[&]() {
           const auto artifacts = FindWindowsTransactionArtifacts(fixture.root);
           EXPECT_EQ(1U, artifacts.size());
           EXPECT_EQ(paths.lock_name, artifacts.front());
           EXPECT_EQ("new", fixture.ReadVersion(fixture.target));
           before_observed = true;
         },
         [&]() {
           EXPECT_TRUE(FindWindowsTransactionArtifacts(fixture.root).empty());
           EXPECT_EQ("new", fixture.ReadVersion(fixture.target));
           after_observed = true;
         },
         {},
         {}});
    EXPECT_EQ(WindowsFileTransactionResult::kCompleted,
              transaction->Execute());
    EXPECT_TRUE(before_observed);
    EXPECT_TRUE(after_observed);
  }
  {
    WindowsTransactionFixture fixture;
    bool before_observed = false;
    bool after_observed = false;
    const std::string transaction_id =
        "00000000-0000-4000-8000-000000000008";
    const WindowsTransactionPaths paths =
        WindowsTransactionPaths::Create(fixture.target.filename(),
                                        transaction_id);
    auto transaction = fixture.MakeTransaction(
        transaction_id, nullptr,
        {{}, {},
         [&]() {
           const auto artifacts = FindWindowsTransactionArtifacts(fixture.root);
           EXPECT_EQ(1U, artifacts.size());
           EXPECT_EQ(paths.lock_name, artifacts.front());
           EXPECT_EQ("old", fixture.ReadVersion(fixture.target));
           EXPECT_EQ("new", fixture.ReadVersion(fixture.stage));
           before_observed = true;
         },
         [&]() {
           EXPECT_TRUE(FindWindowsTransactionArtifacts(fixture.root).empty());
           EXPECT_EQ("old", fixture.ReadVersion(fixture.target));
           EXPECT_EQ("new", fixture.ReadVersion(fixture.stage));
           after_observed = true;
         }});
    transaction->Prepare();
    transaction->CancelPrepared();
    EXPECT_TRUE(before_observed);
    EXPECT_TRUE(after_observed);
  }
}

TEST(WindowsFileTransaction, PreparedCommitAndCancellationAreDisjoint) {
  {
    WindowsTransactionFixture fixture;
    auto transaction = fixture.MakeTransaction();
    transaction->Prepare();

    EXPECT_EQ(WindowsFileTransactionResult::kCompleted,
              transaction->ExecutePrepared());
    EXPECT_EQ("new", fixture.ReadVersion(fixture.target));
    EXPECT_TRUE(FindWindowsTransactionArtifacts(fixture.root).empty());
  }
  {
    WindowsTransactionFixture fixture;
    auto transaction = fixture.MakeTransaction();
    transaction->Prepare();

    transaction->CancelPrepared();
    EXPECT_EQ("old", fixture.ReadVersion(fixture.target));
    EXPECT_EQ("new", fixture.ReadVersion(fixture.stage));
    EXPECT_TRUE(FindWindowsTransactionArtifacts(fixture.root).empty());
    EXPECT_THROW(transaction->ExecutePrepared(), WindowsFileTransactionError);
  }
}

TEST(WindowsFileTransaction, ExternalStageParentIsRetainedAndRestoredOnCancel) {
  WindowsTransactionFixture fixture;
  const auto external_parent = fixture.root / L"staging";
  const auto external_stage = external_parent / L"External.app";
  std::filesystem::create_directories(external_stage);
  fixture.WriteVersion(external_stage, "new");
  auto transaction = std::make_unique<WindowsFileTransaction>(
      fixture.target, external_stage,
      "00000000-0000-4000-8000-000000000008", GetCurrentProcessId(),
      IdentityForVersion("new"), fixture.verifier);

  transaction->Prepare();

  EXPECT_EQ("old", fixture.ReadVersion(fixture.target));
  EXPECT_FALSE(std::filesystem::exists(external_stage));
  EXPECT_TRUE(std::filesystem::exists(
      fixture.root / transaction->paths().prepared_name));

  transaction->CancelPrepared();
  EXPECT_EQ("new", fixture.ReadVersion(external_stage));
  EXPECT_FALSE(std::filesystem::exists(
      fixture.root / transaction->paths().prepared_name));
  EXPECT_TRUE(FindWindowsTransactionArtifacts(fixture.root).empty());
}

TEST(WindowsFileTransaction, RejectsAlternateStreamsAndHardLinks) {
  EXPECT_THROW(
      WindowsTransactionPaths::Create(
          L"Example.app:attacker",
          "00000000-0000-4000-8000-000000000008"),
      WindowsTransactionJournalError);
  EXPECT_THROW(ValidateWindowsLinkCount(false, 2),
               WindowsTransactionJournalError);
  EXPECT_NO_THROW(ValidateWindowsLinkCount(true, 2));
}

TEST(WindowsFileTransaction, RejectsStageMutationBeforeMutation) {
  WindowsTransactionFixture fixture;
  auto transaction = fixture.MakeTransaction();
  fixture.WriteVersion(fixture.stage, "attacker");

  EXPECT_THROW(transaction->Execute(), WindowsFileTransactionError);
  EXPECT_EQ("old", fixture.ReadVersion(fixture.target));
}

TEST(WindowsFileTransaction, RejectsReparseReplacementBeforeMutation) {
  WindowsTransactionFixture fixture;
  auto transaction = fixture.MakeTransaction();
  std::filesystem::remove_all(fixture.stage);
  if (!CreateSymbolicLinkW(
          fixture.stage.c_str(), fixture.target.c_str(),
          SYMBOLIC_LINK_FLAG_DIRECTORY |
              SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE)) {
    GTEST_SKIP() << "symbolic links unavailable: " << GetLastError();
  }

  EXPECT_THROW(transaction->Execute(), WindowsFileTransactionError);
  EXPECT_EQ("old", fixture.ReadVersion(fixture.target));
}

TEST(WindowsFileTransaction, RejectsReparseAtNestedComponents) {
  WindowsTransactionFixture fixture;
  const auto jump = fixture.stage / L"jump";
  if (!CreateSymbolicLinkW(
          jump.c_str(), fixture.target.c_str(),
          SYMBOLIC_LINK_FLAG_DIRECTORY |
              SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE)) {
    GTEST_SKIP() << "symbolic links unavailable: " << GetLastError();
  }
  auto parent = OpenFixtureParent(fixture.root);

  EXPECT_THROW(ReadUtf8FileRelative(
                   parent.get(), L"Stage-U0001F680.app\\jump\\version.txt", 32),
               WindowsTransactionJournalError);
}

TEST(WindowsFileTransaction, RejectsActualHardLinkedFiles) {
  WindowsTransactionFixture fixture;
  const auto source = fixture.root / L"source.bin";
  const auto alias = fixture.root / L"alias.bin";
  std::ofstream(source, std::ios::binary) << "sealed";
  ASSERT_TRUE(CreateHardLinkW(alias.c_str(), source.c_str(), nullptr));
  auto parent = OpenFixtureParent(fixture.root);

  EXPECT_THROW(OpenRelativeNoReparse(
                   parent.get(), L"source.bin", GENERIC_READ | SYNCHRONIZE,
                   FILE_SHARE_READ | FILE_SHARE_DELETE, FILE_OPEN,
                   FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT),
               WindowsTransactionJournalError);
}

TEST(WindowsFileTransaction, RejectsTargetParentReplacement) {
  WindowsTransactionFixture fixture;
  auto transaction = fixture.MakeTransaction();
  const std::filesystem::path displaced = fixture.root.wstring() + L".displaced";
  std::error_code rename_error;
  std::filesystem::rename(fixture.root, displaced, rename_error);
  if (rename_error) {
    EXPECT_EQ("old", fixture.ReadVersion(fixture.target));
    return;
  }
  std::filesystem::create_directories(fixture.root);

  EXPECT_THROW(transaction->Execute(), WindowsFileTransactionError);
  EXPECT_FALSE(std::filesystem::exists(fixture.target));
  EXPECT_EQ("old", fixture.ReadVersion(displaced / L"Example.app"));
}

TEST(WindowsFileTransaction, SharingViolationAndSecondHelperFailClosed) {
  WindowsTransactionFixture fixture;
  auto transaction = fixture.MakeTransaction();
  transaction->Prepare();

  const auto second_stage = fixture.root / L"Stage-2.app";
  std::filesystem::create_directories(second_stage);
  fixture.WriteVersion(second_stage, "new");
  auto second = std::make_unique<WindowsFileTransaction>(
      fixture.target, second_stage,
      "00000000-0000-4000-8000-000000000009", GetCurrentProcessId(),
      IdentityForVersion("new"), fixture.verifier);
  EXPECT_THROW(
      second->Prepare(),
      WindowsFileTransactionError);

  HANDLE blocker = CreateFileW(
      (fixture.target / L"version.txt").c_str(), GENERIC_READ, FILE_SHARE_READ,
      nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  ASSERT_NE(INVALID_HANDLE_VALUE, blocker);
  EXPECT_THROW(transaction->ExecutePrepared(), WindowsFileTransactionError);
  CloseHandle(blocker);
  EXPECT_EQ("old", fixture.ReadVersion(fixture.target));
}

TEST(WindowsFileTransaction, PersistenceFailuresNeverStartMutation) {
  for (const auto point : {
           WindowsTransactionFaultPoint::kDiskFull,
           WindowsTransactionFaultPoint::kShortJournalWrite,
           WindowsTransactionFaultPoint::kFileFlushFailure,
           WindowsTransactionFaultPoint::kDirectoryFlushFailure,
       }) {
    WindowsTransactionFixture fixture;
    ThrowingFaultInjector injector(point);
    auto transaction = fixture.MakeTransaction(
        "00000000-0000-4000-8000-000000000008", &injector);
    EXPECT_THROW(transaction->Execute(), WindowsFileTransactionError);
    EXPECT_EQ("old", fixture.ReadVersion(fixture.target));
  }
}

}  // namespace
}  // namespace desktop_updater::helper
