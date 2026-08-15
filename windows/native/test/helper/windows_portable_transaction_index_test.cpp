#include <gtest/gtest.h>

#include <shlobj.h>

#include <filesystem>
#include <iomanip>
#include <sstream>
#include <string>

#include "windows_helper_bootstrap.h"
#include "windows_persistent_recovery.h"
#include "windows_portable_recovery_host.h"
#include "windows_portable_transaction_index.h"

namespace desktop_updater::helper {
namespace {

WindowsHelperPolicy PortablePolicy(char application, char helper) {
  return WindowsHelperPolicy::ForPortableTesting(
      "com.example.app", std::string(64, application),
      std::string(64, helper));
}

std::string UniqueTransactionId() {
  static std::uint64_t sequence = 0;
  const std::uint64_t value =
      ((GetTickCount64() << 16) ^ GetCurrentProcessId() ^ ++sequence) &
      0xffffffffffffULL;
  std::ostringstream suffix;
  suffix << std::hex << std::nouppercase << std::setfill('0')
         << std::setw(12) << value;
  return "00000000-0000-4000-8000-" + suffix.str();
}

WindowsPersistentTransactionRecord Record(
    const WindowsHelperPolicy& policy,
    const std::string& transaction_id,
    const std::string& state,
    const std::string& outcome = "none",
    const std::string& relaunch = "notRequested") {
  const WindowsTransactionPaths paths =
      WindowsTransactionPaths::Create(L"Example.app", transaction_id);
  WindowsFileIdentity parent;
  parent.volume_serial = 7;
  parent.file_id.fill(1);
  parent.attributes = FILE_ATTRIBUTE_DIRECTORY;
  parent.number_of_links = 1;
  parent.directory = true;
  WindowsFileIdentity target = parent;
  target.file_id.fill(2);
  WindowsFileIdentity stage_parent = parent;
  stage_parent.file_id.fill(3);
  WindowsFileIdentity stage = parent;
  stage.file_id.fill(4);

  WindowsTransactionJournal journal;
  journal.transaction_id = transaction_id;
  journal.owner_process_id = 42;
  journal.owner_process_start_identity = 43;
  journal.target_name = paths.target_name;
  journal.original_stage_parent_path = L"C:\\Users\\alice\\Stage";
  journal.original_stage_name = L"Stage.app";
  journal.prepared_name = paths.prepared_name;
  journal.backup_name = paths.backup_name;
  journal.lock_name = paths.lock_name;
  journal.parent_identity = parent;
  journal.stage_parent_identity = stage_parent;
  journal.target_identity = target;
  journal.stage_identity = stage;
  journal.expected_payload_identity = {
      "com.example.app",    "Example Software LLC", std::string(64, 'a'),
      std::string(64, 'b'), std::string(64, 'c'),   L"bin\\example.exe",
      std::string(64, 'd'), std::string(64, 'e')};
  journal.state = WindowsTransactionState::kPrepared;
  const std::string canonical = journal.EncodeCanonical();
  return {WindowsPersistentTransactionRecord::kSchemaVersion,
          transaction_id,
          "directoryReplace",
          policy.policy_id(),
          policy.application_package_id(),
          policy.helper_sha256(),
          42,
          43,
          44,
          45,
          std::string(43, 'A'),
          std::filesystem::path(L"C:\\Users\\alice\\Example.app"),
          state,
          outcome,
          relaunch,
          canonical,
          WindowsHelperSha256Hex(canonical)};
}

WindowsPersistentResolverClaim Claim(
    const std::string& transaction_id,
    std::int64_t resolver_process_id,
    std::int64_t caller_process_id,
    char nonce_character,
    const std::string& state) {
  return {WindowsPersistentResolverClaim::kSchemaVersion,
          transaction_id,
          resolver_process_id,
          resolver_process_id + 100,
          caller_process_id,
          caller_process_id + 100,
          std::string(43, nonce_character),
          state};
}

std::filesystem::path TransactionPath(const WindowsHelperPolicy& policy,
                                      const std::string& transaction_id) {
  PWSTR raw = nullptr;
  if (SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_DEFAULT, nullptr,
                           &raw) != S_OK || raw == nullptr) {
    throw std::runtime_error("LocalAppData is unavailable");
  }
  const std::filesystem::path local_app_data(raw);
  CoTaskMemFree(raw);
  const std::string binding = WindowsPortableIndexBindingKey(policy);
  return local_app_data / L"desktop_updater_portable_transactions_v1" /
         std::wstring(binding.begin(), binding.end()) /
         std::wstring(transaction_id.begin(), transaction_id.end());
}

class ScopedTransactionCleanup {
 public:
  explicit ScopedTransactionCleanup(std::filesystem::path path)
      : path_(std::move(path)) {}
  ~ScopedTransactionCleanup() {
    std::error_code ignored;
    std::filesystem::remove_all(path_, ignored);
  }

 private:
  std::filesystem::path path_;
};

class OneShotStoreFault final
    : public WindowsPortableTransactionStoreFaultInjector {
 public:
  explicit OneShotStoreFault(WindowsPortableTransactionStoreFaultPoint point)
      : point_(point) {}

  void Hit(WindowsPortableTransactionStoreFaultPoint point) override {
    if (!hit_ && point == point_) {
      hit_ = true;
      throw std::runtime_error("simulated portable store process death");
    }
  }

 private:
  WindowsPortableTransactionStoreFaultPoint point_;
  bool hit_ = false;
};

TEST(WindowsPortableTransactionIndex,
     FreshProcessPromotesValidatedInitialNextAfterDeath) {
  const WindowsHelperPolicy policy = PortablePolicy('a', 'b');
  const std::string transaction_id = UniqueTransactionId();
  const std::filesystem::path transaction_path =
      TransactionPath(policy, transaction_id);
  ScopedTransactionCleanup cleanup(transaction_path);
  const std::string canonical =
      Record(policy, transaction_id, "preparing").EncodeCanonical();
  OneShotStoreFault fault(
      WindowsPortableTransactionStoreFaultPoint::kAfterNextFlush);

  {
    WindowsPortableTransactionStore store(policy, GetCurrentProcess(), true,
                                           &fault);
    EXPECT_THROW(store.CreateRecord(transaction_id, canonical),
                 std::runtime_error);
  }
  EXPECT_FALSE(std::filesystem::exists(transaction_path / L"record.json"));
  EXPECT_TRUE(std::filesystem::exists(transaction_path / L"record.next"));

  WindowsPortableTransactionStore fresh(policy, GetCurrentProcess(), false);
  const auto recovered = fresh.ReadRecord(transaction_id);
  ASSERT_TRUE(recovered.has_value());
  EXPECT_EQ(canonical, *recovered);
  EXPECT_TRUE(std::filesystem::exists(transaction_path / L"record.json"));
  EXPECT_FALSE(std::filesystem::exists(transaction_path / L"record.next"));
}

TEST(WindowsPortableTransactionIndex,
     FreshProcessDeletesExactEmptyInitialNextAfterPreWriteDeath) {
  const WindowsHelperPolicy policy = PortablePolicy('a', 'b');
  const std::string transaction_id = UniqueTransactionId();
  const std::filesystem::path transaction_path =
      TransactionPath(policy, transaction_id);
  ScopedTransactionCleanup cleanup(transaction_path);
  const std::string canonical =
      Record(policy, transaction_id, "preparing").EncodeCanonical();
  OneShotStoreFault fault(
      WindowsPortableTransactionStoreFaultPoint::kAfterNextCreate);

  {
    WindowsPortableTransactionStore store(policy, GetCurrentProcess(), true,
                                           &fault);
    EXPECT_THROW(store.CreateRecord(transaction_id, canonical),
                 std::runtime_error);
  }
  ASSERT_TRUE(std::filesystem::exists(transaction_path / L"record.next"));
  EXPECT_EQ(0U, std::filesystem::file_size(transaction_path / L"record.next"));

  WindowsPortableTransactionStore fresh(policy, GetCurrentProcess(), false);
  EXPECT_FALSE(fresh.ReadRecord(transaction_id).has_value());
  EXPECT_FALSE(std::filesystem::exists(transaction_path / L"record.next"));
}

TEST(WindowsPortableTransactionIndex,
     FreshProcessPromotesValidatedPreparingToPreparedUpdate) {
  const WindowsHelperPolicy policy = PortablePolicy('a', 'b');
  const std::string transaction_id = UniqueTransactionId();
  const std::filesystem::path transaction_path =
      TransactionPath(policy, transaction_id);
  ScopedTransactionCleanup cleanup(transaction_path);
  const std::string initial =
      Record(policy, transaction_id, "preparing").EncodeCanonical();
  const std::string updated =
      Record(policy, transaction_id, "prepared").EncodeCanonical();
  {
    WindowsPortableTransactionStore store(policy, GetCurrentProcess(), true);
    store.CreateRecord(transaction_id, initial);
  }
  OneShotStoreFault fault(
      WindowsPortableTransactionStoreFaultPoint::kAfterNextFlush);
  {
    WindowsPortableTransactionStore store(policy, GetCurrentProcess(), false,
                                           &fault);
    EXPECT_THROW(store.WriteRecord(transaction_id, updated),
                 std::runtime_error);
  }
  EXPECT_TRUE(std::filesystem::exists(transaction_path / L"record.json"));
  EXPECT_TRUE(std::filesystem::exists(transaction_path / L"record.next"));

  WindowsPortableTransactionStore fresh(policy, GetCurrentProcess(), false);
  const auto recovered = fresh.ReadRecord(transaction_id);
  ASSERT_TRUE(recovered.has_value());
  EXPECT_EQ(updated, *recovered);
  EXPECT_FALSE(std::filesystem::exists(transaction_path / L"record.next"));
}

TEST(WindowsPortableTransactionIndex,
     FreshProcessPromotesValidatedPreparedToCommitAcceptedUpdate) {
  const WindowsHelperPolicy policy = PortablePolicy('a', 'b');
  const std::string transaction_id = UniqueTransactionId();
  const std::filesystem::path transaction_path =
      TransactionPath(policy, transaction_id);
  ScopedTransactionCleanup cleanup(transaction_path);
  const std::string initial =
      Record(policy, transaction_id, "prepared").EncodeCanonical();
  const std::string updated =
      Record(policy, transaction_id, "commitAccepted", "none",
             "launchPending")
          .EncodeCanonical();
  {
    WindowsPortableTransactionStore store(policy, GetCurrentProcess(), true);
    store.CreateRecord(transaction_id, initial);
  }
  OneShotStoreFault fault(
      WindowsPortableTransactionStoreFaultPoint::kAfterNextFlush);
  {
    WindowsPortableTransactionStore store(policy, GetCurrentProcess(), false,
                                           &fault);
    EXPECT_THROW(store.WriteRecord(transaction_id, updated),
                 std::runtime_error);
  }

  WindowsPortableTransactionStore fresh(policy, GetCurrentProcess(), false);
  const auto recovered = fresh.ReadRecord(transaction_id);
  ASSERT_TRUE(recovered.has_value());
  EXPECT_EQ(updated, *recovered);
  EXPECT_FALSE(std::filesystem::exists(transaction_path / L"record.next"));
}

TEST(WindowsPortableTransactionIndex,
     FreshProcessPromotesValidatedCleanupPendingToTerminalUpdate) {
  const WindowsHelperPolicy policy = PortablePolicy('a', 'b');
  const std::string transaction_id = UniqueTransactionId();
  const std::filesystem::path transaction_path =
      TransactionPath(policy, transaction_id);
  ScopedTransactionCleanup cleanup(transaction_path);
  const std::string initial =
      Record(policy, transaction_id, "completedCleanupPending", "newTarget",
             "launchPending")
          .EncodeCanonical();
  const std::string updated =
      Record(policy, transaction_id, "completed", "newTarget",
             "launchPending")
          .EncodeCanonical();
  {
    WindowsPortableTransactionStore store(policy, GetCurrentProcess(), true);
    store.CreateRecord(transaction_id, initial);
  }
  OneShotStoreFault fault(
      WindowsPortableTransactionStoreFaultPoint::kAfterNextFlush);
  {
    WindowsPortableTransactionStore store(policy, GetCurrentProcess(), false,
                                           &fault);
    EXPECT_THROW(store.WriteRecord(transaction_id, updated),
                 std::runtime_error);
  }

  WindowsPortableTransactionStore fresh(policy, GetCurrentProcess(), false);
  const auto recovered = fresh.ReadRecord(transaction_id);
  ASSERT_TRUE(recovered.has_value());
  EXPECT_EQ(updated, *recovered);
  EXPECT_FALSE(std::filesystem::exists(transaction_path / L"record.next"));
}

TEST(WindowsPortableTransactionIndex,
     ValidPairRejectsRecordRollbackAndImmutableBindingChanges) {
  const WindowsHelperPolicy policy = PortablePolicy('a', 'b');
  const std::string transaction_id = UniqueTransactionId();
  const std::string prepared =
      Record(policy, transaction_id, "prepared").EncodeCanonical();
  const std::string commit_accepted =
      Record(policy, transaction_id, "commitAccepted", "none",
             "launchPending")
          .EncodeCanonical();
  EXPECT_EQ(WindowsPortableValidPairDecision::kPromoteNext,
            DecideWindowsPortableRecordValidPair(
                policy, transaction_id, prepared, commit_accepted));
  EXPECT_EQ(WindowsPortableValidPairDecision::kReject,
            DecideWindowsPortableRecordValidPair(
                policy, transaction_id, commit_accepted, prepared));

  WindowsPersistentTransactionRecord changed =
      Record(policy, transaction_id, "commitAccepted", "none",
             "launchPending");
  ++changed.caller_process_start_identity;
  EXPECT_EQ(WindowsPortableValidPairDecision::kReject,
            DecideWindowsPortableRecordValidPair(
                policy, transaction_id, commit_accepted,
                changed.EncodeCanonical()));
}

TEST(WindowsPortableTransactionIndex,
     ValidPairAcceptsOnlyMonotonicResolverClaimUpdates) {
  const std::string transaction_id = UniqueTransactionId();
  const std::string claimed =
      Claim(transaction_id, 50, 70, 'A', "claimed").EncodeCanonical();
  const std::string consumed =
      Claim(transaction_id, 50, 70, 'A', "consumed").EncodeCanonical();
  const std::string takeover =
      Claim(transaction_id, 51, 70, 'B', "claimed").EncodeCanonical();
  const std::string changed_caller =
      Claim(transaction_id, 51, 71, 'B', "claimed").EncodeCanonical();

  EXPECT_EQ(WindowsPortableValidPairDecision::kPromoteNext,
            DecideWindowsPortableResolverClaimValidPair(
                transaction_id, claimed, consumed));
  EXPECT_EQ(WindowsPortableValidPairDecision::kPromoteNext,
            DecideWindowsPortableResolverClaimValidPair(
                transaction_id, claimed, takeover));
  EXPECT_EQ(WindowsPortableValidPairDecision::kReject,
            DecideWindowsPortableResolverClaimValidPair(
                transaction_id, consumed, takeover));
  EXPECT_EQ(WindowsPortableValidPairDecision::kReject,
            DecideWindowsPortableResolverClaimValidPair(
                transaction_id, claimed, changed_caller));
}

TEST(WindowsPortableTransactionIndex,
     FreshProcessAcceptsExactEmptyTransactionDirectoryAfterDeath) {
  const WindowsHelperPolicy policy = PortablePolicy('a', 'b');
  const std::string transaction_id = UniqueTransactionId();
  const std::filesystem::path transaction_path =
      TransactionPath(policy, transaction_id);
  ScopedTransactionCleanup cleanup(transaction_path);
  const std::string canonical =
      Record(policy, transaction_id, "preparing").EncodeCanonical();
  OneShotStoreFault fault(WindowsPortableTransactionStoreFaultPoint::
                              kAfterTransactionDirectoryCreate);

  {
    WindowsPortableTransactionStore store(policy, GetCurrentProcess(), true,
                                           &fault);
    EXPECT_THROW(store.CreateRecord(transaction_id, canonical),
                 std::runtime_error);
  }
  EXPECT_TRUE(std::filesystem::is_directory(transaction_path));
  EXPECT_FALSE(std::filesystem::exists(transaction_path / L"record.json"));
  EXPECT_FALSE(std::filesystem::exists(transaction_path / L"record.next"));

  WindowsPortableTransactionStore fresh(policy, GetCurrentProcess(), false);
  EXPECT_FALSE(fresh.ReadRecord(transaction_id).has_value());
}

TEST(WindowsPortableTransactionIndex,
     FrozenLocatorLetsTheVerifiedSuccessorResolveTheCommittedTransaction) {
  const WindowsHelperPolicy before = PortablePolicy('a', 'b');
  const WindowsHelperPolicy after = PortablePolicy('d', 'e');
  const std::string transaction_id = UniqueTransactionId();
  const auto endpoint = BuildPortableWindowsRecoveryHostEndpoint(
      std::filesystem::path(L"C:\\Users\\alice\\AppData\\Local"), before,
      before.helper_sha256(), std::string(64, 'f'),
      L"S-1-5-21-100-200-300-1001");
  const WindowsPortableTransactionLocatorV1 locator =
      BuildWindowsPortableTransactionLocator(transaction_id, before,
                                              endpoint);
  const std::string terminal =
      Record(before, transaction_id, "completed", "newTarget", "launched")
          .EncodeCanonical();
  const std::filesystem::path expected_executable =
      L"C:\\Users\\alice\\Example.app\\bin\\example.exe";
  VerifiedWindowsExecutable successor{
      true, L"Example Software LLC", after.application_signer_identity(),
      after.application_signer_identity(), expected_executable, false, 7, {}};

  ASSERT_NE(WindowsPortableIndexBindingKey(before),
            WindowsPortableIndexBindingKey(after));
  ASSERT_EQ(std::string(64, 'b'), locator.helper_sha256);
  EXPECT_EQ(WindowsPortableTransactionResolution::kVerifiedSuccessor,
            ResolveWindowsPortableTransactionAuthority(
                locator, before, transaction_id, terminal, successor,
                expected_executable, true));

  successor.sha256 = std::string(64, '9');
  EXPECT_EQ(WindowsPortableTransactionResolution::kReject,
            ResolveWindowsPortableTransactionAuthority(
                locator, before, transaction_id, terminal, successor,
                expected_executable, true));
  successor.sha256 = after.application_signer_identity();
  EXPECT_EQ(WindowsPortableTransactionResolution::kReject,
            ResolveWindowsPortableTransactionAuthority(
                locator, before, transaction_id, terminal, successor,
                expected_executable, false));
  EXPECT_EQ(WindowsPortableTransactionResolution::kReject,
            ResolveWindowsPortableTransactionAuthority(
                locator, before, transaction_id, terminal, successor,
                L"C:\\Users\\alice\\Elsewhere\\example.exe", true));
}

TEST(WindowsPortableTransactionIndex,
     FrozenLocatorRejectsAnotherPolicyOrEndpointGeneration) {
  const WindowsHelperPolicy frozen = PortablePolicy('a', 'b');
  const WindowsHelperPolicy another = PortablePolicy('d', 'e');
  const std::string transaction_id = UniqueTransactionId();
  const auto endpoint = BuildPortableWindowsRecoveryHostEndpoint(
      std::filesystem::path(L"C:\\Users\\alice\\AppData\\Local"), frozen,
      frozen.helper_sha256(), std::string(64, 'f'),
      L"S-1-5-21-100-200-300-1001");
  const WindowsPortableTransactionLocatorV1 locator =
      BuildWindowsPortableTransactionLocator(transaction_id, frozen,
                                              endpoint);
  const std::string terminal =
      Record(frozen, transaction_id, "completed", "newTarget", "launched")
          .EncodeCanonical();
  VerifiedWindowsExecutable successor{
      true, L"Example Software LLC", std::string(64, 'f'),
      std::string(64, 'd'),
      L"C:\\Users\\alice\\Example.app\\bin\\example.exe", false, 7, {}};

  EXPECT_EQ(locator, WindowsPortableTransactionLocatorV1::DecodeStrict(
                         locator.EncodeCanonical()));
  EXPECT_EQ(WindowsPortableTransactionResolution::kReject,
            ResolveWindowsPortableTransactionAuthority(
                locator, another, transaction_id, terminal, successor,
                successor.final_path, true));

  auto changed = locator;
  changed.helper_sha256 = another.helper_sha256();
  EXPECT_EQ(WindowsPortableTransactionResolution::kReject,
            ResolveWindowsPortableTransactionAuthority(
                changed, frozen, transaction_id, terminal, successor,
                successor.final_path, true));
}

}  // namespace
}  // namespace desktop_updater::helper
