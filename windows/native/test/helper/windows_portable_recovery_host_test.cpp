#include <gtest/gtest.h>

#include <windows.h>
#include <winternl.h>

#include <functional>
#include <filesystem>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include "windows_portable_recovery_host.h"
#include <sddl.h>
#include "windows_file_transaction.h"
#include "windows_recovery_service.h"

namespace desktop_updater::helper {
namespace {

constexpr char kTransactionId[] =
    "00000000-0000-4000-8000-000000000031";
constexpr wchar_t kUserSid[] = L"S-1-5-21-100-200-300-1001";

WindowsHelperPolicy PortablePolicy() {
  return WindowsHelperPolicy::ForPortableTesting(
      "com.example.app", std::string(64, 'a'), std::string(64, 'b'));
}

PortableWindowsRecoveryHostEndpointV1 Endpoint() {
  return BuildPortableWindowsRecoveryHostEndpoint(
      std::filesystem::path(L"C:\\Users\\alice\\AppData\\Local"),
      PortablePolicy(), std::string(64, 'b'), std::string(64, 'c'),
      kUserSid);
}

struct CurrentUserSid {
  std::vector<unsigned char> bytes;
  std::wstring text;
};

CurrentUserSid ReadCurrentUserSid() {
  HANDLE raw_token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &raw_token)) {
    throw std::runtime_error("current token unavailable");
  }
  UniqueWindowsHandle token(raw_token);
  DWORD size = 0;
  (void)GetTokenInformation(token.get(), TokenUser, nullptr, 0, &size);
  if (size == 0 || GetLastError() != ERROR_INSUFFICIENT_BUFFER) {
    throw std::runtime_error("current SID size unavailable");
  }
  std::vector<unsigned char> token_bytes(size);
  if (!GetTokenInformation(token.get(), TokenUser, token_bytes.data(), size,
                           &size)) {
    throw std::runtime_error("current SID unavailable");
  }
  const auto* user = reinterpret_cast<const TOKEN_USER*>(token_bytes.data());
  const DWORD sid_size = GetLengthSid(user->User.Sid);
  CurrentUserSid result;
  result.bytes.resize(sid_size);
  if (!CopySid(sid_size, result.bytes.data(), user->User.Sid)) {
    throw std::runtime_error("current SID copy failed");
  }
  LPWSTR raw_text = nullptr;
  if (!ConvertSidToStringSidW(result.bytes.data(), &raw_text) ||
      raw_text == nullptr) {
    throw std::runtime_error("current SID text unavailable");
  }
  result.text = raw_text;
  LocalFree(raw_text);
  return result;
}

TEST(WindowsPortableRecoveryHost, EndpointIsVersionAndDigestAddressed) {
  const auto endpoint = Endpoint();

  EXPECT_EQ(PortableWindowsRecoveryHostEndpointV1::kSchemaVersion,
            endpoint.schema_version);
  EXPECT_EQ(kUserSid, endpoint.user_sid);
  EXPECT_EQ(std::string(64, 'b'), endpoint.helper_sha256);
  EXPECT_EQ(std::string(64, 'c'), endpoint.policy_sha256);
  EXPECT_EQ(L"desktop_updater_install_helper.exe",
            endpoint.helper_path.filename().wstring());
  EXPECT_EQ(L"desktop_updater_helper_policy.json",
            endpoint.policy_path.filename().wstring());
  EXPECT_EQ(endpoint.helper_path.parent_path(),
            endpoint.policy_path.parent_path());
  EXPECT_NE(std::wstring::npos,
            endpoint.helper_path.wstring().find(
                L"desktop_updater_portable_recovery_host_v1"));
  EXPECT_NE(std::wstring::npos,
            endpoint.helper_path.wstring().find(std::wstring(64, L'b')));
  EXPECT_EQ(std::wstring::npos,
            endpoint.helper_path.wstring().find(std::wstring(64, L'c')));
  EXPECT_LT(endpoint.helper_path.wstring().size(), 260u);
  EXPECT_EQ(std::wstring::npos,
            endpoint.helper_path.wstring().find(L"Program Files"));
}

TEST(WindowsPortableRecoveryHost, EndpointRejectsAuthorityMismatch) {
  auto protected_policy = WindowsHelperPolicy::ForTesting(
      "com.example.app", "Example Publisher", "Example Publisher",
      std::string(64, 'b'), {L"C:\\Program Files\\Example"});
  EXPECT_THROW(BuildPortableWindowsRecoveryHostEndpoint(
                   std::filesystem::path(
                       L"C:\\Users\\alice\\AppData\\Local"),
                   protected_policy, std::string(64, 'b'),
                   std::string(64, 'c'), kUserSid),
               WindowsPortableRecoveryHostError);
  EXPECT_THROW(BuildPortableWindowsRecoveryHostEndpoint(
                   std::filesystem::path(
                       L"C:\\Users\\alice\\AppData\\Local"),
                   PortablePolicy(), std::string(64, 'd'),
                   std::string(64, 'c'), kUserSid),
               WindowsPortableRecoveryHostError);
  EXPECT_THROW(BuildPortableWindowsRecoveryHostEndpoint(
                   std::filesystem::path(
                       L"C:\\Users\\alice\\AppData\\Local"),
                   PortablePolicy(), std::string(64, 'b'),
                   std::string(64, 'c'), L"S-1-5-18"),
               WindowsPortableRecoveryHostError);
}

TEST(WindowsPortableRecoveryHost,
     AlreadyStableBootstrapSourceIsReusedOnlyAtTheExactFrozenEndpoint) {
  const auto endpoint = Endpoint();

  EXPECT_EQ(PortableWindowsRecoveryHostSourceDecision::kReuseExactStable,
            DecidePortableWindowsRecoveryHostSource(
                endpoint, endpoint.helper_path, endpoint.policy_path));
  EXPECT_EQ(PortableWindowsRecoveryHostSourceDecision::kProvisionExternal,
            DecidePortableWindowsRecoveryHostSource(
                endpoint,
                std::filesystem::path(
                    L"C:\\Users\\alice\\Apps\\Example\\"
                    L"desktop_updater_install_helper.exe"),
                std::filesystem::path(
                    L"C:\\Users\\alice\\Apps\\Example\\"
                    L"desktop_updater_helper_policy.json")));
  EXPECT_EQ(PortableWindowsRecoveryHostSourceDecision::kReject,
            DecidePortableWindowsRecoveryHostSource(
                endpoint, endpoint.helper_path,
                std::filesystem::path(
                    L"C:\\Users\\alice\\Apps\\Example\\"
                    L"desktop_updater_helper_policy.json")));
  EXPECT_EQ(PortableWindowsRecoveryHostSourceDecision::kReject,
            DecidePortableWindowsRecoveryHostSource(
                endpoint,
                endpoint.endpoint_path / L"attacker-controlled-helper.exe",
                endpoint.policy_path));
}

TEST(WindowsPortableRecoveryHost, EndpointMustStayOutsideTargetAndStage) {
  const auto endpoint = Endpoint();
  EXPECT_NO_THROW(RequirePortableWindowsRecoveryHostOutsideMutationRoots(
      endpoint,
      std::filesystem::path(L"C:\\Users\\alice\\Apps\\Example"),
      std::filesystem::path(L"C:\\Users\\alice\\Temp\\stage")));
  EXPECT_THROW(RequirePortableWindowsRecoveryHostOutsideMutationRoots(
                   endpoint,
                   std::filesystem::path(
                       L"C:\\Users\\alice\\AppData\\Local"),
                   std::filesystem::path(
                       L"C:\\Users\\alice\\Temp\\stage")),
               WindowsPortableRecoveryHostError);
  EXPECT_THROW(RequirePortableWindowsRecoveryHostOutsideMutationRoots(
                   endpoint,
                   std::filesystem::path(
                       L"C:\\Users\\alice\\Apps\\Example"),
                   endpoint.endpoint_path.parent_path()),
               WindowsPortableRecoveryHostError);
}

TEST(WindowsPortableRecoveryHost,
     TaskUsesExactInteractiveUserAndFixedRecoveryArguments) {
  const auto definition = BuildPortableWindowsRecoveryHostTaskDefinition(
      Endpoint(), kTransactionId, std::string(43, 'A'));

  EXPECT_EQ(kUserSid, definition.principal_user_id);
  EXPECT_EQ(TASK_LOGON_INTERACTIVE_TOKEN, definition.logon_type);
  EXPECT_EQ(TASK_RUNLEVEL_LUA, definition.run_level);
  EXPECT_EQ(TASK_TRIGGER_LOGON, definition.trigger_type);
  EXPECT_EQ(L"PT0M", definition.trigger_delay);
  EXPECT_TRUE(definition.trigger_start_boundary.empty());
  EXPECT_TRUE(definition.trigger_end_boundary.empty());
  EXPECT_EQ(TASK_CREATE | TASK_DONT_ADD_PRINCIPAL_ACE,
            definition.registration_flags);
  EXPECT_EQ(kPortableWindowsTaskRunAsSelf, definition.run_flags);
  EXPECT_EQ(Endpoint().helper_path, definition.executable_path);
  EXPECT_EQ(
      L"--portable-recover-current 00000000-0000-4000-8000-000000000031",
      definition.arguments);
  EXPECT_NE(std::wstring::npos,
            definition.security_descriptor.find(kUserSid));
  EXPECT_NE(std::wstring::npos,
            definition.security_descriptor.find(L";;;SY)"));
  EXPECT_EQ(std::wstring::npos,
            definition.security_descriptor.find(L";;;BA)"));
  EXPECT_EQ(std::wstring::npos,
            definition.arguments.find(L"--target"));
  EXPECT_EQ(std::wstring::npos,
            definition.arguments.find(L"--policy"));
  EXPECT_EQ(std::wstring::npos,
            definition.arguments.find(L"powershell"));
  EXPECT_EQ(std::wstring::npos,
            definition.arguments.find(L"RunOnce"));
}

TEST(WindowsPortableRecoveryHost, TokenAuthorityRejectsSystemOrElevation) {
  EXPECT_NO_THROW(RequirePortableWindowsRecoveryTokenAuthority(
      kUserSid, kUserSid, false, false));
  EXPECT_THROW(RequirePortableWindowsRecoveryTokenAuthority(
                   kUserSid, L"S-1-5-21-100-200-300-1002", false, false),
               WindowsPortableRecoveryHostError);
  EXPECT_THROW(RequirePortableWindowsRecoveryTokenAuthority(
                   kUserSid, kUserSid, true, false),
               WindowsPortableRecoveryHostError);
  EXPECT_THROW(RequirePortableWindowsRecoveryTokenAuthority(
                   kUserSid, kUserSid, false, true),
               WindowsPortableRecoveryHostError);
}

TEST(WindowsPortableRecoveryHost, ExactAclFactsRejectExtraMasksAndFlags) {
  const DWORD inherited = OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE;
  const std::vector<PortableWindowsRecoveryAclAceFacts> exact = {
      {kUserSid, FILE_ALL_ACCESS, inherited, true},
      {L"S-1-5-18", FILE_ALL_ACCESS, inherited, true},
  };
  EXPECT_NO_THROW(ValidatePortableWindowsRecoveryExactAclFacts(
      kUserSid, kUserSid, kUserSid, true, FILE_ALL_ACCESS, inherited,
      exact));

  auto extra_mask = exact;
  extra_mask.front().mask |= GENERIC_ALL;
  EXPECT_THROW(ValidatePortableWindowsRecoveryExactAclFacts(
                   kUserSid, kUserSid, kUserSid, true, FILE_ALL_ACCESS,
                   inherited, extra_mask),
               WindowsPortableRecoveryHostError);

  auto inherit_only = exact;
  inherit_only.front().flags |= INHERIT_ONLY_ACE;
  EXPECT_THROW(ValidatePortableWindowsRecoveryExactAclFacts(
                   kUserSid, kUserSid, kUserSid, true, FILE_ALL_ACCESS,
                   inherited, inherit_only),
               WindowsPortableRecoveryHostError);

  auto another_user = exact;
  another_user.push_back(
      {L"S-1-5-21-100-200-300-1002", FILE_ALL_ACCESS, inherited, true});
  EXPECT_THROW(ValidatePortableWindowsRecoveryExactAclFacts(
                   kUserSid, kUserSid, kUserSid, true, FILE_ALL_ACCESS,
                   inherited, another_user),
               WindowsPortableRecoveryHostError);

  auto deny = exact;
  deny.front().allowed = false;
  EXPECT_THROW(ValidatePortableWindowsRecoveryExactAclFacts(
                   kUserSid, kUserSid, kUserSid, true, FILE_ALL_ACCESS,
                   inherited, deny),
               WindowsPortableRecoveryHostError);
}

TEST(WindowsPortableRecoveryHost, TaskAclRejectsUnexpectedAceFlags) {
  const std::vector<PortableWindowsRecoveryAclAceFacts> exact = {
      {kUserSid, GENERIC_ALL, 0, true},
      {L"S-1-5-18", GENERIC_ALL, 0, true},
  };
  EXPECT_NO_THROW(ValidatePortableWindowsRecoveryExactAclFacts(
      kUserSid, kUserSid, kUserSid, true, GENERIC_ALL, 0, exact));
  auto inherited = exact;
  inherited.back().flags = INHERITED_ACE;
  EXPECT_THROW(ValidatePortableWindowsRecoveryExactAclFacts(
                   kUserSid, kUserSid, kUserSid, true, GENERIC_ALL, 0,
                   inherited),
               WindowsPortableRecoveryHostError);
}

TEST(WindowsPortableRecoveryHost, RetainedSourceHandleMustMatchVerifiedFile) {
  VerifiedWindowsExecutable expected{};
  expected.sha256 = std::string(64, 'a');
  expected.final_path = std::filesystem::path(
      L"C:\\Users\\alice\\Apps\\Example\\desktop_updater_install_helper.exe");
  expected.volume_serial = 42;
  expected.file_id.fill(7);
  WindowsFileIdentity observed{};
  observed.volume_serial = expected.volume_serial;
  observed.file_id = expected.file_id;
  observed.number_of_links = 1;
  EXPECT_NO_THROW(ValidatePortableWindowsRetainedHelperFacts(
      expected, observed, expected.sha256, expected.final_path));

  observed.file_id[0] = 8;
  EXPECT_THROW(ValidatePortableWindowsRetainedHelperFacts(
                   expected, observed, expected.sha256, expected.final_path),
               WindowsPortableRecoveryHostError);
  observed.file_id = expected.file_id;
  EXPECT_THROW(ValidatePortableWindowsRetainedHelperFacts(
                   expected, observed, std::string(64, 'b'),
                   expected.final_path),
               WindowsPortableRecoveryHostError);
}

TEST(WindowsPortableRecoveryHost,
     CrashLeftPartialEndpointIsRecreatedButUnsafeEndpointIsRejected) {
  EXPECT_EQ(PortableWindowsStableEndpointDecision::kCreate,
            DecidePortableWindowsStableEndpoint(
                PortableWindowsStableEndpointProbe::kMissing));
  EXPECT_EQ(PortableWindowsStableEndpointDecision::kReuse,
            DecidePortableWindowsStableEndpoint(
                PortableWindowsStableEndpointProbe::kExact));
  EXPECT_EQ(PortableWindowsStableEndpointDecision::kQuarantineAndRecreate,
            DecidePortableWindowsStableEndpoint(
                PortableWindowsStableEndpointProbe::kIncompleteSecure));
  EXPECT_EQ(PortableWindowsStableEndpointDecision::kReject,
            DecidePortableWindowsStableEndpoint(
                PortableWindowsStableEndpointProbe::kUnsafe));
}

TEST(WindowsPortableRecoveryHost,
     StableArtifactsAreExactUserSecuredBeforeCreateReturns) {
  const std::filesystem::path root =
      std::filesystem::temp_directory_path() /
      (L"desktop-updater-portable-atomic-host-" +
       std::to_wstring(GetCurrentProcessId()) + L"-" +
       std::to_wstring(GetTickCount64()));
  struct Cleanup {
    std::filesystem::path root;
    ~Cleanup() {
      std::error_code ignored;
      std::filesystem::remove_all(root, ignored);
    }
  } cleanup{root};
  std::filesystem::create_directories(root);
  UniqueWindowsHandle parent(CreateFileW(
      root.c_str(),
      FILE_LIST_DIRECTORY | FILE_ADD_SUBDIRECTORY | FILE_ADD_FILE |
          FILE_READ_ATTRIBUTES | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  ASSERT_TRUE(parent.valid());
  CurrentUserSid user = ReadCurrentUserSid();

  try {
    auto endpoint = CreatePortableWindowsExactUserDirectory(
        parent.get(), L"endpoint",
        FILE_LIST_DIRECTORY | FILE_ADD_FILE | FILE_ADD_SUBDIRECTORY |
            FILE_READ_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT,
        FILE_ATTRIBUTE_HIDDEN, user.bytes.data(), user.text);
    throw std::runtime_error("simulated death after atomic directory create");
  } catch (const std::runtime_error&) {
  }
  auto endpoint = OpenRelativeNoReparse(
      parent.get(), L"endpoint",
      FILE_LIST_DIRECTORY | FILE_ADD_FILE | FILE_READ_ATTRIBUTES |
          READ_CONTROL | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, FILE_OPEN,
      FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
  EXPECT_NO_THROW(ValidatePortableWindowsExactUserSecurity(
      endpoint.get(), user.bytes.data(), true));

  try {
    auto policy = CreatePortableWindowsExactUserFile(
        endpoint.get(), L"policy.json",
        GENERIC_READ | GENERIC_WRITE | FILE_READ_ATTRIBUTES | READ_CONTROL |
            SYNCHRONIZE,
        FILE_SHARE_READ | FILE_SHARE_DELETE,
        FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT |
            FILE_WRITE_THROUGH,
        FILE_ATTRIBUTE_HIDDEN, user.bytes.data(), user.text);
    throw std::runtime_error("simulated death after atomic file create");
  } catch (const std::runtime_error&) {
  }
  auto policy = OpenRelativeNoReparse(
      endpoint.get(), L"policy.json",
      GENERIC_READ | FILE_READ_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_DELETE, FILE_OPEN,
      FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
  EXPECT_NO_THROW(ValidatePortableWindowsExactUserSecurity(
      policy.get(), user.bytes.data(), false));
  EXPECT_EQ(1U, ReadWindowsFileIdentity(policy.get()).number_of_links);
  LARGE_INTEGER size{};
  ASSERT_TRUE(GetFileSizeEx(policy.get(), &size));
  EXPECT_EQ(0, size.QuadPart);
}

TEST(WindowsPortableRecoveryHost,
     ExistingExactTaskIsReusedButMismatchedTaskIsNeverOverwritten) {
  EXPECT_EQ(PortableWindowsRecoveryTaskRegistrationDecision::kRegisterNew,
            DecidePortableWindowsRecoveryTaskRegistration(
                PortableWindowsRecoveryTaskProbe::kMissing));
  EXPECT_EQ(PortableWindowsRecoveryTaskRegistrationDecision::kReuseExact,
            DecidePortableWindowsRecoveryTaskRegistration(
                PortableWindowsRecoveryTaskProbe::kExact));
  EXPECT_EQ(PortableWindowsRecoveryTaskRegistrationDecision::kReject,
            DecidePortableWindowsRecoveryTaskRegistration(
                PortableWindowsRecoveryTaskProbe::kMismatch));
}

TEST(WindowsPortableRecoveryHost,
     TaskReuseRequiresEveryEnabledSettingsAndTriggerSemantic) {
  PortableWindowsRecoveryTaskSemanticFacts exact{
      true, true, true, true, false, false,
      TASK_INSTANCES_IGNORE_NEW, L"PT0S", true, L"PT0M", L"", L""};
  EXPECT_NO_THROW(ValidatePortableWindowsRecoveryTaskSemanticFacts(exact));

  auto mismatch = exact;
  mismatch.registered_enabled = false;
  EXPECT_THROW(ValidatePortableWindowsRecoveryTaskSemanticFacts(mismatch),
               WindowsPortableRecoveryHostError);
  mismatch = exact;
  mismatch.settings_enabled = false;
  EXPECT_THROW(ValidatePortableWindowsRecoveryTaskSemanticFacts(mismatch),
               WindowsPortableRecoveryHostError);
  mismatch = exact;
  mismatch.allow_demand_start = false;
  EXPECT_THROW(ValidatePortableWindowsRecoveryTaskSemanticFacts(mismatch),
               WindowsPortableRecoveryHostError);
  mismatch = exact;
  mismatch.start_when_available = false;
  EXPECT_THROW(ValidatePortableWindowsRecoveryTaskSemanticFacts(mismatch),
               WindowsPortableRecoveryHostError);
  mismatch = exact;
  mismatch.disallow_start_if_on_batteries = true;
  EXPECT_THROW(ValidatePortableWindowsRecoveryTaskSemanticFacts(mismatch),
               WindowsPortableRecoveryHostError);
  mismatch = exact;
  mismatch.stop_if_going_on_batteries = true;
  EXPECT_THROW(ValidatePortableWindowsRecoveryTaskSemanticFacts(mismatch),
               WindowsPortableRecoveryHostError);
  mismatch = exact;
  mismatch.multiple_instances = TASK_INSTANCES_PARALLEL;
  EXPECT_THROW(ValidatePortableWindowsRecoveryTaskSemanticFacts(mismatch),
               WindowsPortableRecoveryHostError);
  mismatch = exact;
  mismatch.execution_time_limit = L"PT72H";
  EXPECT_THROW(ValidatePortableWindowsRecoveryTaskSemanticFacts(mismatch),
               WindowsPortableRecoveryHostError);
  mismatch = exact;
  mismatch.trigger_enabled = false;
  EXPECT_THROW(ValidatePortableWindowsRecoveryTaskSemanticFacts(mismatch),
               WindowsPortableRecoveryHostError);
  mismatch = exact;
  mismatch.trigger_delay = L"PT5M";
  EXPECT_THROW(ValidatePortableWindowsRecoveryTaskSemanticFacts(mismatch),
               WindowsPortableRecoveryHostError);
  mismatch = exact;
  mismatch.trigger_delay.clear();
  EXPECT_NO_THROW(ValidatePortableWindowsRecoveryTaskSemanticFacts(mismatch));
  mismatch = exact;
  mismatch.trigger_start_boundary = L"2026-07-16T12:00:00Z";
  EXPECT_THROW(ValidatePortableWindowsRecoveryTaskSemanticFacts(mismatch),
               WindowsPortableRecoveryHostError);
  mismatch = exact;
  mismatch.trigger_end_boundary = L"2026-07-16T13:00:00Z";
  EXPECT_THROW(ValidatePortableWindowsRecoveryTaskSemanticFacts(mismatch),
               WindowsPortableRecoveryHostError);
}

TEST(WindowsPortableRecoveryHost,
     PrepareBoundaryArmsAndReadsBackBeforeAnyMutation) {
  std::vector<std::string> order;
  const std::string journal = RunPortableWindowsRecoveryPrepareBoundary(
      [&]() { order.push_back("persist"); },
      [&]() { order.push_back("arm-and-readback"); },
      [&]() {
        order.push_back("mutate");
        return "prepared-journal";
      });

  EXPECT_EQ("prepared-journal", journal);
  EXPECT_EQ((std::vector<std::string>{"persist", "arm-and-readback",
                                      "mutate"}),
            order);
}

TEST(WindowsPortableRecoveryHost,
     PrepareBoundaryFailsClosedWhenTaskCannotBeReadBack) {
  bool mutated = false;
  EXPECT_THROW(
      RunPortableWindowsRecoveryPrepareBoundary(
          []() {},
          []() { throw std::runtime_error("task readback mismatch"); },
          [&]() {
            mutated = true;
            return std::string("prepared-journal");
          }),
      std::runtime_error);
  EXPECT_FALSE(mutated);
}

TEST(WindowsPortableRecoveryHost, DisarmsOnlyForVerifiedTerminalOutcomes) {
  EXPECT_TRUE(ShouldDisarmPortableWindowsRecoveryHost("completed",
                                                       "newTarget"));
  EXPECT_TRUE(ShouldDisarmPortableWindowsRecoveryHost("rolledBack",
                                                       "oldTarget"));
  EXPECT_TRUE(ShouldDisarmPortableWindowsRecoveryHost("relaunchFailure",
                                                       "newTarget"));
  EXPECT_FALSE(ShouldDisarmPortableWindowsRecoveryHost("recoveryRequired",
                                                        "none"));
  EXPECT_FALSE(ShouldDisarmPortableWindowsRecoveryHost("helperUnavailable",
                                                        "none"));
  EXPECT_FALSE(ShouldDisarmPortableWindowsRecoveryHost(
      "manualActionRequired", "none"));
  EXPECT_FALSE(ShouldDisarmPortableWindowsRecoveryHost("completed",
                                                        "oldTarget"));
}

TEST(WindowsPortableRecoveryHost,
     StableTaskConvergesAfterSimulatedDeathFollowingBackupRename) {
  struct SharedTaskState {
    bool armed = false;
    bool disarmed = false;
  } task;
  class FakeController final : public PortableWindowsRecoveryHostController {
   public:
    explicit FakeController(SharedTaskState* state) : state_(state) {}
    void ArmAndStart(const PortableWindowsRecoveryHostTaskDefinition&,
                     DWORD) override {
      state_->armed = true;
    }
    void Disarm(
        const PortableWindowsRecoveryHostTaskDefinition&) override {
      state_->armed = false;
      state_->disarmed = true;
    }

   private:
    SharedTaskState* state_;
  } controller(&task);

  const auto definition = BuildPortableWindowsRecoveryHostTaskDefinition(
      Endpoint(), kTransactionId, std::string(43, 'A'));
  std::string durable_state;
  std::string target_contents = "old-target";
  try {
    (void)RunPortableWindowsRecoveryPrepareBoundary(
        [&]() { durable_state = "preparing"; },
        [&]() { controller.ArmAndStart(definition, 30'000); },
        [&]() -> std::string {
          target_contents.clear();
          durable_state = "backupCreated";
          throw std::runtime_error("simulated process death");
        });
    FAIL() << "simulated process death was not observed";
  } catch (const std::runtime_error&) {
  }

  ASSERT_TRUE(task.armed);
  ASSERT_FALSE(task.disarmed);
  ASSERT_EQ("backupCreated", durable_state);
  ASSERT_TRUE(target_contents.empty());

  // A fresh process at the next exact-user logon uses the durable portable
  // index and the stable host, not any path or argument from the dead caller.
  const auto recovered = RunPortableWindowsAutonomousRecoveryBoundary(
      controller, definition, [&]() {
        EXPECT_EQ("backupCreated", durable_state);
        durable_state = "completed";
        target_contents = "new-target";
        return PortableWindowsRecoveryResolution{"completed", "newTarget"};
      });

  EXPECT_EQ("completed", recovered.result_code);
  EXPECT_EQ("newTarget", recovered.verified_outcome);
  EXPECT_EQ("completed", durable_state);
  EXPECT_EQ("new-target", target_contents);
  EXPECT_FALSE(task.armed);
  EXPECT_TRUE(task.disarmed);
}

WindowsVerifiedPayloadIdentity RecoveryPayload(const std::string& version) {
  const char digest = version == "new" ? 'b' : 'a';
  return {"com.example.app", "Example Software LLC",
          std::string(64, digest), std::string(64, 'c'),
          std::string(64, 'd'), L"bin\\example.exe",
          std::string(64, 'e'), std::string(64, 'f')};
}

class RecoveryPayloadVerifier final : public WindowsInstallPayloadVerifier {
 public:
  WindowsVerifiedPayloadIdentity Verify(HANDLE parent,
                                        const std::wstring& leaf) override {
    return RecoveryPayload(
        ReadUtf8FileRelative(parent, leaf + L"\\version.txt", 32));
  }
};

class DeathAfterBackupFault final : public WindowsTransactionFaultInjector {
 public:
  void Hit(WindowsTransactionFaultPoint point) override {
    if (!hit_ && point == WindowsTransactionFaultPoint::kAfterBackupRename) {
      hit_ = true;
      throw WindowsFileTransactionError(
          WindowsFileTransactionError::Code::kInjectedFailure,
          "simulated process death after durable backup rename");
    }
  }

 private:
  bool hit_ = false;
};

class DeadRecoveryOwner final : public WindowsProcessLivenessChecker {
 public:
  bool IsSameProcessAlive(DWORD, std::uint64_t) override { return false; }
};

class RecordingPortableRecoveryController final
    : public PortableWindowsRecoveryHostController {
 public:
  void ArmAndStart(const PortableWindowsRecoveryHostTaskDefinition&,
                   DWORD) override {
    armed = true;
  }
  void Disarm(const PortableWindowsRecoveryHostTaskDefinition&) override {
    armed = false;
    disarmed = true;
  }

  bool armed = false;
  bool disarmed = false;
};

TEST(WindowsPortableRecoveryHost,
     RealFileTransactionConvergesInFreshServiceAfterBackupDeath) {
  const std::filesystem::path root =
      std::filesystem::temp_directory_path() /
      (L"desktop-updater-portable-real-recovery-" +
       std::to_wstring(GetCurrentProcessId()) + L"-" +
       std::to_wstring(GetTickCount64()));
  struct Cleanup {
    std::filesystem::path root;
    ~Cleanup() {
      std::error_code ignored;
      std::filesystem::remove_all(root, ignored);
    }
  } cleanup{root};
  const std::filesystem::path target = root / L"Example.app";
  const std::filesystem::path stage = root / L"Stage.app";
  std::filesystem::create_directories(target);
  std::filesystem::create_directories(stage);
  std::ofstream(target / L"version.txt", std::ios::binary) << "old";
  std::ofstream(stage / L"version.txt", std::ios::binary) << "new";

  RecoveryPayloadVerifier verifier;
  DeathAfterBackupFault fault;
  auto transaction = std::make_unique<WindowsFileTransaction>(
      target, stage, kTransactionId, GetCurrentProcessId(),
      RecoveryPayload("new"), verifier, &fault);
  RecordingPortableRecoveryController controller;
  const auto definition = BuildPortableWindowsRecoveryHostTaskDefinition(
      Endpoint(), kTransactionId, std::string(43, 'A'));
  bool preparing_persisted = false;
  const std::string prepared = RunPortableWindowsRecoveryPrepareBoundary(
      [&]() { preparing_persisted = true; },
      [&]() { controller.ArmAndStart(definition, 30'000); },
      [&]() {
        transaction->Prepare();
        return transaction->prepared_journal_canonical();
      });
  ASSERT_TRUE(preparing_persisted);
  ASSERT_TRUE(controller.armed);
  ASSERT_FALSE(prepared.empty());
  transaction->MarkCommitAccepted();
  EXPECT_THROW(transaction->ExecutePrepared(), WindowsFileTransactionError);
  ASSERT_FALSE(std::filesystem::exists(target));
  const WindowsTransactionPaths paths = transaction->paths();
  ASSERT_TRUE(std::filesystem::exists(root / paths.backup_name));

  // Dropping the transaction object models abrupt helper death: its durable
  // journal and lock remain. A newly constructed service owns convergence.
  transaction.reset();
  DeadRecoveryOwner dead;
  WindowsRecoveryService fresh(
      target, kTransactionId, RecoveryPayload("new"), verifier, dead,
      WindowsRecoveryIntent::kCompleteCommitted);
  const auto resolution = RunPortableWindowsAutonomousRecoveryBoundary(
      controller, definition, [&]() {
        EXPECT_EQ(WindowsRecoveryOutcome::kRecovered, fresh.Recover());
        return PortableWindowsRecoveryResolution{"completed", "newTarget"};
      });

  EXPECT_EQ("completed", resolution.result_code);
  EXPECT_EQ("newTarget", resolution.verified_outcome);
  EXPECT_FALSE(controller.armed);
  EXPECT_TRUE(controller.disarmed);
  std::ifstream input(target / L"version.txt", std::ios::binary);
  EXPECT_EQ("new", std::string(std::istreambuf_iterator<char>(input),
                                std::istreambuf_iterator<char>()));
  EXPECT_TRUE(FindWindowsTransactionArtifacts(root).empty());
}

}  // namespace
}  // namespace desktop_updater::helper
