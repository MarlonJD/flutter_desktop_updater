#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_PORTABLE_RECOVERY_HOST_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_PORTABLE_RECOVERY_HOST_H_

#include <windows.h>
#include <taskschd.h>

#include <cstdint>
#include <filesystem>
#include <functional>
#include <stdexcept>
#include <string>
#include <vector>

#include "helper_authenticode.h"
#include "helper_policy_windows.h"
#include "windows_portable_user_storage.h"
#include "windows_transaction_journal.h"

namespace desktop_updater::helper {

inline constexpr LONG kPortableWindowsTaskRunAsSelf = 0x1;

// Portable preparation includes Task Scheduler registration/readback and
// starting an already-validated exact-token recovery host. Keep this budget
// bounded, but separate it from the 30-second protected/elevated handshake so
// slow Windows ARM64 hosts do not time out after all authorization checks have
// succeeded.
inline constexpr DWORD kPortableWindowsHelperStartupTimeoutMilliseconds =
    90 * 1000;

class WindowsPortableRecoveryHostError : public std::runtime_error {
 public:
  explicit WindowsPortableRecoveryHostError(const std::string& detail)
      : std::runtime_error(detail) {}
};

struct PortableWindowsRecoveryHostEndpointV1 {
  static constexpr std::int64_t kSchemaVersion = 1;

  std::int64_t schema_version = kSchemaVersion;
  std::string policy_id;
  std::string package_id;
  std::wstring user_sid;
  std::string binding_sha256;
  std::string helper_sha256;
  std::string policy_sha256;
  std::filesystem::path local_app_data_path;
  std::filesystem::path endpoint_path;
  std::filesystem::path helper_path;
  std::filesystem::path policy_path;
};

PortableWindowsRecoveryHostEndpointV1
BuildPortableWindowsRecoveryHostEndpoint(
    const std::filesystem::path& local_app_data_path,
    const WindowsHelperPolicy& policy,
    const std::string& helper_sha256,
    const std::string& policy_sha256,
    const std::wstring& user_sid);

enum class PortableWindowsRecoveryHostSourceDecision {
  kProvisionExternal,
  kReuseExactStable,
  kReject,
};

PortableWindowsRecoveryHostSourceDecision
DecidePortableWindowsRecoveryHostSource(
    const PortableWindowsRecoveryHostEndpointV1& endpoint,
    const std::filesystem::path& verified_source_helper_path,
    const std::filesystem::path& verified_source_policy_path);

void RequirePortableWindowsRecoveryHostOutsideMutationRoots(
    const PortableWindowsRecoveryHostEndpointV1& endpoint,
    const std::filesystem::path& target_path,
    const std::filesystem::path& stage_path);

struct PortableWindowsRecoveryHostBootstrap {
  WindowsHelperPolicy policy;
  VerifiedWindowsExecutable helper_identity;
  PortableWindowsRecoveryHostEndpointV1 endpoint;
};

class PortableWindowsRecoveryHostController;

// Copies the already-authenticated portable helper and its canonical sealed
// policy into a stable per-user, version/hash-addressed LocalAppData endpoint.
// Existing endpoints are reused only after no-reparse, DACL, digest and
// Authenticode readback succeeds.
PortableWindowsRecoveryHostEndpointV1 ProvisionPortableWindowsRecoveryHost(
    const WindowsHelperPolicy& policy,
    const VerifiedWindowsExecutable& source_helper_identity,
    HANDLE source_helper_file,
    HANDLE source_policy_file,
    HANDLE authenticated_caller_process);

// Loads only a previously provisioned stable endpoint for the exact current
// user. This rejects elevated/SYSTEM tokens, reparse traversal, unexpected
// ACLs, and helper/policy identity drift.
PortableWindowsRecoveryHostBootstrap
LoadPortableWindowsRecoveryHostBootstrap();

void ValidateCurrentPortableWindowsRecoveryHost(
    const WindowsHelperPolicy& expected_policy);

struct PortableWindowsRecoveryHostTaskDefinition {
  std::string transaction_id;
  std::string recovery_ready_nonce;
  std::wstring task_path;
  std::wstring ready_event_name;
  std::filesystem::path executable_path;
  std::wstring arguments;
  std::wstring security_descriptor;
  std::wstring principal_user_id;
  TASK_LOGON_TYPE logon_type;
  TASK_RUNLEVEL_TYPE run_level;
  TASK_TRIGGER_TYPE2 trigger_type;
  std::wstring trigger_delay;
  std::wstring trigger_start_boundary;
  std::wstring trigger_end_boundary;
  LONG registration_flags;
  LONG run_flags;
};

PortableWindowsRecoveryHostTaskDefinition
BuildPortableWindowsRecoveryHostTaskDefinition(
    const PortableWindowsRecoveryHostEndpointV1& endpoint,
    const std::string& transaction_id,
    const std::string& recovery_ready_nonce);

void RequirePortableWindowsRecoveryTokenAuthority(
    const std::wstring& expected_user_sid,
    const std::wstring& actual_user_sid,
    bool elevated,
    bool local_system);

using PortableWindowsRecoveryAclAceFacts =
    PortableWindowsExactUserAclAceFacts;

void ValidatePortableWindowsRecoveryExactAclFacts(
    const std::wstring& expected_user_sid,
    const std::wstring& owner_sid,
    const std::wstring& group_sid,
    bool dacl_protected,
    DWORD expected_mask,
    BYTE expected_flags,
    const std::vector<PortableWindowsRecoveryAclAceFacts>& aces);

void ValidatePortableWindowsRetainedHelperFacts(
    const VerifiedWindowsExecutable& expected,
    const WindowsFileIdentity& observed,
    const std::string& observed_sha256,
    const std::filesystem::path& observed_final_path);

enum class PortableWindowsStableEndpointProbe {
  kMissing,
  kExact,
  kIncompleteSecure,
  kUnsafe,
};

enum class PortableWindowsStableEndpointDecision {
  kCreate,
  kReuse,
  kQuarantineAndRecreate,
  kReject,
};

PortableWindowsStableEndpointDecision DecidePortableWindowsStableEndpoint(
    PortableWindowsStableEndpointProbe probe);

enum class PortableWindowsRecoveryTaskProbe {
  kMissing,
  kExact,
  kMismatch,
};

enum class PortableWindowsRecoveryTaskRegistrationDecision {
  kRegisterNew,
  kReuseExact,
  kReject,
};

PortableWindowsRecoveryTaskRegistrationDecision
DecidePortableWindowsRecoveryTaskRegistration(
    PortableWindowsRecoveryTaskProbe probe);

struct PortableWindowsRecoveryTaskSemanticFacts {
  bool registered_enabled = false;
  bool settings_enabled = false;
  bool allow_demand_start = false;
  bool start_when_available = false;
  bool disallow_start_if_on_batteries = true;
  bool stop_if_going_on_batteries = true;
  TASK_INSTANCES_POLICY multiple_instances = TASK_INSTANCES_PARALLEL;
  std::wstring execution_time_limit;
  bool trigger_enabled = false;
  std::wstring trigger_delay;
  std::wstring trigger_start_boundary;
  std::wstring trigger_end_boundary;
};

void ValidatePortableWindowsRecoveryTaskSemanticFacts(
    const PortableWindowsRecoveryTaskSemanticFacts& facts);

// Task Scheduler's interactive-token start can fail when the caller was
// created with credentials but has no Winlogon session. Those are the only
// failures for which the already-validated helper may be started directly in
// the caller's exact non-elevated token.
bool IsPortableWindowsRecoveryTaskStartFallback(HRESULT result);

std::string RunPortableWindowsRecoveryPrepareBoundary(
    std::function<void()> persist_preparing,
    std::function<void()> arm_and_read_back,
    std::function<std::string()> prepare_mutation);

bool ShouldDisarmPortableWindowsRecoveryHost(
    const std::string& result_code,
    const std::string& verified_outcome);

struct PortableWindowsRecoveryResolution {
  std::string result_code;
  std::string verified_outcome;
};

PortableWindowsRecoveryResolution
RunPortableWindowsAutonomousRecoveryBoundary(
    PortableWindowsRecoveryHostController& controller,
    const PortableWindowsRecoveryHostTaskDefinition& definition,
    std::function<PortableWindowsRecoveryResolution()> recover);

void SignalPortableWindowsRecoveryHostReady(
    const PortableWindowsRecoveryHostTaskDefinition& definition);

class PortableWindowsRecoveryHostController {
 public:
  virtual ~PortableWindowsRecoveryHostController() = default;
  virtual void ArmAndStart(
      const PortableWindowsRecoveryHostTaskDefinition& definition,
      DWORD startup_timeout_milliseconds) = 0;
  virtual void Disarm(
      const PortableWindowsRecoveryHostTaskDefinition& definition) = 0;
};

class TaskSchedulerPortableWindowsRecoveryHostController final
    : public PortableWindowsRecoveryHostController {
 public:
  void ArmAndStart(
      const PortableWindowsRecoveryHostTaskDefinition& definition,
      DWORD startup_timeout_milliseconds) override;
  void Disarm(
      const PortableWindowsRecoveryHostTaskDefinition& definition) override;
};

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_PORTABLE_RECOVERY_HOST_H_
