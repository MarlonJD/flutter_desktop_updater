#ifndef DESKTOP_UPDATER_RUNTIME_STAGE_PROVENANCE_H_
#define DESKTOP_UPDATER_RUNTIME_STAGE_PROVENANCE_H_

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace desktop_updater {
namespace runtime {
namespace internal {

constexpr const char* kStageProvenanceFileName =
    ".desktop_updater_stage_provenance.json";
constexpr const char* kOwnedStagePrefix = "desktop_updater_stage_";

using StageSha256Function =
    std::function<std::vector<std::uint8_t>(const std::string&)>;

struct StageProvenanceEntry {
  std::string path;
  std::string kind;
  std::int64_t length = 0;
  std::string sha256;
  std::string target;
};

struct StageProvenanceMarker {
  std::string nonce;
  std::string package_id;
  std::string descriptor_sha256;
  std::string artifact_sha256;
  std::vector<StageProvenanceEntry> entries;
};

struct StageProvenanceState {
  StageProvenanceMarker marker;
  std::string marker_sha256;
};

struct OwnedStage {
  std::string path;
  std::string parent_path;
  std::string nonce;
};

OwnedStage CreateOwnedStage(const std::string& parent_path,
                            const std::string& nonce = std::string());

StageProvenanceState WriteStageProvenance(
    const OwnedStage& stage,
    const std::string& package_id,
    const std::string& descriptor_sha256,
    const std::string& artifact_sha256,
    const StageSha256Function& sha256);

StageProvenanceState ReadStageProvenance(
    const std::string& stage_root,
    const StageSha256Function& sha256);

StageProvenanceMarker VerifyStageProvenance(
    const std::string& stage_root,
    const std::string& expected_marker_sha256,
    const StageSha256Function& sha256);

void RemoveOwnedStage(const std::string& parent_path,
                      const std::string& stage_root,
                      const std::string& nonce,
                      const StageSha256Function& sha256);

std::string StageBytesToHex(const std::vector<std::uint8_t>& bytes);

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_RUNTIME_STAGE_PROVENANCE_H_
