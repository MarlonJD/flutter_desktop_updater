#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_PORTABLE_TRANSACTION_INDEX_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_PORTABLE_TRANSACTION_INDEX_H_

#include <windows.h>

#include <cstdint>
#include <filesystem>
#include <memory>
#include <optional>
#include <string>

#include "helper_authenticode.h"
#include "helper_policy_windows.h"

namespace desktop_updater::helper {

struct PortableWindowsRecoveryHostEndpointV1;

struct WindowsPortableTransactionLocatorV1 {
  static constexpr std::int64_t kSchemaVersion = 1;

  std::int64_t schema_version = kSchemaVersion;
  std::string transaction_id;
  std::string index_binding_sha256;
  std::string policy_id;
  std::string package_id;
  std::string helper_sha256;
  std::string policy_sha256;

  std::string EncodeCanonical() const;
  static WindowsPortableTransactionLocatorV1 DecodeStrict(
      const std::string& canonical_json);
  bool operator==(const WindowsPortableTransactionLocatorV1& other) const;
};

struct ResolvedWindowsPortableTransactionEndpointV1 {
  WindowsPortableTransactionLocatorV1 locator;
  std::wstring user_sid;
  std::filesystem::path local_app_data_path;
  std::filesystem::path endpoint_path;
  std::filesystem::path helper_path;
  std::filesystem::path policy_path;
};

enum class WindowsPortableTransactionResolution {
  kVerifiedOriginalGeneration,
  kVerifiedSuccessor,
  kReject,
};

WindowsPortableTransactionLocatorV1 BuildWindowsPortableTransactionLocator(
    const std::string& transaction_id,
    const WindowsHelperPolicy& policy,
    const PortableWindowsRecoveryHostEndpointV1& endpoint);

void BindWindowsPortableTransactionEndpoint(
    const std::string& transaction_id,
    const WindowsHelperPolicy& policy,
    const PortableWindowsRecoveryHostEndpointV1& endpoint,
    HANDLE caller_process);

std::optional<ResolvedWindowsPortableTransactionEndpointV1>
LoadWindowsPortableTransactionEndpoint(const std::string& transaction_id);

WindowsPortableTransactionResolution
ResolveWindowsPortableTransactionAuthority(
    const WindowsPortableTransactionLocatorV1& locator,
    const WindowsHelperPolicy& frozen_policy,
    const std::string& transaction_id,
    const std::string& canonical_record,
    const VerifiedWindowsExecutable& caller_identity,
    const std::filesystem::path& observed_process_path,
    bool identity_still_matches);

WindowsPortableTransactionResolution
DecideWindowsPortableTransactionCallerAuthority(
    const WindowsHelperPolicy& frozen_policy,
    const std::string& transaction_id,
    const std::string& canonical_record,
    const VerifiedWindowsExecutable& caller_identity,
    const std::filesystem::path& observed_process_path,
    bool identity_still_matches);

enum class WindowsPortableTransactionProbe {
  kAbsent,
  kPresent,
  kBindingMismatch,
};

enum class WindowsTransactionLookupDecision {
  kUnavailable,
  kPortable,
  kProtected,
  kBindingMismatch,
};

enum class WindowsPortableDurableFileProbe {
  kMissing,
  kExactValid,
  kExactEmpty,
  kExactInvalid,
  kUnsafe,
};

enum class WindowsPortableDurableFileDecision {
  kUnavailable,
  kDiscardNextAndUnavailable,
  kUseFinal,
  kUseFinalAndDiscardNext,
  kReconcileValidPair,
  kPromoteNext,
  kReject,
};

enum class WindowsPortableValidPairDecision {
  kPromoteNext,
  kReject,
};

WindowsPortableDurableFileDecision
DecideWindowsPortableDurableFileRecovery(
    WindowsPortableDurableFileProbe final_file,
    WindowsPortableDurableFileProbe next_file);

WindowsPortableValidPairDecision DecideWindowsPortableRecordValidPair(
    const WindowsHelperPolicy& policy,
    const std::string& transaction_id,
    const std::string& final_canonical,
    const std::string& next_canonical);

WindowsPortableValidPairDecision
DecideWindowsPortableResolverClaimValidPair(
    const std::string& transaction_id,
    const std::string& final_canonical,
    const std::string& next_canonical);

WindowsTransactionLookupDecision DecideWindowsTransactionLookup(
    WindowsPortableTransactionProbe portable,
    bool protected_transaction_present);

std::string WindowsPortableIndexBindingKey(
    const WindowsHelperPolicy& policy);

enum class WindowsPortableTransactionStoreFaultPoint {
  kAfterTransactionDirectoryCreate,
  kAfterNextCreate,
  kAfterNextFlush,
  kAfterRenameBeforeDirectoryFlush,
};

class WindowsPortableTransactionStoreFaultInjector {
 public:
  virtual ~WindowsPortableTransactionStoreFaultInjector() = default;
  virtual void Hit(WindowsPortableTransactionStoreFaultPoint point) = 0;
};

class WindowsPortableTransactionStore {
 public:
  WindowsPortableTransactionStore(const WindowsHelperPolicy& policy,
                                  HANDLE caller_process,
                                  bool create_if_missing,
                                  WindowsPortableTransactionStoreFaultInjector*
                                      fault_injector = nullptr);
  ~WindowsPortableTransactionStore();
  WindowsPortableTransactionStore(const WindowsPortableTransactionStore&) =
      delete;
  WindowsPortableTransactionStore& operator=(
      const WindowsPortableTransactionStore&) = delete;

  void CreateRecord(const std::string& transaction_id,
                    const std::string& canonical_record);
  void WriteRecord(const std::string& transaction_id,
                   const std::string& canonical_record);
  std::optional<std::string> ReadRecord(
      const std::string& transaction_id) const;
  std::optional<std::string> ReadResolverClaim(
      const std::string& transaction_id) const;
  void WriteResolverClaim(const std::string& transaction_id,
                          const std::string& canonical_claim);

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

WindowsPortableTransactionProbe ProbeWindowsPortableTransaction(
    const WindowsHelperPolicy& policy,
    const std::string& transaction_id);

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_PORTABLE_TRANSACTION_INDEX_H_
