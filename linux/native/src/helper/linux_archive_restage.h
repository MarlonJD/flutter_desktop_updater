#ifndef DESKTOP_UPDATER_LINUX_HELPER_LINUX_ARCHIVE_RESTAGE_H_
#define DESKTOP_UPDATER_LINUX_HELPER_LINUX_ARCHIVE_RESTAGE_H_

#include <sys/types.h>

#include <cstdint>
#include <filesystem>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>

#include "linux_mount_guard.h"
#include "stage_provenance.h"

namespace desktop_updater::helper {

inline constexpr char kLinuxRetainedArtifactName[] =
    ".desktop_updater_artifact.zip";
inline constexpr char kLinuxReleaseManifestName[] =
    ".desktop_updater_release_manifest.json";
inline constexpr char kLinuxStageProvenanceName[] =
    ".desktop_updater_stage_provenance.json";
inline constexpr char kLinuxPayloadSealName[] =
    ".desktop_updater_payload_seal.json";
inline constexpr char kLinuxRestageOwnerName[] =
    ".desktop_updater_restage_owner";

class LinuxArchiveRestageError : public std::runtime_error {
 public:
  explicit LinuxArchiveRestageError(const std::string& detail)
      : std::runtime_error(detail) {}
};

class LinuxArchiveManualCleanupRequiredError final
    : public LinuxArchiveRestageError {
 public:
  LinuxArchiveManualCleanupRequiredError(std::string payload_leaf,
                                         std::string control_leaf,
                                         std::string recovery_record_leaf)
      : LinuxArchiveRestageError(
            "bounded restage cleanup requires manual action"),
        payload_leaf_(std::move(payload_leaf)),
        control_leaf_(std::move(control_leaf)),
        recovery_record_leaf_(std::move(recovery_record_leaf)) {}

  const std::string& payload_leaf() const { return payload_leaf_; }
  const std::string& control_leaf() const { return control_leaf_; }
  const std::string& recovery_record_leaf() const {
    return recovery_record_leaf_;
  }

 private:
  std::string payload_leaf_;
  std::string control_leaf_;
  std::string recovery_record_leaf_;
};

enum class LinuxArchiveRestageFaultPoint {
  kAfterRecoveryRecord,
  kAfterPayloadDirectoryMkdirBeforeCookie,
  kAfterPayloadDirectoryCreate,
  kAfterControlDirectoryMkdirBeforeCookie,
  kAfterControlDirectoryCreate,
  kAfterRecoveryRecordNextSyncBeforeRename,
  kAfterProtectedCopy,
  kAfterArchivePreflight,
  kAfterFirstExtractedEntry,
  kAfterPayloadSeal,
};

class LinuxArchiveRestageFaultInjector {
 public:
  virtual ~LinuxArchiveRestageFaultInjector() = default;
  virtual void OnLinuxArchiveRestageFault(
      LinuxArchiveRestageFaultPoint point) = 0;
};

struct LinuxArchiveRestageRequest {
  int source_stage_fd = -1;
  int target_parent_fd = -1;
  std::filesystem::path target_parent_path;
  std::string target_name;
  std::string transaction_id;
  std::string package_id;
  std::string canonical_release_manifest;
  std::string descriptor_sha256;
  std::string artifact_sha256;
  std::int64_t artifact_length = 0;
  std::string executable_relative_path;
  runtime::internal::StageProvenanceMarker caller_marker;
  uid_t source_uid = 0;
  gid_t source_gid = 0;
  uid_t payload_uid = 0;
  gid_t payload_gid = 0;
  mode_t activation_root_mode = 0755;
  bool broker_mode = false;
  std::size_t maximum_payload_seal_bytes = 64 * 1024 * 1024;
  // Native tests use the named fallback to exercise filesystems where
  // O_TMPFILE is unavailable. Production callers must leave this false.
  bool disable_recovery_record_o_tmpfile_for_testing = false;
  LinuxArchiveRestageFaultInjector* fault_injector = nullptr;
};

struct LinuxArchivePayloadVerification {
  std::string payload_seal_sha256;
  std::string artifact_sha256;
  std::string descriptor_sha256;
  std::string executable_sha256;
  std::uint32_t executable_mode = 0;
  std::uint32_t executable_uid = 0;
  std::uint32_t executable_gid = 0;
};

class LinuxArchiveRestagedPayload {
 public:
  ~LinuxArchiveRestagedPayload();
  LinuxArchiveRestagedPayload(const LinuxArchiveRestagedPayload&) = delete;
  LinuxArchiveRestagedPayload& operator=(
      const LinuxArchiveRestagedPayload&) = delete;

  const std::filesystem::path& path() const { return path_; }
  const std::filesystem::path& control_path() const { return control_path_; }
  const std::string& payload_seal_sha256() const {
    return payload_seal_sha256_;
  }
  const std::string& artifact_sha256() const { return artifact_sha256_; }

  // Once the durable transaction journal exists, process death must leave
  // both payload and control state for recovery instead of destructor cleanup.
  void ArmForRecovery();
  void CleanupCancelled();
  void CleanupCompleted();
  void PreserveControlForRecovery();

 private:
  friend std::unique_ptr<LinuxArchiveRestagedPayload>
  RestageLinuxSignedZip(const LinuxArchiveRestageRequest& request);

  LinuxArchiveRestagedPayload(
      std::filesystem::path path,
      std::filesystem::path control_path,
      std::string payload_leaf,
      std::string control_leaf,
      std::string payload_seal_sha256,
      std::string artifact_sha256,
      UniqueLinuxFd target_parent,
      LinuxFileIdentity payload_identity,
      LinuxFileIdentity control_identity,
      std::string recovery_record_leaf,
      LinuxFileIdentity recovery_record_identity,
      UniqueLinuxFd recovery_record);

  bool CleanupPayloadNoThrow();
  bool CleanupControlNoThrow();
  bool CleanupRecoveryRecordNoThrow();

  std::filesystem::path path_;
  std::filesystem::path control_path_;
  std::string payload_leaf_;
  std::string control_leaf_;
  std::string payload_seal_sha256_;
  std::string artifact_sha256_;
  UniqueLinuxFd target_parent_;
  LinuxFileIdentity payload_identity_;
  LinuxFileIdentity control_identity_;
  std::string recovery_record_leaf_;
  LinuxFileIdentity recovery_record_identity_;
  UniqueLinuxFd recovery_record_;
  bool automatic_cleanup_ = true;
  bool payload_present_ = true;
  bool control_present_ = true;
  bool recovery_record_present_ = true;
};

std::unique_ptr<LinuxArchiveRestagedPayload> RestageLinuxSignedZip(
    const LinuxArchiveRestageRequest& request);

std::string LinuxArchiveControlLeaf(const std::string& target_name,
                                    const std::string& transaction_id);

std::string LinuxArchiveRestageRecordLeaf(const std::string& transaction_id);

LinuxArchivePayloadVerification VerifyLinuxArchivePayload(
    int target_parent_fd,
    const std::string& payload_leaf,
    const std::string& control_leaf,
    const LinuxArchiveRestageRequest& expected,
    const std::string& expected_payload_seal_sha256);

bool LinuxArchiveActivatedRootMatches(
    int target_parent_fd,
    const std::string& payload_leaf,
    const LinuxFileIdentity& staged_identity,
    const LinuxArchiveRestageRequest& expected);

void FinalizeLinuxArchiveActivatedRoot(
    int target_parent_fd,
    const std::string& payload_leaf,
    const LinuxFileIdentity& staged_identity,
    const LinuxArchiveRestageRequest& expected);

std::string ReadLinuxArchiveControlManifest(
    int target_parent_fd,
    const std::string& control_leaf,
    const LinuxArchiveRestageRequest& expected);

mode_t ReadLinuxArchiveActivationRootMode(
    int target_parent_fd,
    const std::string& control_leaf,
    uid_t expected_uid,
    gid_t expected_gid,
    const std::string& expected_payload_seal_sha256);

void CleanupLinuxArchiveControl(
    int target_parent_fd,
    const std::string& control_leaf,
    const LinuxArchiveRestageRequest& expected,
    const std::string& expected_payload_seal_sha256);

void CleanupLinuxArchiveRestageRecord(
    int target_parent_fd,
    const LinuxArchiveRestageRequest& expected);

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_LINUX_HELPER_LINUX_ARCHIVE_RESTAGE_H_
