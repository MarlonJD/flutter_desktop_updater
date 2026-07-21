#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "linux_native_install_service.h"

#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <map>
#include <optional>
#include <regex>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "install_helper_policy.h"
#include "linux_archive_restage.h"
#include "linux_file_transaction.h"
#include "linux_control_wire.h"
#include "linux_helper_policy.h"
#include "linux_helper_diagnostics.h"
#include "linux_recovery_service.h"
#include "linux_relaunch_service.h"
#include "linux_transaction_registry.h"
#include "native_install_authorization.h"
#include "native_install_request.h"
#include "native_install_session.h"
#include "release_contract.h"
#include "stage_provenance.h"

namespace desktop_updater::helper {
namespace {

namespace fs = std::filesystem;
using runtime::internal::AuthorizeNativeInstallTransactionRequestV1;
using runtime::internal::HelperPolicyV1;
using runtime::internal::NativeInstallAuthorizationPolicyV1;
using runtime::internal::NativeInstallAuthorizationReleaseKeyV1;
using runtime::internal::NativeInstallAuthorizationStrategyV1;
using runtime::internal::NativeInstallCallerExitMonitorFactoryV1;
using runtime::internal::NativeInstallCallerExitMonitorV1;
using runtime::internal::NativeInstallCallerV1;
using runtime::internal::NativeInstallOneShotServiceRuntimeV1;
using runtime::internal::NativeInstallOneShotSessionV1;
using runtime::internal::NativeInstallPreparedTransactionV1;
using runtime::internal::NativeInstallRequestAuthorizerV1;
using runtime::internal::NativeInstallTransactionRequestV1;
using runtime::internal::ParseHelperPolicyV1;
using runtime::internal::StageProvenanceBinding;
using runtime::internal::StageProvenanceEntry;
using runtime::internal::StageProvenanceMarker;

constexpr char kPortablePolicyName[] =
    "desktop-updater-helper.policy.json";
constexpr char kReleaseManifestName[] =
    ".desktop_updater_release_manifest.json";
constexpr char kInstalledIdentityName[] =
    ".desktop_updater_install_identity.json";

#if defined(DESKTOP_UPDATER_ENABLE_POLKIT_E2E_FAULT_INJECTION)
constexpr char kPolkitE2ECrashAfterBackup[] =
    "/var/lib/desktop-updater/"
    "desktop-updater-polkit-e2e-crash-after-backup";

class PolkitE2ECrashFault final : public LinuxTransactionFaultInjector {
 public:
  void Hit(LinuxTransactionFaultPoint point) override {
    if (point != LinuxTransactionFaultPoint::kAfterBackupRename) return;
    struct stat observed {};
    if (lstat(kPolkitE2ECrashAfterBackup, &observed) != 0) {
      if (errno == ENOENT) return;
      throw LinuxHelperPolicyError("polkit E2E crash marker read failed");
    }
    const LinuxVerifiedFile verified =
        VerifyProtectedLinuxFile(kPolkitE2ECrashAfterBackup);
    if (observed.st_dev != static_cast<dev_t>(verified.device) ||
        observed.st_ino != static_cast<ino_t>(verified.inode) ||
        observed.st_nlink != 1 || (observed.st_mode & 07777) != 0600) {
      throw LinuxHelperPolicyError(
          "polkit E2E crash marker security rejected");
    }
    (void)kill(getpid(), SIGKILL);
    _exit(137);
  }
};

LinuxTransactionFaultInjector* PolkitE2EFaultInjector() {
  static PolkitE2ECrashFault fault;
  return &fault;
}
#else
#if defined(DESKTOP_UPDATER_NATIVE_TESTING)
class NativeTestingStopAfterBackupFault final
    : public LinuxTransactionFaultInjector {
 public:
  void Hit(LinuxTransactionFaultPoint point) override {
    if (point != LinuxTransactionFaultPoint::kAfterBackupRename) return;
    const char* enabled =
        std::getenv("DESKTOP_UPDATER_TEST_STOP_AFTER_BACKUP_RENAME");
    if (enabled != nullptr && std::string(enabled) == "1") {
      (void)raise(SIGSTOP);
    }
  }
};

LinuxTransactionFaultInjector* PolkitE2EFaultInjector() {
  static NativeTestingStopAfterBackupFault fault;
  return &fault;
}
#else
LinuxTransactionFaultInjector* PolkitE2EFaultInjector() { return nullptr; }
#endif
#endif

std::int64_t NowUnixMilliseconds() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

void TestOnlyExitAfter(const char* environment_name, int status) {
#ifdef DESKTOP_UPDATER_NATIVE_TESTING
  const char* enabled = std::getenv(environment_name);
  if (enabled != nullptr && std::string(enabled) == "1") _exit(status);
#else
  (void)environment_name;
  (void)status;
#endif
}

std::string ReadAllFile(const fs::path& path,
                        std::size_t maximum,
                        bool portable_policy = false) {
  struct stat before {};
  if (lstat(path.c_str(), &before) != 0 || !S_ISREG(before.st_mode) ||
      S_ISLNK(before.st_mode)) {
    throw LinuxHelperPolicyError("required helper file is unavailable");
  }
  if (portable_policy &&
      (before.st_uid != geteuid() ||
       (before.st_mode & (S_IWGRP | S_IWOTH)) != 0)) {
    throw LinuxHelperPolicyError(
        "portable policy ownership or permissions rejected");
  }
  UniqueLinuxFd file(open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
  struct stat retained {};
  if (!file.valid() || fstat(file.get(), &retained) != 0 ||
      before.st_dev != retained.st_dev || before.st_ino != retained.st_ino ||
      !S_ISREG(retained.st_mode)) {
    throw LinuxHelperPolicyError("required helper file identity changed");
  }
  std::string bytes;
  std::array<char, 8192> buffer{};
  for (;;) {
    ssize_t count = -1;
    do {
      count = read(file.get(), buffer.data(), buffer.size());
    } while (count < 0 && errno == EINTR);
    if (count == 0) break;
    if (count < 0 ||
        bytes.size() + static_cast<std::size_t>(count) > maximum) {
      throw LinuxHelperPolicyError("required helper file read rejected");
    }
    bytes.append(buffer.data(), static_cast<std::size_t>(count));
  }
  return bytes;
}

bool IsLowerHexSha256(const std::string& value) {
  return value.size() == 64 &&
         std::all_of(value.begin(), value.end(), [](unsigned char byte) {
           return (byte >= '0' && byte <= '9') ||
                  (byte >= 'a' && byte <= 'f');
         });
}

bool Utf8Less(const std::string& left, const std::string& right) {
  return std::lexicographical_compare(
      left.begin(), left.end(), right.begin(), right.end(),
      [](char first, char second) {
        return static_cast<unsigned char>(first) <
               static_cast<unsigned char>(second);
      });
}

void ValidateCallerInventoryPath(const std::string& path) {
  if (path.empty() || path.front() == '/' || path.find('\\') != std::string::npos) {
    throw LinuxHelperPolicyError("caller provenance path rejected");
  }
  std::size_t start = 0;
  while (start <= path.size()) {
    const std::size_t separator = path.find('/', start);
    const std::string segment = path.substr(
        start, separator == std::string::npos ? std::string::npos
                                              : separator - start);
    if (segment.empty() || segment == "." || segment == "..") {
      throw LinuxHelperPolicyError("caller provenance path rejected");
    }
    if (separator == std::string::npos) break;
    start = separator + 1;
  }
}

// The caller marker remains an authenticated locator/binding for the fixed
// retained ZIP only. Its extracted-tree inventory is parsed for canonical
// wire compatibility, but is never used as payload mutation authority.
StageProvenanceBinding ReadPinnedStageProvenanceBinding(
    int source_stage_fd,
    const std::string& source_stage_leaf) {
  const std::string bytes = ReadAllFile(
      fs::path("/proc/self/fd") / std::to_string(source_stage_fd) /
          kLinuxStageProvenanceName,
      64 * 1024 * 1024);
  const auto parsed = runtime::internal::ParseJson(bytes);
  if (runtime::internal::EncodeCanonicalJson(parsed) != bytes ||
      parsed.object().size() != 6 ||
      parsed.at("schemaVersion").integer() != 1) {
    throw LinuxHelperPolicyError("caller provenance marker is not canonical");
  }
  StageProvenanceMarker marker;
  marker.nonce = parsed.at("nonce").string();
  marker.package_id = parsed.at("packageId").string();
  marker.descriptor_sha256 = parsed.at("descriptorSha256").string();
  marker.artifact_sha256 = parsed.at("artifactSha256").string();
  static const std::regex nonce_pattern(
      "^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-"
      "[0-9a-f]{12}$");
  if (!std::regex_match(marker.nonce, nonce_pattern) ||
      source_stage_leaf !=
          std::string(runtime::internal::kOwnedStagePrefix) + marker.nonce ||
      marker.package_id.empty() ||
      !IsLowerHexSha256(marker.descriptor_sha256) ||
      !IsLowerHexSha256(marker.artifact_sha256)) {
    throw LinuxHelperPolicyError("caller provenance identity rejected");
  }
  std::string previous;
  for (const auto& encoded : parsed.at("entries").array()) {
    StageProvenanceEntry entry;
    entry.path = encoded.at("path").string();
    entry.kind = encoded.at("kind").string();
    entry.length = encoded.at("length").integer();
    ValidateCallerInventoryPath(entry.path);
    if (!previous.empty() && !Utf8Less(previous, entry.path)) {
      throw LinuxHelperPolicyError("caller provenance entries rejected");
    }
    previous = entry.path;
    if (entry.kind == "file") {
      entry.sha256 = encoded.at("sha256").string();
      if (encoded.object().size() != 4 || entry.length < 0 ||
          !IsLowerHexSha256(entry.sha256) ||
          encoded.find("target") != nullptr) {
        throw LinuxHelperPolicyError("caller provenance file rejected");
      }
    } else if (entry.kind == "directory") {
      if (encoded.object().size() != 3 || entry.length != 0 ||
          encoded.find("sha256") != nullptr ||
          encoded.find("target") != nullptr) {
        throw LinuxHelperPolicyError("caller provenance directory rejected");
      }
    } else if (entry.kind == "symlink") {
      entry.target = encoded.at("target").string();
      ValidateCallerInventoryPath(entry.target);
      if (encoded.object().size() != 4 || entry.length != 0 ||
          encoded.find("sha256") != nullptr) {
        throw LinuxHelperPolicyError("caller provenance symlink rejected");
      }
    } else {
      throw LinuxHelperPolicyError("caller provenance entry kind rejected");
    }
    marker.entries.push_back(std::move(entry));
  }
  return {std::move(marker), bytes};
}

NativeInstallAuthorizationPolicyV1 AuthorizationPolicy(
    const HelperPolicyV1& policy) {
  NativeInstallAuthorizationPolicyV1 result;
  result.policy_id = policy.policy_id;
  result.application_package_id = policy.application_package_id;
  result.allowed_target_classes = policy.allowed_target_classes;
  result.minimum_helper_protocol_version =
      policy.minimum_helper_protocol_version;
  for (const auto& key : policy.release_root_public_keys) {
    result.release_root_public_keys.push_back(
        NativeInstallAuthorizationReleaseKeyV1{
            key.key_id, key.algorithm, key.public_key_base64});
  }
  for (const auto& strategy : policy.allowed_strategies) {
    result.allowed_strategies.push_back(
        NativeInstallAuthorizationStrategyV1{
            strategy.strategy, strategy.provider});
  }
  return result;
}

bool IsUnderRoot(const fs::path& candidate, const fs::path& root) {
  const fs::path normalized_candidate =
      fs::absolute(candidate).lexically_normal();
  const fs::path normalized_root = fs::absolute(root).lexically_normal();
  auto candidate_part = normalized_candidate.begin();
  for (auto root_part = normalized_root.begin();
       root_part != normalized_root.end(); ++root_part, ++candidate_part) {
    if (candidate_part == normalized_candidate.end() ||
        *candidate_part != *root_part) {
      return false;
    }
  }
  try {
    auto root_directory = OpenLinuxDirectory(normalized_root.string());
    const fs::path relative =
        normalized_candidate.lexically_relative(normalized_root);
    if (relative.empty()) return false;
    auto retained = OpenLinuxDirectoryBeneath(
        root_directory.get(), relative.generic_string());
    return retained.valid();
  } catch (const LinuxMountGuardError&) {
    return false;
  }
}

struct LoadedPolicy {
  HelperPolicyV1 policy;
  NativeInstallAuthorizationPolicyV1 authorization;
  std::string canonical_sha256;
};

void VerifyProtectedRecoveryDescriptor(
    const std::string& manifest,
    const NativeInstallTransactionRequestV1& request,
    const NativeInstallAuthorizationPolicyV1& policy) {
  const auto descriptor = runtime::internal::ParseReleaseDescriptor(manifest);
  if (runtime::internal::EncodeCanonicalJson(descriptor.raw) != manifest ||
      Sha256LinuxBytes(manifest) !=
          request.signed_descriptor.canonical_sha256 ||
      descriptor.schema_version != 3 || descriptor.platform != "linux" ||
      descriptor.package_id != request.package_id ||
      descriptor.artifact.kind != "zip" ||
      descriptor.artifact.sha256 != request.stage.artifact_sha256 ||
      descriptor.artifact.length != request.stage.artifact_length ||
      !descriptor.has_signature ||
      descriptor.signature.algorithm !=
          request.signed_descriptor.signature_algorithm ||
      descriptor.signature.public_key_id != request.signed_descriptor.key_id ||
      descriptor.signature.value !=
          request.signed_descriptor.signature_base64) {
    throw LinuxHelperPolicyError(
        "protected recovery descriptor binding rejected");
  }
  std::map<std::string, std::vector<std::uint8_t>> keys;
  for (const auto& key : policy.release_root_public_keys) {
    if (key.algorithm != "ed25519") {
      throw LinuxHelperPolicyError(
          "protected recovery descriptor algorithm rejected");
    }
    auto decoded = runtime::internal::DecodeBase64(key.public_key_base64);
    if (decoded.size() != 32 ||
        !keys.emplace(key.key_id, std::move(decoded)).second) {
      throw LinuxHelperPolicyError(
          "protected recovery descriptor key rejected");
    }
  }
  if (!runtime::internal::VerifyDescriptorSignature(descriptor, keys)) {
    throw LinuxHelperPolicyError(
        "protected recovery descriptor signature rejected");
  }
}

LoadedPolicy LoadPolicy(const fs::path& helper_executable,
                        bool broker_mode,
                        const NativeInstallTransactionRequestV1& request,
                        const LinuxPeerBinding& peer,
                        const std::optional<std::string>& recovery_caller_sha256 =
                            std::nullopt,
                        const std::optional<std::string>&
                            expected_policy_sha256 = std::nullopt) {
  std::string canonical_policy;
  if (broker_mode) {
    const LinuxHelperPolicy sealed = LinuxHelperPolicy::Load(
        fs::path("/etc/desktop-updater/policies") /
            (request.package_id + ".json"),
        request.package_id);
    ValidateLinuxBrokerIdentity(VerifyProtectedLinuxFile(helper_executable),
                                sealed);
    canonical_policy = sealed.canonical_policy_json();
  } else {
    canonical_policy = ReadAllFile(
        helper_executable.parent_path() / kPortablePolicyName,
        128 * 1024, true);
    if (!canonical_policy.empty() && canonical_policy.back() == '\n') {
      canonical_policy.pop_back();
    }
  }
  HelperPolicyV1 policy =
      ParseHelperPolicyV1(canonical_policy, request.package_id, 1);
  const std::string canonical_policy_sha256 =
      Sha256LinuxBytes(canonical_policy);
  const bool policy_caller =
      request.caller.executable_sha256 ==
          policy.allowed_application_signer.value &&
      request.caller.signer_identity ==
          policy.allowed_application_signer.value;
  const bool recovery_caller =
      recovery_caller_sha256.has_value() &&
      expected_policy_sha256.has_value() &&
      request.caller.executable_sha256 == *recovery_caller_sha256 &&
      request.caller.signer_identity == *recovery_caller_sha256;
  if (canonical_policy != policy.canonical_json ||
      (expected_policy_sha256.has_value() &&
       canonical_policy_sha256 != *expected_policy_sha256) ||
      request.policy_id != policy.policy_id ||
      policy.allowed_application_signer.kind != "sha256" ||
      policy.allowed_helper_signer.kind != "sha256" ||
      policy.allowed_helper_signer.value !=
          Sha256LinuxFile(helper_executable) ||
      (!policy_caller && !recovery_caller)) {
    throw LinuxHelperPolicyError(
        "canonical policy, helper, or caller binding rejected");
  }
  VerifyLinuxPeerExecutable(peer.pid, peer.process_start_identity,
                            request.caller.executable_sha256);
  if (policy.allowed_install_roots.empty()) {
    if (request.target.target_class != "sameUserWritable" || broker_mode) {
      throw LinuxHelperPolicyError(
          "portable target class or broker policy rejected");
    }
    struct stat target {};
    struct stat parent {};
    const fs::path target_path(request.target.path_hint);
    const bool target_exists = lstat(target_path.c_str(), &target) == 0;
    const bool recovery_target_absent =
        !target_exists && errno == ENOENT && recovery_caller;
    if ((!target_exists && !recovery_target_absent) ||
        lstat(target_path.parent_path().c_str(), &parent) != 0 ||
        (target_exists && target.st_uid != peer.uid) ||
        parent.st_uid != peer.uid ||
        access(target_path.parent_path().c_str(), W_OK | X_OK) != 0) {
      throw LinuxHelperPolicyError(
          "same-user-writable target proof rejected");
    }
  } else {
    const bool allowed = std::any_of(
        policy.allowed_install_roots.begin(),
        policy.allowed_install_roots.end(), [&](const std::string& root) {
          return IsUnderRoot(request.target.path_hint, root);
        });
    if (!allowed) {
      throw LinuxHelperPolicyError("target is outside sealed install roots");
    }
  }
  return LoadedPolicy{policy, AuthorizationPolicy(policy),
                      canonical_policy_sha256};
}

class VerifiedLinuxInstallPayload final : public LinuxInstallPayloadVerifier {
 public:
  VerifiedLinuxInstallPayload(NativeInstallTransactionRequestV1 request,
                              std::string signer_identity,
                              LinuxArchiveRestageRequest archive_request,
                              std::string payload_seal_sha256)
      : request_(std::move(request)),
        signer_identity_(std::move(signer_identity)),
        archive_request_(std::move(archive_request)),
        payload_seal_sha256_(std::move(payload_seal_sha256)),
        control_leaf_(LinuxArchiveControlLeaf(
            request_.target.target_name_hint, request_.transaction_id)) {}

  LinuxVerifiedPayloadIdentity Verify(
      int parent, const std::string& payload_leaf) override {
    const auto verified = VerifyLinuxArchivePayload(
        parent, payload_leaf, control_leaf_, archive_request_,
        payload_seal_sha256_);
    return {request_.package_id,
            signer_identity_,
            verified.descriptor_sha256,
            verified.payload_seal_sha256,
            verified.artifact_sha256,
            request_.target.executable_relative_path,
            verified.executable_sha256,
            verified.executable_mode,
            verified.executable_uid,
            verified.executable_gid};
  }

  void FinalizeActivatedPayloadRoot(
      int parent,
      const std::string& leaf,
      const LinuxFileIdentity& staged_identity) override {
    FinalizeLinuxArchiveActivatedRoot(parent, leaf, staged_identity,
                                      archive_request_);
  }

  bool MatchesActivatedPayloadRoot(
      int parent,
      const std::string& leaf,
      const LinuxFileIdentity& staged_identity) override {
    return LinuxArchiveActivatedRootMatches(parent, leaf, staged_identity,
                                            archive_request_);
  }

  void CleanupProtectedControlState() {
    auto parent = OpenLinuxDirectory(
        archive_request_.target_parent_path.string());
    if (LinuxRelativeExistsNoFollow(parent.get(), control_leaf_)) {
      CleanupLinuxArchiveControl(parent.get(), control_leaf_, archive_request_,
                                 payload_seal_sha256_);
    }
    CleanupLinuxArchiveRestageRecord(parent.get(), archive_request_);
  }

 private:
  NativeInstallTransactionRequestV1 request_;
  std::string signer_identity_;
  LinuxArchiveRestageRequest archive_request_;
  std::string payload_seal_sha256_;
  std::string control_leaf_;
};

class LinuxPreparedInstall final : public NativeInstallPreparedTransactionV1 {
 public:
  LinuxPreparedInstall(std::string transaction_id,
                       std::unique_ptr<LinuxArchiveRestagedPayload> restaged,
                       std::unique_ptr<VerifiedLinuxInstallPayload> verifier,
                       std::unique_ptr<LinuxFileTransaction> transaction,
                       LinuxTransactionRegistryRecord record,
                       bool broker_mode,
                       NativeInstallTransactionRequestV1 request,
                       LinuxProcessLauncher::Identity launch_identity)
      : transaction_id_(std::move(transaction_id)),
        restaged_(std::move(restaged)),
        verifier_(std::move(verifier)),
        transaction_(std::move(transaction)),
        registry_(broker_mode),
        record_(std::move(record)),
        broker_mode_(broker_mode),
        request_(std::move(request)),
        launch_identity_(std::move(launch_identity)) {
    TestOnlyExitAfter(
        "DESKTOP_UPDATER_TEST_EXIT_AFTER_PREPARING_REGISTRY", 86);
  }

  const std::string& transaction_id() const override {
    return transaction_id_;
  }

  std::string PrepareDurableJournal() override {
    const std::string journal = transaction_->PrepareDurableJournal();
    restaged_->ArmForRecovery();
    record_.journal_sha256 = Sha256LinuxBytes(journal);
    record_.state = "prepared";
    record_.result_code = "recoveryRequired";
    registry_.Persist(record_);
    EmitLinuxHelperDiagnostic(broker_mode_, request_, "prepared",
                              "transaction journal persisted",
                              "durableJournalReady");
    return journal;
  }

  void MarkCommitAccepted() override {
    record_.state = "commitAccepted";
    record_.result_code = "recoveryRequired";
    registry_.Persist(record_);
  }

  void ExecuteAfterCallerExit() override {
    try {
      (void)transaction_->Execute();
      record_.state = "launchPending";
      record_.result_code = "recoveryRequired";
      registry_.Persist(record_);
      EmitLinuxHelperDiagnostic(broker_mode_, request_, "completed",
                                "activation verified",
                                "payloadIdentityMatched");
    } catch (...) {
      record_.state = "recoveryRequired";
      record_.result_code = "recoveryRequired";
      try {
        registry_.Persist(record_);
      } catch (...) {
      }
      throw;
    }
    TestOnlyExitAfter(
        "DESKTOP_UPDATER_TEST_EXIT_AFTER_RELAUNCH_PENDING", 89);
    record_.state = "launchAttempting";
    record_.result_code = "relaunchFailure";
    registry_.Persist(record_);
    TestOnlyExitAfter(
        "DESKTOP_UPDATER_TEST_EXIT_AFTER_RELAUNCH_ATTEMPTING", 90);
    bool launched = false;
    EmitLinuxHelperDiagnostic(broker_mode_, request_, "completed",
                              "relaunch attempt",
                              "verifiedExecutableFd");
    try {
      LinuxRelaunchService relaunch(
          record_.expected_payload_identity, *verifier_, launcher_,
          launch_identity_);
      relaunch.Relaunch(record_.target_path);
      launched = true;
    } catch (...) {
      launched = false;
    }
    record_.state = launched ? "launched" : "launchFailed";
    record_.result_code = launched ? "completed" : "relaunchFailure";
    registry_.Persist(record_);
    EmitLinuxHelperDiagnostic(
        broker_mode_, request_, "completed", "transaction completed",
        launched ? "relaunchExecConfirmed" : "relaunchFailure");
    // The terminal filesystem outcome and protected registry state are now
    // durable. Control cleanup is idempotent auxiliary work and must never
    // downgrade a verified activation to recoveryRequired.
    try {
      verifier_->CleanupProtectedControlState();
      restaged_->CleanupCompleted();
    } catch (...) {
      restaged_->PreserveControlForRecovery();
      EmitLinuxHelperDiagnostic(broker_mode_, request_, "completed",
                                "recovery detected",
                                "terminalControlCleanupPending");
    }
  }

  void CancelPrepared() override {
    transaction_->CancelPrepared();
    record_.state = "rolledBack";
    record_.result_code = "rolledBack";
    registry_.Persist(record_);
    TestOnlyExitAfter(
        "DESKTOP_UPDATER_TEST_EXIT_AFTER_ROLLBACK_REGISTRY", 87);
    EmitLinuxHelperDiagnostic(broker_mode_, request_, "rolledBack",
                              "transaction completed",
                              "reservationCancelled");
    try {
      restaged_->CleanupCancelled();
    } catch (...) {
      EmitLinuxHelperDiagnostic(broker_mode_, request_, "rolledBack",
                                "recovery detected",
                                "terminalControlCleanupPending");
    }
  }

 private:
  std::string transaction_id_;
  std::unique_ptr<LinuxArchiveRestagedPayload> restaged_;
  std::unique_ptr<VerifiedLinuxInstallPayload> verifier_;
  std::unique_ptr<LinuxFileTransaction> transaction_;
  LinuxTransactionRegistry registry_;
  LinuxTransactionRegistryRecord record_;
  bool broker_mode_;
  NativeInstallTransactionRequestV1 request_;
  LinuxProcessLauncher::Identity launch_identity_;
  FexecveLinuxProcessLauncher launcher_;
};

class LinuxInstallAuthorizer final : public NativeInstallRequestAuthorizerV1 {
 public:
  LinuxInstallAuthorizer(LoadedPolicy policy,
                         std::string endpoint_sha256,
                         fs::path helper_executable,
                         LinuxPeerBinding peer,
                         bool broker_mode)
      : policy_(std::move(policy)),
        endpoint_sha256_(std::move(endpoint_sha256)),
        helper_executable_(std::move(helper_executable)),
        peer_(std::move(peer)),
        broker_mode_(broker_mode) {}

  const std::string& helper_endpoint_identity_sha256() const override {
    return endpoint_sha256_;
  }

  std::unique_ptr<NativeInstallPreparedTransactionV1> Authorize(
      const NativeInstallTransactionRequestV1& request) override {
    if (request.caller.process_id != peer_.pid ||
        request.caller.process_start_identity !=
            "linux:" + std::to_string(peer_.process_start_identity) ||
        request.caller.package_id != request.package_id) {
      throw LinuxHelperPolicyError("authenticated caller binding changed");
    }
    LinuxProcessLauncher::Identity launch_identity =
        CaptureLinuxRelaunchIdentity(peer_.pid, peer_.process_start_identity,
                                     peer_.uid, peer_.gid);
    const fs::path stage(request.stage.path_hint);
    ValidateLinuxLeaf(stage.filename().string());
    auto source_parent = OpenLinuxDirectory(stage.parent_path().string());
    auto source_stage = OpenLinuxRelativeNoFollow(
        source_parent.get(), stage.filename().string(),
        O_RDONLY | O_DIRECTORY);
    const fs::path pinned_stage = fs::path("/proc/self/fd") /
                                  std::to_string(source_stage.get());
    const auto binding = ReadPinnedStageProvenanceBinding(
        source_stage.get(), stage.filename().string());
    const auto& marker = binding.marker;
    const std::string manifest = ReadAllFile(
        pinned_stage / kReleaseManifestName, 1024 * 1024);
    const auto authorized = AuthorizeNativeInstallTransactionRequestV1(
        request, policy_.authorization, "linux", manifest, marker,
        Sha256LinuxBytes(binding.canonical_json), Sha256LinuxBytes);
    const fs::path target_path(request.target.path_hint);
    auto target_parent = OpenLinuxDirectory(target_path.parent_path().string());
    auto target = OpenLinuxRelativeNoFollow(
        target_parent.get(), target_path.filename().string(),
        O_RDONLY | O_DIRECTORY);
    ProveAuthenticatedLinuxInstallTarget(peer_, request, target.get());
    const LinuxFileIdentity target_identity = ReadLinuxFileIdentity(target.get());
    const std::string installed_identity = ReadAllFile(
        fs::path("/proc/self/fd") / std::to_string(target.get()) /
            kInstalledIdentityName,
        128 * 1024);
    if (Sha256LinuxBytes(installed_identity) !=
        request.target.identity_proof_sha256) {
      throw LinuxHelperPolicyError("installed target identity changed");
    }

    LinuxArchiveRestageRequest archive_request;
    archive_request.source_stage_fd = source_stage.get();
    archive_request.target_parent_fd = target_parent.get();
    archive_request.target_parent_path = target_path.parent_path();
    archive_request.target_name = request.target.target_name_hint;
    archive_request.transaction_id = request.transaction_id;
    archive_request.package_id = request.package_id;
    archive_request.canonical_release_manifest = manifest;
    archive_request.descriptor_sha256 =
        request.signed_descriptor.canonical_sha256;
    archive_request.artifact_sha256 = request.stage.artifact_sha256;
    archive_request.artifact_length = request.stage.artifact_length;
    archive_request.executable_relative_path =
        request.target.executable_relative_path;
    archive_request.caller_marker = marker;
    archive_request.source_uid = peer_.uid;
    archive_request.source_gid = peer_.gid;
    archive_request.payload_uid = broker_mode_ ? 0 : peer_.uid;
    archive_request.payload_gid = broker_mode_ ? 0 : peer_.gid;
    archive_request.activation_root_mode =
        static_cast<mode_t>(target_identity.mode & 0777) &
        static_cast<mode_t>(~(S_IWGRP | S_IWOTH));
    archive_request.broker_mode = broker_mode_;
    std::unique_ptr<LinuxArchiveRestagedPayload> restaged;
    try {
      restaged = RestageLinuxSignedZip(archive_request);
    } catch (const LinuxArchiveManualCleanupRequiredError&) {
      EmitLinuxHelperDiagnostic(broker_mode_, request,
                                "manualActionRequired",
                                "manual action required",
                                "boundedRestageCleanupRefused");
      throw;
    }
    auto verifier = std::make_unique<VerifiedLinuxInstallPayload>(
        request, authorized.descriptor.signature.public_key_id,
        archive_request, restaged->payload_seal_sha256());
    const LinuxVerifiedPayloadIdentity expected = verifier->Verify(
        target_parent.get(), restaged->path().filename().string());
    LinuxTransactionRegistryRecord record;
    record.transaction_id = request.transaction_id;
    record.package_id = request.package_id;
    record.policy_id = request.policy_id;
    record.helper_endpoint_identity_sha256 = endpoint_sha256_;
    record.recovery_policy_identity_sha256 = policy_.canonical_sha256;
    LinuxTransactionRegistry registry(broker_mode_);
    if (broker_mode_) {
      record.recovery_authority_kind = "fixedBroker";
      record.recovery_authority_generation_sha256 =
          LinuxRecoveryAuthorityGenerationSha256(
              record.transaction_id, record.recovery_authority_kind,
              record.helper_endpoint_identity_sha256,
              record.recovery_policy_identity_sha256);
    } else {
      registry.PreservePortableRecoveryAuthority(
          helper_executable_,
          helper_executable_.parent_path() / kPortablePolicyName, &record);
    }
    record.target_path = request.target.path_hint;
    record.canonical_request = runtime::internal::
        EncodeCanonicalNativeInstallTransactionRequestV1(request);
    record.state = "preparing";
    record.result_code = "recoveryRequired";
    record.journal_sha256 = std::string(64, '0');
    record.expected_payload_identity = expected;
    // Publish a complete recovery intent before attempting the durable target
    // lock. A process death after successful lock persistence is then
    // discoverable through the transaction registry.
    registry.Persist(record);

    std::unique_ptr<LinuxFileTransaction> transaction;
    try {
      transaction = std::make_unique<LinuxFileTransaction>(
          request.target.path_hint, restaged->path(),
          request.transaction_id, getpid(),
          expected, *verifier, PolkitE2EFaultInjector());
    } catch (...) {
      try {
        record.state = "rolledBack";
        record.result_code = "rolledBack";
        registry.Persist(record);
        restaged->CleanupCancelled();
      } catch (...) {
      }
      throw;
    }
    TestOnlyExitAfter(
        "DESKTOP_UPDATER_TEST_EXIT_AFTER_TARGET_LOCK", 85);
    EmitLinuxHelperDiagnostic(broker_mode_, request, "prepared",
                              "target lock acquired",
                              "exclusiveTargetLock");
    return std::make_unique<LinuxPreparedInstall>(
        request.transaction_id, std::move(restaged), std::move(verifier),
        std::move(transaction), std::move(record), broker_mode_, request,
        std::move(launch_identity));
  }

 private:
  LoadedPolicy policy_;
  std::string endpoint_sha256_;
  fs::path helper_executable_;
  LinuxPeerBinding peer_;
  bool broker_mode_;
};

class LinuxCallerExitMonitor final : public NativeInstallCallerExitMonitorV1 {
 public:
  LinuxCallerExitMonitor(pid_t pid,
                         std::uint64_t start_identity,
                         NativeInstallTransactionRequestV1 request,
                         bool broker_mode)
      : pid_(pid),
        start_identity_(start_identity),
        pidfd_(OpenLinuxPidfd(pid)),
        request_(std::move(request)),
        broker_mode_(broker_mode) {}

  void WaitForExit(std::int64_t expires_at_unix_milliseconds) override {
    while (NowUnixMilliseconds() <= expires_at_unix_milliseconds) {
      if (pidfd_.valid()) {
        const std::int64_t remaining =
            expires_at_unix_milliseconds - NowUnixMilliseconds();
        pollfd observed{pidfd_.get(), POLLIN, 0};
        int result = -1;
        do {
          result = poll(&observed, 1,
                        static_cast<int>(std::max<std::int64_t>(0, remaining)));
        } while (result < 0 && errno == EINTR);
        if (result > 0 &&
            (observed.revents & (POLLIN | POLLHUP | POLLERR)) != 0) {
          EmitLinuxHelperDiagnostic(broker_mode_, request_, "commitAccepted",
                                    "caller exit observed",
                                    "exactCallerExited");
          return;
        }
        if (result < 0) {
          throw UnixSocketTransportError("caller pidfd wait failed");
        }
      } else {
        try {
          if (LinuxProcessStartIdentity(pid_) != start_identity_) {
            EmitLinuxHelperDiagnostic(broker_mode_, request_,
                                      "commitAccepted",
                                      "caller exit observed",
                                      "exactCallerExited");
            return;
          }
        } catch (const std::exception&) {
          EmitLinuxHelperDiagnostic(broker_mode_, request_, "commitAccepted",
                                    "caller exit observed",
                                    "exactCallerExited");
          return;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(25));
      }
    }
    throw UnixSocketTransportError("caller did not exit before reservation expiry");
  }

 private:
  pid_t pid_;
  std::uint64_t start_identity_;
  UniqueLinuxFd pidfd_;
  NativeInstallTransactionRequestV1 request_;
  bool broker_mode_;
};

class LinuxCallerExitMonitorFactory final
    : public NativeInstallCallerExitMonitorFactoryV1 {
 public:
  LinuxCallerExitMonitorFactory(NativeInstallTransactionRequestV1 request,
                                bool broker_mode)
      : request_(std::move(request)), broker_mode_(broker_mode) {}

  std::unique_ptr<NativeInstallCallerExitMonitorV1> Create(
      const NativeInstallCallerV1& caller) override {
    constexpr char prefix[] = "linux:";
    if (caller.process_id <= 0 ||
        caller.process_start_identity.rfind(prefix, 0) != 0) {
      throw UnixSocketTransportError("caller exit identity rejected");
    }
    const auto start = std::stoull(
        caller.process_start_identity.substr(sizeof(prefix) - 1));
    if (LinuxProcessStartIdentity(static_cast<pid_t>(caller.process_id)) !=
        start) {
      throw UnixSocketTransportError("caller exit identity changed");
    }
    return std::make_unique<LinuxCallerExitMonitor>(
        static_cast<pid_t>(caller.process_id), start, request_, broker_mode_);
  }

 private:
  NativeInstallTransactionRequestV1 request_;
  bool broker_mode_;
};

std::string ReadyToken() {
  static constexpr char alphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  std::array<unsigned char, 32> random{};
  UniqueLinuxFd source(open("/dev/urandom", O_RDONLY | O_CLOEXEC));
  std::size_t offset = 0;
  while (source.valid() && offset < random.size()) {
    ssize_t count = read(source.get(), random.data() + offset,
                         random.size() - offset);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) break;
    offset += static_cast<std::size_t>(count);
  }
  if (offset != random.size()) {
    throw UnixSocketTransportError("ready token entropy unavailable");
  }
  std::string token;
  token.reserve(43);
  std::uint32_t accumulator = 0;
  int bits = 0;
  for (unsigned char byte : random) {
    accumulator = (accumulator << 8) | byte;
    bits += 8;
    while (bits >= 6) {
      bits -= 6;
      token.push_back(alphabet[(accumulator >> bits) & 0x3f]);
    }
  }
  if (bits > 0) token.push_back(alphabet[(accumulator << (6 - bits)) & 0x3f]);
  return token;
}

bool InstalledTargetIdentityMatches(
    int target_parent,
    const std::string& target_leaf,
    const NativeInstallTransactionRequestV1& request) {
  try {
    auto target = OpenLinuxRelativeNoFollow(
        target_parent, target_leaf, O_RDONLY | O_DIRECTORY);
    const std::string identity = ReadAllFile(
        fs::path("/proc/self/fd") / std::to_string(target.get()) /
            kInstalledIdentityName,
        128 * 1024);
    return Sha256LinuxBytes(identity) == request.target.identity_proof_sha256;
  } catch (...) {
    return false;
  }
}

bool VerifiedPayloadMatches(VerifiedLinuxInstallPayload* verifier,
                            int parent,
                            const std::string& leaf,
                            const LinuxVerifiedPayloadIdentity& expected) {
  try {
    return LinuxRelativeExistsNoFollow(parent, leaf) &&
           verifier->Verify(parent, leaf) == expected;
  } catch (...) {
    return false;
  }
}

}  // namespace

void ProveAuthenticatedLinuxInstallTarget(
    const LinuxPeerBinding& peer,
    const NativeInstallTransactionRequestV1& request,
    int retained_target_root) {
  constexpr char kMismatch[] =
      "authenticated caller executable does not match install target";
  try {
    ValidateCallerInventoryPath(request.target.executable_relative_path);
    if (LinuxProcessStartIdentity(peer.pid) != peer.process_start_identity) {
      throw LinuxHelperPolicyError(kMismatch);
    }

    const fs::path proc_executable =
        fs::path("/proc") / std::to_string(peer.pid) / "exe";
    UniqueLinuxFd retained_caller(
        open(proc_executable.c_str(), O_RDONLY | O_CLOEXEC));
    if (!retained_caller.valid()) {
      throw LinuxHelperPolicyError(kMismatch);
    }

    auto open_target_executable = [&]() {
      int parent = retained_target_root;
      UniqueLinuxFd retained;
      std::size_t start = 0;
      for (;;) {
        const std::size_t separator =
            request.target.executable_relative_path.find('/', start);
        const bool final = separator == std::string::npos;
        const std::string component =
            request.target.executable_relative_path.substr(
                start, final ? std::string::npos : separator - start);
        retained = OpenLinuxRelativeNoFollow(
            parent, component,
            final ? O_RDONLY : O_PATH | O_DIRECTORY);
        if (final) break;
        parent = retained.get();
        start = separator + 1;
      }
      return retained;
    };

    UniqueLinuxFd retained_target = open_target_executable();
    const LinuxFileIdentity caller_identity =
        ReadLinuxFileIdentity(retained_caller.get());
    const LinuxFileIdentity target_identity =
        ReadLinuxFileIdentity(retained_target.get());
    if (!S_ISREG(caller_identity.mode) || !S_ISREG(target_identity.mode) ||
        caller_identity != target_identity) {
      throw LinuxHelperPolicyError(kMismatch);
    }

    // Re-open both names after retaining the first pair. This detects an exec
    // or target-path replacement during authorization without relying on
    // mutable path strings after the identity comparison.
    UniqueLinuxFd reproved_caller(
        open(proc_executable.c_str(), O_RDONLY | O_CLOEXEC));
    UniqueLinuxFd reproved_target = open_target_executable();
    if (!reproved_caller.valid() ||
        ReadLinuxFileIdentity(reproved_caller.get()) != caller_identity ||
        ReadLinuxFileIdentity(reproved_target.get()) != target_identity ||
        LinuxProcessStartIdentity(peer.pid) != peer.process_start_identity) {
      throw LinuxHelperPolicyError(kMismatch);
    }
  } catch (const LinuxHelperPolicyError&) {
    throw;
  } catch (const std::exception&) {
    throw LinuxHelperPolicyError(kMismatch);
  }
}

void RunLinuxNativeInstallService(
    runtime::internal::NativeInstallWireChannelV1& channel,
    const LinuxPeerBinding& peer,
    const fs::path& helper_executable,
    bool broker_mode,
    const std::string& canonical_request) {
  const NativeInstallTransactionRequestV1 request =
      runtime::internal::ParseNativeInstallTransactionRequestV1(
          canonical_request);
  const std::string helper_parent =
      helper_executable.parent_path().filename().string();
  if (helper_parent.size() > std::string(".authority").size() &&
      helper_parent.compare(helper_parent.size() -
                                std::string(".authority").size(),
                            std::string(".authority").size(),
                            ".authority") == 0) {
    throw LinuxHelperPolicyError(
        "retained recovery authority cannot authorize a new install");
  }
  LoadedPolicy policy =
      LoadPolicy(helper_executable, broker_mode, request, peer);
  EmitLinuxHelperDiagnostic(broker_mode, request, "authenticated",
                            "helper authenticated", "policyAndPeerBound");
  LinuxInstallAuthorizer authorizer(
      std::move(policy), Sha256LinuxFile(helper_executable), helper_executable,
      peer, broker_mode);
  NativeInstallOneShotSessionV1 session(
      authorizer, ReadyToken, Sha256LinuxBytes, NowUnixMilliseconds, 30'000);
  LinuxCallerExitMonitorFactory monitor_factory(request, broker_mode);
  NativeInstallOneShotServiceRuntimeV1 runtime(session, monitor_factory);
  runtime.RunWithInitialRequest(channel, canonical_request);
}

void RunLinuxNativeInstallControlService(
    runtime::internal::NativeInstallWireChannelV1& channel,
    const LinuxPeerBinding& peer,
    const fs::path& helper_executable,
    bool broker_mode,
    const std::string& canonical_request) {
  const LinuxControlRequestV1 control =
      ParseLinuxControlRequestV1(canonical_request);
  if (control.request_nonce != peer.nonce ||
      control.caller_process_id != peer.pid ||
      control.caller_process_start_identity !=
          "linux:" + std::to_string(peer.process_start_identity)) {
    throw LinuxControlWireError("authenticated control caller changed");
  }
  LinuxTransactionRegistry registry(broker_mode);
  auto loaded = registry.Load(control.transaction_id);
  if (!loaded.has_value()) {
    throw LinuxTransactionRegistryError("transaction is not registered");
  }
  LinuxTransactionRegistryRecord record = *loaded;
  registry.VerifyRecoveryAuthority(record, helper_executable);
  const std::string current_endpoint = Sha256LinuxFile(helper_executable);
  if (record.helper_endpoint_identity_sha256 != current_endpoint) {
    throw LinuxHelperPolicyError(
        "transaction helper endpoint identity changed");
  }
  NativeInstallTransactionRequestV1 stored_request =
      runtime::internal::ParseNativeInstallTransactionRequestV1(
          record.canonical_request);
  stored_request.caller.process_id = control.caller_process_id;
  stored_request.caller.process_start_identity =
      control.caller_process_start_identity;
  stored_request.caller.executable_sha256 =
      control.caller_executable_sha256;
  stored_request.caller.signer_identity = control.caller_signer_identity;
  const fs::path target_path(record.target_path);
  LoadedPolicy loaded_policy = LoadPolicy(
      helper_executable, broker_mode, stored_request, peer,
      record.expected_payload_identity.executable_sha256,
      record.recovery_policy_identity_sha256);

  if (control.operation == "queryTransaction") {
    std::string state;
    std::string result;
    if (record.state == "completed" || record.state == "launched") {
      state = "completed";
      result = "completed";
    } else if (record.state == "launchPending") {
      state = "prepared";
      result = "recoveryRequired";
    } else if (record.state == "launchAttempting" ||
               record.state == "launchFailed") {
      state = "completed";
      result = "relaunchFailure";
    } else if (record.state == "rolledBack") {
      state = "rolledBack";
      result = "rolledBack";
    } else if (record.state == "manualActionRequired") {
      state = "manualActionRequired";
      result = "manualActionRequired";
    } else {
      state = "prepared";
      result = "recoveryRequired";
    }
    channel.WriteFrame(runtime::internal::
                           EncodeNativeInstallTransactionStatusV1(
                               {1, record.transaction_id, state, result,
                                record.journal_sha256}));
    return;
  }

  auto target_parent = OpenLinuxDirectory(target_path.parent_path().string());
  const LinuxTransactionPaths transaction_paths = LinuxTransactionPaths::Create(
      target_path.filename().string(), record.transaction_id);
  const std::string control_leaf = LinuxArchiveControlLeaf(
      target_path.filename().string(), record.transaction_id);
  const std::string payload_leaf =
      "desktop_updater_stage_" + record.transaction_id;
  LinuxArchiveRestageRequest archive_request;
  archive_request.target_parent_fd = target_parent.get();
  archive_request.target_parent_path = target_path.parent_path();
  archive_request.target_name = target_path.filename().string();
  archive_request.transaction_id = stored_request.transaction_id;
  archive_request.package_id = stored_request.package_id;
  archive_request.descriptor_sha256 =
      stored_request.signed_descriptor.canonical_sha256;
  archive_request.artifact_sha256 = stored_request.stage.artifact_sha256;
  archive_request.artifact_length = stored_request.stage.artifact_length;
  archive_request.executable_relative_path =
      stored_request.target.executable_relative_path;
  archive_request.payload_uid = broker_mode ? 0 : peer.uid;
  archive_request.payload_gid = broker_mode ? 0 : peer.gid;
  archive_request.broker_mode = broker_mode;
  const bool control_exists =
      LinuxRelativeExistsNoFollow(target_parent.get(), control_leaf);
  if (control_exists) {
    archive_request.activation_root_mode = ReadLinuxArchiveActivationRootMode(
        target_parent.get(), control_leaf, archive_request.payload_uid,
        archive_request.payload_gid,
        record.expected_payload_identity.stage_provenance_sha256);
    archive_request.canonical_release_manifest =
        ReadLinuxArchiveControlManifest(target_parent.get(), control_leaf,
                                        archive_request);
    VerifyProtectedRecoveryDescriptor(
        archive_request.canonical_release_manifest, stored_request,
        loaded_policy.authorization);
  }

  if (record.state == "completed" || record.state == "launched" ||
      record.state == "launchPending" ||
      record.state == "launchAttempting" ||
      record.state == "launchFailed") {
    const bool relaunch_failed =
        record.state == "launchPending" ||
        record.state == "launchAttempting" || record.state == "launchFailed";
    if (record.state == "launchPending" ||
        record.state == "launchAttempting") {
      record.state = "launchFailed";
      record.result_code = "relaunchFailure";
      registry.Persist(record);
    }
    if (control_exists) {
      VerifiedLinuxInstallPayload terminal_verifier(
          stored_request, record.expected_payload_identity.signer_identity,
          archive_request,
          record.expected_payload_identity.stage_provenance_sha256);
      if (terminal_verifier.Verify(target_parent.get(),
                                   target_path.filename().string()) !=
          record.expected_payload_identity) {
        throw LinuxArchiveRestageError(
            "completed payload identity changed before control cleanup");
      }
      CleanupLinuxArchiveControl(
          target_parent.get(), control_leaf, archive_request,
          record.expected_payload_identity.stage_provenance_sha256);
    }
    CleanupLinuxArchiveRestageRecord(target_parent.get(), archive_request);
    channel.WriteFrame(runtime::internal::EncodeNativeInstallRecoveryResultV1(
        {1, record.transaction_id,
         relaunch_failed ? "relaunchFailure" : "completed", "newTarget",
         record.journal_sha256}));
    return;
  }
  if (record.state == "rolledBack") {
    if (!InstalledTargetIdentityMatches(target_parent.get(),
                                        target_path.filename().string(),
                                        stored_request)) {
      throw LinuxArchiveRestageError(
          "rolled-back target identity changed");
    }
    if (LinuxRelativeExistsNoFollow(target_parent.get(), payload_leaf)) {
      if (!control_exists) {
        throw LinuxArchiveRestageError(
            "rolled-back payload lacks protected control proof");
      }
      VerifiedLinuxInstallPayload rollback_verifier(
          stored_request, record.expected_payload_identity.signer_identity,
          archive_request,
          record.expected_payload_identity.stage_provenance_sha256);
      if (rollback_verifier.Verify(target_parent.get(), payload_leaf) !=
          record.expected_payload_identity) {
        throw LinuxArchiveRestageError(
            "rolled-back payload identity changed");
      }
      const LinuxFileIdentity payload_identity =
          ReadLinuxRelativeIdentity(target_parent.get(), payload_leaf);
      RemoveLinuxTreeExact(target_parent.get(), payload_leaf,
                           payload_identity);
      SyncLinuxDirectory(target_parent.get());
    }
    if (control_exists) {
      CleanupLinuxArchiveControl(
          target_parent.get(), control_leaf, archive_request,
          record.expected_payload_identity.stage_provenance_sha256);
    }
    CleanupLinuxArchiveRestageRecord(target_parent.get(), archive_request);
    channel.WriteFrame(runtime::internal::EncodeNativeInstallRecoveryResultV1(
        {1, record.transaction_id, "rolledBack", "oldTarget",
         record.journal_sha256}));
    return;
  }
  if (!control_exists) {
    record.state = "manualActionRequired";
    record.result_code = "manualActionRequired";
    registry.Persist(record);
    channel.WriteFrame(runtime::internal::EncodeNativeInstallRecoveryResultV1(
        {1, record.transaction_id, "manualActionRequired", "none",
         record.journal_sha256}));
    return;
  }

  VerifiedLinuxInstallPayload verifier(
      stored_request, record.expected_payload_identity.signer_identity,
      archive_request,
      record.expected_payload_identity.stage_provenance_sha256);
  PidfdLinuxProcessLivenessChecker liveness;
  LinuxRecoveryService recovery(
      record.target_path, record.transaction_id,
      record.expected_payload_identity, verifier, liveness);
  const bool journal_exists = LinuxRelativeExistsNoFollow(
      target_parent.get(), transaction_paths.journal_name);
  const bool journal_next_exists = LinuxRelativeExistsNoFollow(
      target_parent.get(), transaction_paths.journal_next_name);
  if (journal_exists) {
    const std::string journal = ReadLinuxRelativeUtf8(
        target_parent.get(), transaction_paths.journal_name, 1024 * 1024);
    const std::string actual_journal_sha256 = Sha256LinuxBytes(journal);
    if (record.journal_sha256 == std::string(64, '0')) {
      record.journal_sha256 = actual_journal_sha256;
      registry.Persist(record);
    } else if (record.journal_sha256 != actual_journal_sha256) {
      throw LinuxArchiveRestageError(
          "registry and durable journal binding changed");
    }
  }
  LinuxRecoveryOutcome outcome = LinuxRecoveryOutcome::kNothingToRecover;
  if (journal_exists || journal_next_exists ||
      LinuxRelativeExistsNoFollow(target_parent.get(),
                                  transaction_paths.lock_name)) {
    outcome = recovery.Recover();
  }
  EmitLinuxHelperDiagnostic(broker_mode, stored_request, record.state,
                            "recovery detected",
                            journal_exists ? "durableJournalFound"
                                           : "preJournalTopologyFound");
  runtime::internal::NativeInstallRecoveryResultV1 response;
  response.protocol_version = 1;
  response.transaction_id = record.transaction_id;
  response.journal_sha256 = record.journal_sha256;
  if (journal_exists && outcome == LinuxRecoveryOutcome::kRecovered) {
    if (verifier.Verify(target_parent.get(), target_path.filename().string()) !=
        record.expected_payload_identity) {
      throw LinuxArchiveRestageError(
          "recovered payload identity changed before control cleanup");
    }
    record.state = "launchPending";
    record.result_code = "recoveryRequired";
    registry.Persist(record);
    // Recovery has no live authenticated caller from which to recapture
    // credentials and session environment. Consume the relaunch outcome
    // without retrying under helper/root credentials.
    record.state = "launchFailed";
    record.result_code = "relaunchFailure";
    registry.Persist(record);
    TestOnlyExitAfter(
        "DESKTOP_UPDATER_TEST_EXIT_AFTER_RECOVERY_TERMINAL_REGISTRY", 88);
    response.result_code = "relaunchFailure";
    response.verified_outcome = "newTarget";
    EmitLinuxHelperDiagnostic(broker_mode, stored_request, "completed",
                              "activation verified",
                              "recoveryPayloadIdentityMatched");
    EmitLinuxHelperDiagnostic(broker_mode, stored_request, "completed",
                              "transaction completed",
                              "recoveryCompleted");
    try {
      CleanupLinuxArchiveControl(
          target_parent.get(), control_leaf, archive_request,
          record.expected_payload_identity.stage_provenance_sha256);
      CleanupLinuxArchiveRestageRecord(target_parent.get(), archive_request);
    } catch (...) {
      EmitLinuxHelperDiagnostic(broker_mode, stored_request, "completed",
                                "recovery detected",
                                "terminalControlCleanupPending");
    }
  } else if (outcome == LinuxRecoveryOutcome::kLiveOwner) {
    record.state = "recoveryRequired";
    record.result_code = "recoveryRequired";
    response.result_code = "recoveryRequired";
    response.verified_outcome = "none";
  } else if (!journal_exists &&
             outcome == LinuxRecoveryOutcome::kNothingToRecover) {
    const bool target_is_new = VerifiedPayloadMatches(
        &verifier, target_parent.get(), target_path.filename().string(),
        record.expected_payload_identity);
    const bool stage_exists =
        LinuxRelativeExistsNoFollow(target_parent.get(), payload_leaf);
    const bool stage_is_new = stage_exists && VerifiedPayloadMatches(
        &verifier, target_parent.get(), payload_leaf,
        record.expected_payload_identity);
    const bool target_is_old = InstalledTargetIdentityMatches(
        target_parent.get(), target_path.filename().string(), stored_request);
    if (target_is_new && !stage_exists) {
      record.state = "launchPending";
      record.result_code = "recoveryRequired";
      registry.Persist(record);
      record.state = "launchFailed";
      record.result_code = "relaunchFailure";
      registry.Persist(record);
      TestOnlyExitAfter(
          "DESKTOP_UPDATER_TEST_EXIT_AFTER_RECOVERY_TERMINAL_REGISTRY", 88);
      response.result_code = "relaunchFailure";
      response.verified_outcome = "newTarget";
      try {
        CleanupLinuxArchiveControl(
            target_parent.get(), control_leaf, archive_request,
            record.expected_payload_identity.stage_provenance_sha256);
        CleanupLinuxArchiveRestageRecord(target_parent.get(), archive_request);
      } catch (...) {
        EmitLinuxHelperDiagnostic(broker_mode, stored_request, "completed",
                                  "recovery detected",
                                  "terminalControlCleanupPending");
      }
    } else if (!target_is_new && target_is_old &&
               (!stage_exists || stage_is_new)) {
      if (stage_exists) {
        const LinuxFileIdentity stage_identity =
            ReadLinuxRelativeIdentity(target_parent.get(), payload_leaf);
        RemoveLinuxTreeExact(target_parent.get(), payload_leaf, stage_identity);
        SyncLinuxDirectory(target_parent.get());
      }
      record.state = "rolledBack";
      record.result_code = "rolledBack";
      registry.Persist(record);
      response.result_code = "rolledBack";
      response.verified_outcome = "oldTarget";
      try {
        CleanupLinuxArchiveControl(
            target_parent.get(), control_leaf, archive_request,
            record.expected_payload_identity.stage_provenance_sha256);
        CleanupLinuxArchiveRestageRecord(target_parent.get(), archive_request);
      } catch (...) {
        EmitLinuxHelperDiagnostic(broker_mode, stored_request, "rolledBack",
                                  "recovery detected",
                                  "terminalControlCleanupPending");
      }
    } else {
      record.state = "manualActionRequired";
      record.result_code = "manualActionRequired";
      response.result_code = "manualActionRequired";
      response.verified_outcome = "none";
    }
  } else {
    record.state = "manualActionRequired";
    record.result_code = "manualActionRequired";
    response.result_code = "manualActionRequired";
    response.verified_outcome = "none";
    EmitLinuxHelperDiagnostic(broker_mode, stored_request,
                              "manualActionRequired",
                              "manual action required",
                              "recoveryObservationAmbiguous");
  }
  if (record.state != "completed" && record.state != "rolledBack") {
    registry.Persist(record);
  }
  channel.WriteFrame(
      runtime::internal::EncodeNativeInstallRecoveryResultV1(response));
}

}  // namespace desktop_updater::helper
