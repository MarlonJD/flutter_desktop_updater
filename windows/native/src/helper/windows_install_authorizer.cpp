#include "windows_install_authorizer.h"

#include <windows.h>

#include <aclapi.h>
#include <bcrypt.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdint>
#include <cwctype>
#include <exception>
#include <filesystem>
#include <limits>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "helper_authenticode.h"
#include "json_value.h"
#include "windows_file_transaction.h"
#include "windows_archive_restage.h"
#include "windows_helper_bootstrap.h"
#include "windows_helper_diagnostics.h"
#include "windows_persistent_recovery.h"
#include "windows_recovery_host.h"
#include "windows_relaunch_service.h"
#include "windows_one_shot_transport.h"
#include "windows_portable_transaction_index.h"
#include "windows_uninstall_record_proof.h"

namespace desktop_updater::helper {
namespace {

DWORD RetainedProcessId(HANDLE process) {
  const DWORD process_id = GetProcessId(process);
  if (process_id == 0) {
    throw std::runtime_error("retained caller process ID is unavailable");
  }
  return process_id;
}

std::filesystem::path RetainedProcessExecutablePath(HANDLE process) {
  std::vector<wchar_t> buffer(32768);
  DWORD length = static_cast<DWORD>(buffer.size());
  if (!QueryFullProcessImageNameW(process, 0, buffer.data(), &length) ||
      length == 0 || length >= buffer.size()) {
    throw std::runtime_error(
        "retained caller executable path is unavailable");
  }
  return std::filesystem::path(std::wstring(buffer.data(), length));
}

using desktop_updater::runtime::internal::AuthorizedNativeInstallRequestV1;
using desktop_updater::runtime::internal::AuthorizeNativeInstallTransactionRequestV1;
using desktop_updater::runtime::internal::EncodeCanonicalJson;
using desktop_updater::runtime::internal::JsonValue;
using desktop_updater::runtime::internal::NativeInstallAuthorizationPolicyV1;
using desktop_updater::runtime::internal::NativeInstallPreparedTransactionV1;
using desktop_updater::runtime::internal::NativeInstallTransactionRequestV1;
using desktop_updater::runtime::internal::ParseJson;
using desktop_updater::runtime::internal::StageBytesToHex;
using desktop_updater::runtime::internal::StageProvenanceMarker;
using desktop_updater::runtime::internal::StageProvenanceState;
using desktop_updater::runtime::internal::VerifyStageProvenance;

constexpr std::size_t kMaximumHelperMetadataBytes = 16 * 1024 * 1024;

class ScopedWindowsHelperFailureEvent final {
 public:
  explicit ScopedWindowsHelperFailureEvent(WindowsHelperEvent event)
      : event_(event), uncaught_exceptions_(std::uncaught_exceptions()) {}

  ~ScopedWindowsHelperFailureEvent() {
    if (std::uncaught_exceptions() > uncaught_exceptions_) {
      RecordWindowsHelperEvent(event_);
    }
  }

  void Advance(WindowsHelperEvent event) noexcept { event_ = event; }

 private:
  WindowsHelperEvent event_;
  int uncaught_exceptions_;
};

[[noreturn]] void Fail(const std::string& detail) {
  throw desktop_updater::runtime::internal::NativeInstallAuthorizationError(
      detail);
}

std::wstring Utf8ToWide(const std::string& value, const char* field) {
  if (value.empty() ||
      value.size() > static_cast<std::size_t>(
                         std::numeric_limits<int>::max())) {
    Fail(std::string(field) + " is invalid UTF-8");
  }
  const int length = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (length <= 0) Fail(std::string(field) + " is invalid UTF-8");
  std::wstring result(static_cast<std::size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          length) != length) {
    Fail(std::string(field) + " UTF-8 conversion failed");
  }
  return result;
}

std::vector<std::uint8_t> BCryptSha256Bytes(const std::string& bytes) {
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  DWORD object_size = 0;
  DWORD received = 0;
  std::vector<unsigned char> object;
  std::vector<std::uint8_t> digest(32);
  auto cleanup = [&]() {
    if (hash != nullptr) BCryptDestroyHash(hash);
    if (algorithm != nullptr) BCryptCloseAlgorithmProvider(algorithm, 0);
  };
  auto fail = [&]() -> void {
    cleanup();
    Fail("Windows helper SHA-256 failed");
  };
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                  nullptr, 0) < 0 ||
      BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
                        reinterpret_cast<PUCHAR>(&object_size),
                        sizeof(object_size), &received, 0) < 0) {
    fail();
  }
  object.resize(object_size);
  if (BCryptCreateHash(algorithm, &hash, object.data(), object_size, nullptr,
                       0, 0) < 0) {
    fail();
  }
  std::size_t offset = 0;
  while (offset < bytes.size()) {
    const ULONG length = static_cast<ULONG>(std::min<std::size_t>(
        bytes.size() - offset,
        static_cast<std::size_t>(std::numeric_limits<ULONG>::max())));
    if (BCryptHashData(
            hash,
            reinterpret_cast<PUCHAR>(
                const_cast<char*>(bytes.data() + offset)),
            length, 0) < 0) {
      fail();
    }
    offset += length;
  }
  if (BCryptFinishHash(hash, digest.data(),
                       static_cast<ULONG>(digest.size()), 0) < 0) {
    fail();
  }
  cleanup();
  return digest;
}

std::string BCryptSha256Hex(const std::string& bytes) {
  return StageBytesToHex(BCryptSha256Bytes(bytes));
}

std::string ReadRegularFileNoReparse(const std::filesystem::path& path,
                                     std::size_t maximum_bytes) {
  UniqueWindowsHandle file(CreateFileW(
      path.c_str(), GENERIC_READ | FILE_READ_ATTRIBUTES, FILE_SHARE_READ,
      nullptr, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (!file.valid()) Fail("helper metadata file is unavailable");
  BY_HANDLE_FILE_INFORMATION information{};
  if (!GetFileInformationByHandle(file.get(), &information) ||
      (information.dwFileAttributes &
       (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0 ||
      information.nFileSizeHigh != 0 ||
      information.nFileSizeLow > maximum_bytes) {
    Fail("helper metadata file is not a bounded regular file");
  }
  std::string result(information.nFileSizeLow, '\0');
  std::size_t offset = 0;
  while (offset < result.size()) {
    DWORD count = 0;
    const DWORD requested = static_cast<DWORD>(std::min<std::size_t>(
        result.size() - offset, 64 * 1024));
    if (!ReadFile(file.get(), result.data() + offset, requested, &count,
                  nullptr) ||
        count == 0 || count > requested) {
      Fail("helper metadata file read failed");
    }
    offset += count;
  }
  return result;
}

std::wstring NormalizePath(std::filesystem::path path) {
  std::wstring value = path.lexically_normal().wstring();
  if (value.rfind(L"\\\\?\\", 0) == 0) value.erase(0, 4);
  std::replace(value.begin(), value.end(), L'/', L'\\');
  std::transform(value.begin(), value.end(), value.begin(),
                 [](wchar_t character) { return std::towlower(character); });
  while (value.size() > 3 && value.back() == L'\\') value.pop_back();
  return value;
}

bool IsAtOrUnder(const std::filesystem::path& child,
                 const std::filesystem::path& root) {
  const std::wstring child_value = NormalizePath(child);
  const std::wstring root_value = NormalizePath(root);
  return !root_value.empty() &&
         (child_value == root_value ||
          (child_value.size() > root_value.size() &&
           child_value.compare(0, root_value.size(), root_value) == 0 &&
           child_value[root_value.size()] == L'\\'));
}

void ValidateRetainedCaller(
    HANDLE caller_process,
    const std::filesystem::path& target,
    const NativeInstallTransactionRequestV1& request,
    const WindowsHelperPolicy& policy) {
  const DWORD retained_process_id = RetainedProcessId(caller_process);
  if (request.caller.process_id !=
      static_cast<std::int64_t>(retained_process_id)) {
    Fail("caller process ID does not match the retained pipe server");
  }
  const std::uint64_t start_identity_before =
      WindowsProcessStartIdentity(caller_process);
  if (request.caller.process_start_identity !=
      WindowsProcessStartIdentityString(start_identity_before)) {
    Fail("caller process start identity changed");
  }
  if (request.package_id != policy.application_package_id() ||
      request.caller.package_id != request.package_id) {
    Fail("caller package or signer binding is rejected");
  }

  const std::filesystem::path executable_path =
      RetainedProcessExecutablePath(caller_process);
  const VerifiedWindowsExecutable executable =
      VerifyWindowsExecutable(executable_path);
  const std::filesystem::path expected_executable =
      target / Utf8ToWide(request.target.executable_relative_path,
                          "target executable");
  const bool signer_matches =
      policy.is_portable()
          ? policy.application_signer_kind() == "sha256" &&
                executable.sha256 == policy.application_signer_identity() &&
                executable.publisher == Utf8ToWide(
                                            request.caller.signer_identity,
                                            "caller signer")
          : request.caller.signer_identity ==
                    policy.application_publisher() &&
                executable.publisher ==
                    Utf8ToWide(policy.application_publisher(),
                               "application publisher");
  if (!executable.signature_valid ||
      !signer_matches ||
      executable.sha256 != request.caller.executable_sha256 ||
      NormalizePath(executable.final_path) !=
          NormalizePath(expected_executable) ||
      !VerifyWindowsExecutableStillMatches(executable_path, executable) ||
      WindowsProcessStartIdentity(caller_process) != start_identity_before ||
      RetainedProcessId(caller_process) != retained_process_id) {
    Fail("retained caller executable identity is rejected");
  }
}

std::filesystem::path CanonicalDirectory(const std::string& encoded,
                                         const char* field) {
  const std::filesystem::path path =
      std::filesystem::path(Utf8ToWide(encoded, field));
  std::error_code error;
  const std::filesystem::path canonical =
      std::filesystem::canonical(path, error);
  if (error || canonical.empty() ||
      !std::filesystem::is_directory(canonical, error) || error) {
    Fail(std::string(field) + " is not a canonical directory");
  }
  return canonical;
}

void ValidateRelativeExecutable(const std::filesystem::path& path) {
  if (path.empty() || path.is_absolute() || path.has_root_name() ||
      path.lexically_normal() != path) {
    Fail("target executable path is not canonical relative");
  }
  for (const auto& component : path) {
    if (component.empty() || component == L"." || component == L"..") {
      Fail("target executable path escapes target");
    }
  }
}

enum class CallerDirectoryAccessResult {
  kGranted,
  kDirectoryHandleFailure,
  kSecurityDescriptorFailure,
  kCallerTokenFailure,
  kImpersonationTokenFailure,
  kAccessCheckFailure,
  kAccessDenied,
};

WindowsHelperEvent DirectoryAccessFailureEvent(
    CallerDirectoryAccessResult result) {
  switch (result) {
    case CallerDirectoryAccessResult::kDirectoryHandleFailure:
      return WindowsHelperEvent::kPortableDirectoryHandleFailure;
    case CallerDirectoryAccessResult::kSecurityDescriptorFailure:
      return WindowsHelperEvent::kPortableSecurityDescriptorFailure;
    case CallerDirectoryAccessResult::kCallerTokenFailure:
      return WindowsHelperEvent::kPortableCallerTokenFailure;
    case CallerDirectoryAccessResult::kImpersonationTokenFailure:
      return WindowsHelperEvent::kPortableImpersonationTokenFailure;
    case CallerDirectoryAccessResult::kAccessCheckFailure:
      return WindowsHelperEvent::kPortableAccessCheckFailure;
    case CallerDirectoryAccessResult::kAccessDenied:
      return WindowsHelperEvent::kPortableDirectoryAccessDenied;
    case CallerDirectoryAccessResult::kGranted:
      break;
  }
  return WindowsHelperEvent::kPortableAccessCheckFailure;
}

CallerDirectoryAccessResult CallerTokenDirectoryAccess(
    const std::filesystem::path& path,
    HANDLE caller_process,
    DWORD desired_access) {
  UniqueWindowsHandle directory(CreateFileW(
      path.c_str(), READ_CONTROL | FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (!directory.valid()) {
    return CallerDirectoryAccessResult::kDirectoryHandleFailure;
  }
  BY_HANDLE_FILE_INFORMATION information{};
  if (!GetFileInformationByHandle(directory.get(), &information) ||
      (information.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
      (information.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    return CallerDirectoryAccessResult::kDirectoryHandleFailure;
  }

  PSECURITY_DESCRIPTOR raw_descriptor = nullptr;
  PACL dacl = nullptr;
  const DWORD security = GetSecurityInfo(
      directory.get(), SE_FILE_OBJECT, DACL_SECURITY_INFORMATION, nullptr,
      nullptr, &dacl, nullptr, &raw_descriptor);
  if (security != ERROR_SUCCESS || raw_descriptor == nullptr) {
    if (raw_descriptor != nullptr) LocalFree(raw_descriptor);
    return CallerDirectoryAccessResult::kSecurityDescriptorFailure;
  }
  std::unique_ptr<void, decltype(&LocalFree)> descriptor(raw_descriptor,
                                                         LocalFree);
  HANDLE raw_token = nullptr;
  if (!OpenProcessToken(caller_process, TOKEN_QUERY | TOKEN_DUPLICATE,
                        &raw_token)) {
    return CallerDirectoryAccessResult::kCallerTokenFailure;
  }
  UniqueWindowsHandle token(raw_token);
  HANDLE raw_impersonation = nullptr;
  if (!DuplicateToken(token.get(), SecurityImpersonation,
                      &raw_impersonation)) {
    return CallerDirectoryAccessResult::kImpersonationTokenFailure;
  }
  UniqueWindowsHandle impersonation(raw_impersonation);
  GENERIC_MAPPING mapping{FILE_GENERIC_READ, FILE_GENERIC_WRITE,
                          FILE_GENERIC_EXECUTE, FILE_ALL_ACCESS};
  MapGenericMask(&desired_access, &mapping);
  std::vector<unsigned char> privileges(4096);
  DWORD privileges_size = static_cast<DWORD>(privileges.size());
  DWORD granted = 0;
  BOOL access = FALSE;
  if (!AccessCheck(
          raw_descriptor, impersonation.get(), desired_access, &mapping,
          reinterpret_cast<PRIVILEGE_SET*>(privileges.data()),
          &privileges_size, &granted, &access)) {
    return CallerDirectoryAccessResult::kAccessCheckFailure;
  }
  return access == TRUE && (granted & desired_access) == desired_access
             ? CallerDirectoryAccessResult::kGranted
             : CallerDirectoryAccessResult::kAccessDenied;
}

void ValidatePortableWindowsTargetAuthority(
    const std::filesystem::path& target,
    const std::filesystem::path& caller_executable,
    HANDLE caller_process,
    ScopedWindowsHelperFailureEvent* failure_stage) {
  constexpr DWORD kTargetAccess =
      FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE;
  constexpr DWORD kParentAccess =
      GENERIC_READ | GENERIC_WRITE | FILE_TRAVERSE | FILE_DELETE_CHILD |
      SYNCHRONIZE;
  const CallerDirectoryAccessResult target_access =
      CallerTokenDirectoryAccess(target, caller_process, kTargetAccess);
  const CallerDirectoryAccessResult parent_access = CallerTokenDirectoryAccess(
      target.parent_path(), caller_process, kParentAccess);
  const bool target_writable =
      target_access == CallerDirectoryAccessResult::kGranted;
  const bool parent_writable =
      parent_access == CallerDirectoryAccessResult::kGranted;
  const std::filesystem::path executable_path(caller_executable);
  if (failure_stage != nullptr) {
    if (target.empty() || executable_path.empty() ||
        target.filename().empty() || executable_path.filename().empty() ||
        NormalizePath(target) !=
            NormalizePath(executable_path.parent_path())) {
      failure_stage->Advance(
          WindowsHelperEvent::kPortableTargetCallerRootFailure);
    } else if (!target_writable) {
      failure_stage->Advance(
          WindowsHelperEvent::kPortableTargetReadAuthorityFailure);
      RecordWindowsHelperEvent(DirectoryAccessFailureEvent(target_access));
    } else if (!parent_writable) {
      failure_stage->Advance(
          WindowsHelperEvent::kPortableParentMutationAuthorityFailure);
      RecordWindowsHelperEvent(DirectoryAccessFailureEvent(parent_access));
    }
  }
  ValidatePortableWindowsTargetAuthorityFacts(
      target.wstring(), caller_executable.wstring(), target_writable,
      parent_writable);
}

void ValidateTargetAuthority(const std::filesystem::path& target,
                             const NativeInstallTransactionRequestV1& request,
                             const WindowsHelperPolicy& policy,
                             HANDLE caller_process,
                             ScopedWindowsHelperFailureEvent* failure_stage =
                                 nullptr) {
  if (!policy.is_portable()) {
    const bool allowed_root = std::any_of(
        policy.allowed_install_roots().begin(),
        policy.allowed_install_roots().end(),
        [&](const std::wstring& root) {
          return IsAtOrUnder(target, std::filesystem::path(root));
        });
    if (!allowed_root) Fail("target is outside sealed install roots");
  }
  const std::wstring expected_name =
      Utf8ToWide(request.target.target_name_hint, "target name");
  if (_wcsicmp(target.filename().c_str(), expected_name.c_str()) != 0) {
    Fail("target name hint changed");
  }

  const std::filesystem::path executable_relative =
      std::filesystem::path(Utf8ToWide(
          request.target.executable_relative_path, "target executable"));
  ValidateRelativeExecutable(executable_relative);
  if (failure_stage != nullptr) {
    failure_stage->Advance(
        WindowsHelperEvent::kPortableTargetExecutableIdentityFailure);
  }
  const std::filesystem::path executable_path = target / executable_relative;
  const VerifiedWindowsExecutable executable =
      VerifyWindowsExecutable(executable_path);
  const bool signer_matches =
      policy.is_portable()
          ? policy.application_signer_kind() == "sha256" &&
                executable.sha256 == policy.application_signer_identity() &&
                executable.publisher == Utf8ToWide(
                                            request.caller.signer_identity,
                                            "caller signer")
          : executable.publisher ==
                Utf8ToWide(policy.application_publisher(),
                           "application publisher");
  if (!executable.signature_valid ||
      !signer_matches ||
      !VerifyWindowsExecutableStillMatches(executable_path, executable)) {
    Fail("installed executable Authenticode identity mismatch");
  }

  if (policy.is_portable()) {
    if (failure_stage != nullptr) {
      failure_stage->Advance(
          WindowsHelperEvent::kPortableTargetCallerRootFailure);
    }
    ValidatePortableWindowsTargetAuthority(
        target, RetainedProcessExecutablePath(caller_process),
        caller_process, failure_stage);
  }

  if (!policy.is_portable()) {
    const auto registry_proof = FindCanonicalWindowsUninstallRecordProof(
        target, request.package_id, caller_process);
    if (registry_proof.has_value() &&
        BCryptSha256Hex(*registry_proof) ==
            request.target.identity_proof_sha256) {
      return;
    }
  }

  if (failure_stage != nullptr) {
    failure_stage->Advance(
        WindowsHelperEvent::kPortableTargetMarkerFailure);
  }
  const std::string marker = ReadRegularFileNoReparse(
      target / L".desktop_updater_install_identity.json", 64 * 1024);
  const JsonValue marker_value = ParseJson(marker);
  const auto& marker_object = marker_value.object();
  if (marker_object.size() != 2 ||
      marker_object.find("packageId") == marker_object.end() ||
      marker_object.find("schemaVersion") == marker_object.end() ||
      marker_value.at("schemaVersion").integer() != 1 ||
      marker_value.at("packageId").string() != request.package_id ||
      EncodeCanonicalJson(marker_value) != marker ||
      BCryptSha256Hex(marker) != request.target.identity_proof_sha256) {
    Fail("installed target identity marker mismatch");
  }
}

class WindowsPortableDirectoryPreparedTransaction final
    : public NativeInstallPreparedTransactionV1 {
 public:
  WindowsPortableDirectoryPreparedTransaction(
      std::filesystem::path target_path,
      WindowsVerifiedArchiveRestage restage,
      std::string transaction_id,
      WindowsVerifiedPayloadIdentity expected_payload_identity,
      const WindowsHelperPolicy& policy,
      PortableWindowsRecoveryHostEndpointV1 endpoint,
      HANDLE caller_process)
      : target_path_(std::move(target_path)),
        transaction_id_(std::move(transaction_id)),
        policy_(policy),
        endpoint_(std::move(endpoint)),
        recovery_ready_nonce_(SecureWindowsReadyToken()),
        recovery_host_definition_(
            BuildPortableWindowsRecoveryHostTaskDefinition(
                endpoint_, transaction_id_, recovery_ready_nonce_)),
        executor_process_id_(GetCurrentProcessId()),
        executor_process_start_identity_(
            WindowsProcessStartIdentity(GetCurrentProcess())),
        caller_process_id_(GetProcessId(caller_process)),
        caller_process_start_identity_(
            WindowsProcessStartIdentity(caller_process)),
        caller_process_(caller_process),
        index_(policy_, caller_process),
        restage_(std::move(restage)),
        verifier_(expected_payload_identity),
        transaction_(target_path_, restage_.path(), transaction_id_,
                     executor_process_id_, expected_payload_identity,
                     verifier_, restage_.parent_handle(),
                     restage_.root_handle(), nullptr,
                     {[this]() {
                        index_.PersistCleanupPending(
                            transaction_id_, "completedCleanupPending",
                            "newTarget");
                      },
                      [this]() {
                        index_.PersistTerminal(transaction_id_, "completed",
                                               "newTarget");
                      },
                      [this]() {
                        index_.PersistCleanupPending(
                            transaction_id_, "rolledBackCleanupPending",
                            "oldTarget");
                      },
                      [this]() {
                        index_.PersistTerminal(transaction_id_, "rolledBack",
                                               "oldTarget");
                        DisarmRecoveryHost();
                      }},
                     executor_process_start_identity_, {}, [this]() {
                       restage_.ReleaseToTransaction();
                     }),
        launcher_(caller_process),
        relaunch_service_(std::move(expected_payload_identity), verifier_,
                          launcher_) {}

  const std::string& transaction_id() const override {
    return transaction_id_;
  }

  std::string PrepareDurableJournal() override {
    const ScopedWindowsHelperFailureEvent failure_event(
        WindowsHelperEvent::kPortablePreparationFailure);
    const std::string frozen = transaction_.initial_journal_canonical();
    return RunPortableWindowsRecoveryPrepareBoundary(
        [this, &frozen]() {
          BindWindowsPortableTransactionEndpoint(
              transaction_id_, policy_, endpoint_, caller_process_);
          index_.PersistPreparing(transaction_id_, target_path_, frozen,
                                  executor_process_id_,
                                  executor_process_start_identity_,
                                  caller_process_id_,
                                  caller_process_start_identity_,
                                  recovery_ready_nonce_);
        },
        [this]() {
          recovery_host_.ArmAndStart(recovery_host_definition_, 30'000);
          recovery_host_armed_ = true;
        },
        [this]() {
          transaction_.Prepare();
          const std::string prepared =
              transaction_.prepared_journal_canonical();
          index_.PersistActive(transaction_id_, prepared);
          return prepared;
        });
  }

  void MarkCommitAccepted() override {
    index_.MarkCommitAccepted(transaction_id_);
    transaction_.MarkCommitAccepted();
  }

  void ExecuteAfterCallerExit() override {
    (void)transaction_.ExecutePrepared();
    WindowsPersistentResolverClaim claim{
        WindowsPersistentResolverClaim::kSchemaVersion,
        transaction_id_,
        static_cast<std::int64_t>(executor_process_id_),
        static_cast<std::int64_t>(executor_process_start_identity_),
        static_cast<std::int64_t>(caller_process_id_),
        static_cast<std::int64_t>(caller_process_start_identity_),
        SecureWindowsReadyToken(),
        "claimed"};
    if (index_.ClaimResolver(claim) != WindowsResolverClaimDecision::kOwn) {
      throw WindowsRelaunchError(
          "portable relaunch attempt is owned by another resolver");
    }
    const WindowsAtMostOnceRelaunchOutcome outcome =
        RunWindowsAtMostOnceRelaunch(
            [this, &claim]() { return index_.ConsumeResolverClaim(claim); },
            [this]() { index_.MarkRelaunchAttempting(transaction_id_); },
            [this]() { relaunch_service_.Relaunch(target_path_); },
            [this](bool launched) {
              index_.PersistRelaunchOutcome(transaction_id_, launched);
            });
    if (outcome == WindowsAtMostOnceRelaunchOutcome::kNotOwned) {
      throw WindowsRelaunchError(
          "portable relaunch attempt claim is unavailable");
    }
    DisarmRecoveryHost();
    if (outcome == WindowsAtMostOnceRelaunchOutcome::kFailed) {
      throw WindowsRelaunchError("portable relaunch attempt failed");
    }
  }

  void CancelPrepared() override {
    index_.MarkCancelling(transaction_id_);
    transaction_.CancelPrepared();
  }

 private:
  void DisarmRecoveryHost() noexcept {
    if (!recovery_host_armed_) return;
    try {
      recovery_host_.Disarm(recovery_host_definition_);
      recovery_host_armed_ = false;
    } catch (...) {
      // The stable exact-user host keeps the durable logon task armed until
      // it observes and verifies the already-terminal persistent record.
    }
  }

  std::filesystem::path target_path_;
  std::string transaction_id_;
  WindowsHelperPolicy policy_;
  PortableWindowsRecoveryHostEndpointV1 endpoint_;
  std::string recovery_ready_nonce_;
  PortableWindowsRecoveryHostTaskDefinition recovery_host_definition_;
  TaskSchedulerPortableWindowsRecoveryHostController recovery_host_;
  DWORD executor_process_id_;
  std::uint64_t executor_process_start_identity_;
  DWORD caller_process_id_;
  std::uint64_t caller_process_start_identity_;
  HANDLE caller_process_;
  bool recovery_host_armed_ = false;
  WindowsPersistentTransactionIndex index_;
  WindowsVerifiedArchiveRestage restage_;
  AuthenticodeWindowsPayloadVerifier verifier_;
  WindowsFileTransaction transaction_;
  CallerTokenWindowsLauncher launcher_;
  WindowsRelaunchService relaunch_service_;
};

class WindowsDirectoryPreparedTransaction final
    : public NativeInstallPreparedTransactionV1 {
 public:
  WindowsDirectoryPreparedTransaction(
      std::filesystem::path target_path,
      WindowsVerifiedArchiveRestage restage,
      std::string transaction_id,
      WindowsVerifiedPayloadIdentity expected_payload_identity,
      const WindowsHelperPolicy& policy,
      ProtectedWindowsHelperEndpointV1 endpoint,
      HANDLE caller_process)
      : target_path_(std::move(target_path)),
        transaction_id_(std::move(transaction_id)),
        endpoint_(std::move(endpoint)),
        recovery_ready_nonce_(SecureWindowsReadyToken()),
        recovery_host_definition_(BuildWindowsRecoveryHostTaskDefinition(
            endpoint_, transaction_id_, recovery_ready_nonce_)),
        executor_process_id_(GetCurrentProcessId()),
        executor_process_start_identity_(
            WindowsProcessStartIdentity(GetCurrentProcess())),
        caller_process_id_(GetProcessId(caller_process)),
        caller_process_start_identity_(
            WindowsProcessStartIdentity(caller_process)),
        index_(policy, caller_process),
        restage_(std::move(restage)),
        verifier_(expected_payload_identity),
        transaction_(target_path_, restage_.path(), transaction_id_,
                     executor_process_id_,
                     expected_payload_identity,
                     verifier_, restage_.parent_handle(),
                     restage_.root_handle(), nullptr,
                     {[this]() {
                        index_.PersistCleanupPending(
                            transaction_id_, "completedCleanupPending",
                            "newTarget");
                      },
                      [this]() {
                        index_.PersistTerminal(transaction_id_, "completed",
                                               "newTarget");
                      },
                      [this]() {
                        index_.PersistCleanupPending(
                            transaction_id_, "rolledBackCleanupPending",
                            "oldTarget");
                      },
                      [this]() {
                        index_.PersistTerminal(transaction_id_, "rolledBack",
                                               "oldTarget");
                        DisarmRecoveryHost();
                      }},
                     executor_process_start_identity_,
                     [](HANDLE directory) {
                       FlushWindowsVolume(directory);
                     },
                     [this]() {
                       restage_.ReleaseToTransaction();
                     }),
        launcher_(caller_process),
        relaunch_service_(std::move(expected_payload_identity), verifier_,
                          launcher_) {}

  const std::string& transaction_id() const override {
    return transaction_id_;
  }

  std::string PrepareDurableJournal() override {
    const std::string frozen = transaction_.initial_journal_canonical();
    BindProtectedWindowsTransactionEndpoint(transaction_id_, endpoint_);
    index_.PersistPreparing(transaction_id_, target_path_, frozen,
                            executor_process_id_,
                            executor_process_start_identity_,
                            caller_process_id_,
                            caller_process_start_identity_,
                            recovery_ready_nonce_);
    recovery_host_.ArmAndStart(recovery_host_definition_, 30'000);
    recovery_host_armed_ = true;
    transaction_.Prepare();
    const std::string prepared = transaction_.prepared_journal_canonical();
    index_.PersistActive(transaction_id_, prepared);
    return prepared;
  }

  void MarkCommitAccepted() override {
    index_.MarkCommitAccepted(transaction_id_);
  }

  void ExecuteAfterCallerExit() override {
    (void)transaction_.ExecutePrepared();
    WindowsPersistentResolverClaim claim{
        WindowsPersistentResolverClaim::kSchemaVersion,
        transaction_id_,
        static_cast<std::int64_t>(executor_process_id_),
        static_cast<std::int64_t>(executor_process_start_identity_),
        static_cast<std::int64_t>(caller_process_id_),
        static_cast<std::int64_t>(caller_process_start_identity_),
        SecureWindowsReadyToken(),
        "claimed"};
    if (index_.ClaimResolver(claim) != WindowsResolverClaimDecision::kOwn) {
      throw WindowsRelaunchError(
          "protected relaunch attempt is owned by another resolver");
    }
    const WindowsAtMostOnceRelaunchOutcome outcome =
        RunWindowsAtMostOnceRelaunch(
            [this, &claim]() { return index_.ConsumeResolverClaim(claim); },
            [this]() { index_.MarkRelaunchAttempting(transaction_id_); },
            [this]() { relaunch_service_.Relaunch(target_path_); },
            [this](bool launched) {
              index_.PersistRelaunchOutcome(transaction_id_, launched);
            });
    if (outcome == WindowsAtMostOnceRelaunchOutcome::kNotOwned) {
      throw WindowsRelaunchError(
          "protected relaunch attempt claim is unavailable");
    }
    DisarmRecoveryHost();
    if (outcome == WindowsAtMostOnceRelaunchOutcome::kFailed) {
      throw WindowsRelaunchError("protected relaunch attempt failed");
    }
  }

  void CancelPrepared() override {
    index_.MarkCancelling(transaction_id_);
    transaction_.CancelPrepared();
  }

 private:
  void DisarmRecoveryHost() noexcept {
    if (!recovery_host_armed_) return;
    try {
      recovery_host_.Disarm(recovery_host_definition_);
    } catch (...) {
      // The running SYSTEM instance will remove the task after observing this
      // already-durable terminal record.
    }
    recovery_host_armed_ = false;
  }

  std::filesystem::path target_path_;
  std::string transaction_id_;
  ProtectedWindowsHelperEndpointV1 endpoint_;
  std::string recovery_ready_nonce_;
  WindowsRecoveryHostTaskDefinition recovery_host_definition_;
  TaskSchedulerWindowsRecoveryHostController recovery_host_;
  DWORD executor_process_id_;
  std::uint64_t executor_process_start_identity_;
  DWORD caller_process_id_;
  std::uint64_t caller_process_start_identity_;
  bool recovery_host_armed_ = false;
  WindowsPersistentTransactionIndex index_;
  WindowsVerifiedArchiveRestage restage_;
  AuthenticodeWindowsPayloadVerifier verifier_;
  WindowsFileTransaction transaction_;
  CallerTokenWindowsLauncher launcher_;
  WindowsRelaunchService relaunch_service_;
};

}  // namespace

void ValidatePortableWindowsTargetAuthorityFacts(
    const std::wstring& target,
    const std::wstring& caller_executable,
    bool target_writable,
    bool parent_writable) {
  const std::filesystem::path target_path(target);
  const std::filesystem::path executable_path(caller_executable);
  if (target_path.empty() || executable_path.empty() ||
      target_path.filename().empty() || executable_path.filename().empty() ||
      NormalizePath(target_path) !=
          NormalizePath(executable_path.parent_path()) ||
      !target_writable || !parent_writable) {
    Fail("portable target is not the exact writable caller application root");
  }
}

NativeInstallAuthorizationPolicyV1
BuildWindowsNativeInstallAuthorizationPolicy(
    const WindowsHelperPolicy& policy) {
  NativeInstallAuthorizationPolicyV1 result;
  result.policy_id = policy.policy_id();
  result.application_package_id = policy.application_package_id();
  result.allowed_target_classes = policy.allowed_target_classes();
  result.minimum_helper_protocol_version =
      policy.minimum_helper_protocol_version();
  result.release_root_public_keys.reserve(
      policy.release_root_public_keys().size());
  for (const auto& key : policy.release_root_public_keys()) {
    result.release_root_public_keys.push_back(
        {key.key_id, key.algorithm, key.public_key_base64});
  }
  result.allowed_strategies.reserve(policy.allowed_strategies().size());
  for (const auto& strategy : policy.allowed_strategies()) {
    result.allowed_strategies.push_back(
        {strategy.strategy, strategy.provider});
  }
  return result;
}

WindowsVerifiedPayloadIdentity BuildWindowsExpectedPayloadIdentity(
    const NativeInstallTransactionRequestV1& request,
    const StageProvenanceMarker& marker,
    const std::string& payload_seal_sha256,
    const WindowsHelperPolicy& policy) {
  if (payload_seal_sha256.size() != 64 ||
      !std::all_of(payload_seal_sha256.begin(),
                   payload_seal_sha256.end(), [](unsigned char value) {
                     return std::isdigit(value) != 0 ||
                            (value >= 'a' && value <= 'f');
                   })) {
    Fail("helper payload seal is invalid");
  }
  std::string executable_path = request.target.executable_relative_path;
  std::replace(executable_path.begin(), executable_path.end(), '\\', '/');
  const auto executable = std::find_if(
      marker.entries.begin(), marker.entries.end(),
      [&](const auto& entry) { return entry.path == executable_path; });
  if (executable == marker.entries.end() || executable->kind != "file" ||
      executable->length < 1 || executable->sha256.size() != 64 ||
      !std::all_of(executable->sha256.begin(), executable->sha256.end(),
                   [](unsigned char value) {
                     return std::isdigit(value) != 0 ||
                            (value >= 'a' && value <= 'f');
                   })) {
    Fail("staged executable is missing from frozen inventory");
  }
  return {
      request.package_id,
      policy.is_portable() ? request.caller.signer_identity
                           : policy.application_publisher(),
      request.signed_descriptor.canonical_sha256,
      request.stage.provenance_sha256,
      request.stage.artifact_sha256,
      Utf8ToWide(request.target.executable_relative_path,
                 "target executable"),
      executable->sha256,
      payload_seal_sha256,
  };
}

WindowsNativeInstallAuthorizer::WindowsNativeInstallAuthorizer(
    WindowsHelperPolicy policy,
    ProtectedWindowsHelperEndpointV1 endpoint,
    HANDLE caller_process)
    : policy_(std::move(policy)),
      endpoint_(std::move(endpoint)),
      caller_process_(caller_process) {
  if (policy_.is_portable() || caller_process_ == nullptr ||
      caller_process_ == INVALID_HANDLE_VALUE) {
    Fail("named-pipe caller process is invalid");
  }
}

const std::string&
WindowsNativeInstallAuthorizer::helper_endpoint_identity_sha256() const {
  return policy_.helper_sha256();
}

std::unique_ptr<NativeInstallPreparedTransactionV1>
WindowsNativeInstallAuthorizer::Authorize(
    const NativeInstallTransactionRequestV1& request) {
  if (request.strategy != "directoryReplace" ||
      request.provider != "platformDirectory") {
    Fail("Windows provider transaction is not directory replacement");
  }
  RecordWindowsHelperEvent(WindowsHelperEvent::kStagingPathValidation);
  const std::filesystem::path target =
      CanonicalDirectory(request.target.path_hint, "target path");
  const std::filesystem::path stage =
      CanonicalDirectory(request.stage.path_hint, "stage path");
  if (IsAtOrUnder(stage, target) || IsAtOrUnder(target, stage)) {
    Fail("stage and target paths overlap");
  }
  ValidateRetainedCaller(caller_process_, target, request, policy_);
  ValidateTargetAuthority(target, request, policy_, caller_process_);

  const StageProvenanceMarker marker = VerifyStageProvenance(
      stage, request.stage.provenance_sha256, BCryptSha256Bytes);
  const std::string release_manifest = ReadRegularFileNoReparse(
      stage / L".desktop_updater_release_manifest.json",
      kMaximumHelperMetadataBytes);
  const AuthorizedNativeInstallRequestV1 authorized =
      AuthorizeNativeInstallTransactionRequestV1(
          request, BuildWindowsNativeInstallAuthorizationPolicy(policy_),
          "windows", release_manifest, marker,
          request.stage.provenance_sha256, BCryptSha256Hex);
  if (authorized.descriptor.artifact.kind != "zip") {
    Fail("directory replacement requires a signed Windows ZIP descriptor");
  }
  WindowsVerifiedArchiveRestage restage = RestageVerifiedWindowsZip(
      stage, target.parent_path(), request.transaction_id,
      request.package_id, request.signed_descriptor.canonical_sha256,
      request.stage.artifact_sha256, request.stage.artifact_length,
      release_manifest, WindowsArchiveRestageAuthority::kInstallerProtected,
      caller_process_);
  WindowsVerifiedPayloadIdentity expected =
      BuildWindowsExpectedPayloadIdentity(
          request, restage.provenance(), restage.payload_seal_sha256(),
          policy_);
  return std::make_unique<WindowsDirectoryPreparedTransaction>(
      target, std::move(restage), request.transaction_id,
      std::move(expected), policy_, endpoint_, caller_process_);
}

WindowsPortableInstallAuthorizer::WindowsPortableInstallAuthorizer(
    WindowsHelperPolicy policy,
    PortableWindowsRecoveryHostEndpointV1 endpoint,
    HANDLE caller_process)
    : policy_(std::move(policy)),
      endpoint_(std::move(endpoint)),
      caller_process_(caller_process) {
  if (!policy_.is_portable() || caller_process_ == nullptr ||
      caller_process_ == INVALID_HANDLE_VALUE ||
      endpoint_.policy_id != policy_.policy_id() ||
      endpoint_.package_id != policy_.application_package_id() ||
      endpoint_.helper_sha256 != policy_.helper_sha256()) {
    Fail("portable named-pipe caller or policy is invalid");
  }
}

const std::string&
WindowsPortableInstallAuthorizer::helper_endpoint_identity_sha256() const {
  return policy_.helper_sha256();
}

std::unique_ptr<NativeInstallPreparedTransactionV1>
WindowsPortableInstallAuthorizer::Authorize(
    const NativeInstallTransactionRequestV1& request) {
  const ScopedWindowsHelperFailureEvent failure_event(
      WindowsHelperEvent::kPortableAuthorizationFailure);
  ScopedWindowsHelperFailureEvent authorization_stage(
      WindowsHelperEvent::kPortableRequestValidationFailure);
  if (request.target.target_class != "sameUserWritable" ||
      request.strategy != "directoryReplace" ||
      request.provider != "platformDirectory" ||
      !policy_.AllowsRequest(request.protocol_version,
                             request.target.target_class, request.strategy,
                             request.provider)) {
    Fail("portable Windows provider exceeds same-user directory authority");
  }
  RecordWindowsHelperEvent(WindowsHelperEvent::kStagingPathValidation);
  const std::filesystem::path target =
      CanonicalDirectory(request.target.path_hint, "target path");
  const std::filesystem::path stage =
      CanonicalDirectory(request.stage.path_hint, "stage path");
  if (IsAtOrUnder(stage, target) || IsAtOrUnder(target, stage)) {
    Fail("stage and target paths overlap");
  }
  RequirePortableWindowsRecoveryHostOutsideMutationRoots(endpoint_, target,
                                                         stage);
  authorization_stage.Advance(
      WindowsHelperEvent::kPortableCallerIdentityFailure);
  ValidateRetainedCaller(caller_process_, target, request, policy_);
  authorization_stage.Advance(
      WindowsHelperEvent::kPortableTargetAuthorityFailure);
  {
    ScopedWindowsHelperFailureEvent target_authority_stage(
        WindowsHelperEvent::kPortableTargetRequestFailure);
    ValidateTargetAuthority(target, request, policy_, caller_process_,
                            &target_authority_stage);
  }
  authorization_stage.Advance(
      WindowsHelperEvent::kPortableStageAuthorizationFailure);

  const StageProvenanceMarker marker = VerifyStageProvenance(
      stage, request.stage.provenance_sha256, BCryptSha256Bytes);
  const std::string release_manifest = ReadRegularFileNoReparse(
      stage / L".desktop_updater_release_manifest.json",
      kMaximumHelperMetadataBytes);
  const AuthorizedNativeInstallRequestV1 authorized =
      AuthorizeNativeInstallTransactionRequestV1(
          request, BuildWindowsNativeInstallAuthorizationPolicy(policy_),
          "windows", release_manifest, marker,
          request.stage.provenance_sha256, BCryptSha256Hex);
  if (authorized.descriptor.artifact.kind != "zip") {
    Fail("portable directory replacement requires a signed Windows ZIP");
  }
  WindowsVerifiedArchiveRestage restage = RestageVerifiedWindowsZip(
      stage, target.parent_path(), request.transaction_id,
      request.package_id, request.signed_descriptor.canonical_sha256,
      request.stage.artifact_sha256, request.stage.artifact_length,
      release_manifest, WindowsArchiveRestageAuthority::kPortableExactCaller,
      caller_process_);
  WindowsVerifiedPayloadIdentity expected =
      BuildWindowsExpectedPayloadIdentity(
          request, restage.provenance(), restage.payload_seal_sha256(),
          policy_);
  return std::make_unique<WindowsPortableDirectoryPreparedTransaction>(
      target, std::move(restage), request.transaction_id,
      std::move(expected), policy_, endpoint_, caller_process_);
}

}  // namespace desktop_updater::helper
