#include "desktop_updater_native.h"

#include <limits.h>
#include <libgen.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdint>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iterator>
#include <sstream>
#include <string>
#include <unordered_set>
#include <vector>

#include "json_value.h"
#include "stage_provenance.h"

namespace desktop_updater {
namespace native {
namespace {

const std::unordered_set<std::string> kProtectedInstallRoots = {
    "/",          "/bin",       "/sbin",      "/usr",
    "/usr/bin",   "/usr/sbin",  "/usr/local", "/usr/local/bin",
    "/opt",       "/etc",       "/var",       "/home",
};

constexpr const char* kInstalledIdentityMarkerName =
    ".desktop_updater_install_identity.json";

std::string ParentDirectory(const std::string& file_path) {
  char* copy = strdup(file_path.c_str());
  if (copy == nullptr) {
    return "";
  }
  const std::string result = dirname(copy);
  free(copy);
  return result;
}

std::string BaseName(const std::string& file_path) {
  char* copy = strdup(file_path.c_str());
  if (copy == nullptr) {
    return "";
  }
  const std::string result = basename(copy);
  free(copy);
  return result;
}

bool IsCanonicalAbsolutePath(const std::string& path) {
  if (path.empty() || path.front() != '/') {
    return false;
  }
  if (path == "/") {
    return true;
  }
  if (path.back() == '/') {
    return false;
  }

  size_t segment_start = 1;
  while (segment_start < path.size()) {
    const size_t segment_end = path.find('/', segment_start);
    const size_t length = segment_end == std::string::npos
                              ? std::string::npos
                              : segment_end - segment_start;
    const std::string segment = path.substr(segment_start, length);
    if (segment.empty() || segment == "." || segment == "..") {
      return false;
    }
    if (segment_end == std::string::npos) {
      break;
    }
    segment_start = segment_end + 1;
  }
  return true;
}

bool IsCanonicalRelativePath(const std::string& path) {
  if (path.empty() || path.front() == '/' || path.back() == '/') {
    return false;
  }

  size_t segment_start = 0;
  while (segment_start < path.size()) {
    const size_t segment_end = path.find('/', segment_start);
    const size_t length = segment_end == std::string::npos
                              ? std::string::npos
                              : segment_end - segment_start;
    const std::string segment = path.substr(segment_start, length);
    if (segment.empty() || segment == "." || segment == "..") {
      return false;
    }
    if (segment_end == std::string::npos) {
      break;
    }
    segment_start = segment_end + 1;
  }
  return true;
}

std::string JoinPath(const std::string& root, const std::string& relative) {
  return root == "/" ? root + relative : root + "/" + relative;
}

std::string EnvironmentPath(const char* name) {
  const char* value = std::getenv(name);
  if (value == nullptr || value[0] == '\0') {
    return "";
  }
  std::string result = value;
  while (result.size() > 1 && result.back() == '/') {
    result.pop_back();
  }
  return result;
}

bool IsStrictDescendant(const std::string& path, const std::string& root) {
  if (root == "/") {
    return path.size() > 1 && path.front() == '/';
  }
  return path.size() > root.size() && path.compare(0, root.size(), root) == 0 &&
         path[root.size()] == '/';
}

bool IsProtectedInstallRoot(const std::string& root) {
  if (kProtectedInstallRoots.count(root) != 0) {
    return true;
  }
  const std::string home = EnvironmentPath("HOME");
  if (!home.empty() &&
      (root == home || root == JoinPath(home, "bin") ||
       root == JoinPath(home, ".local/bin") ||
       root == JoinPath(home, "Desktop") ||
       root == JoinPath(home, "Downloads"))) {
    return true;
  }
  const std::string temp = EnvironmentPath("TMPDIR");
  return root == "/tmp" || root == "/private/tmp" ||
         (!temp.empty() && root == temp);
}

bool IsTemporaryInstallRoot(const std::string& root) {
  const std::string temp = EnvironmentPath("TMPDIR");
  return root == "/tmp" || IsStrictDescendant(root, "/tmp") ||
         root == "/private/tmp" ||
         IsStrictDescendant(root, "/private/tmp") ||
         (!temp.empty() &&
          (root == temp || IsStrictDescendant(root, temp)));
}

bool PathsOverlap(const std::string& first, const std::string& second) {
  return first == second || IsStrictDescendant(first, second) ||
         IsStrictDescendant(second, first);
}

bool IsLowercaseSHA256(const std::string& value) {
  if (value.size() != 64) return false;
  for (unsigned char byte : value) {
    if (!std::isdigit(byte) && (byte < 'a' || byte > 'f')) return false;
  }
  return true;
}

bool IsLowercaseUuidNonce(const std::string& value) {
  if (value.size() != 36 || value[8] != '-' || value[13] != '-' ||
      value[18] != '-' || value[23] != '-' || value[14] != '4' ||
      std::string("89ab").find(value[19]) == std::string::npos) {
    return false;
  }
  for (std::size_t index = 0; index < value.size(); ++index) {
    if (index == 8 || index == 13 || index == 18 || index == 23) continue;
    const char byte = value[index];
    if (!std::isdigit(static_cast<unsigned char>(byte)) &&
        (byte < 'a' || byte > 'f')) return false;
  }
  return true;
}

bool HasSymlinkComponent(const std::string& path) {
  if (!IsCanonicalAbsolutePath(path)) {
    return true;
  }

  std::string current;
  size_t segment_start = 1;
  while (segment_start < path.size()) {
    const size_t segment_end = path.find('/', segment_start);
    const size_t length = segment_end == std::string::npos
                              ? std::string::npos
                              : segment_end - segment_start;
    current += "/" + path.substr(segment_start, length);
    struct stat path_stat = {};
    if (lstat(current.c_str(), &path_stat) == 0 && S_ISLNK(path_stat.st_mode)) {
      return true;
    }
    if (segment_end == std::string::npos) {
      break;
    }
    segment_start = segment_end + 1;
  }
  return false;
}

bool ResolveExistingPath(const std::string& path, std::string* resolved) {
  char buffer[PATH_MAX];
  if (realpath(path.c_str(), buffer) == nullptr) {
    return false;
  }
  *resolved = buffer;
  return true;
}

bool IsRealDirectory(const std::string& path) {
  struct stat value = {};
  return lstat(path.c_str(), &value) == 0 && S_ISDIR(value.st_mode) &&
         !S_ISLNK(value.st_mode);
}

bool IsRealFile(const std::string& path) {
  struct stat value = {};
  return lstat(path.c_str(), &value) == 0 && S_ISREG(value.st_mode) &&
         !S_ISLNK(value.st_mode);
}

std::string JsonEscape(const std::string& value) {
  std::ostringstream escaped;
  escaped << std::hex << std::setfill('0');
  for (const unsigned char byte : value) {
    switch (byte) {
      case '\b':
        escaped << "\\b";
        break;
      case '\f':
        escaped << "\\f";
        break;
      case '\n':
        escaped << "\\n";
        break;
      case '\r':
        escaped << "\\r";
        break;
      case '\t':
        escaped << "\\t";
        break;
      case '\\':
      case '"':
        escaped << '\\' << static_cast<char>(byte);
        break;
      default:
        if (byte < 0x20) {
          escaped << "\\u00" << std::setw(2)
                  << static_cast<unsigned int>(byte);
        } else {
          escaped << static_cast<char>(byte);
        }
    }
  }
  return escaped.str();
}

bool HasMatchingInstallIdentityMarker(const std::string& install_root,
                                      const std::string& package_id) {
  const std::string marker_path =
      JoinPath(install_root, kInstalledIdentityMarkerName);
  if (!IsRealFile(marker_path)) {
    return false;
  }
  std::ifstream input(marker_path, std::ios::binary);
  const std::string contents((std::istreambuf_iterator<char>(input)),
                             std::istreambuf_iterator<char>());
  return (input.good() || input.eof()) &&
         contents == "{\"packageId\":\"" + JsonEscape(package_id) +
                         "\",\"schemaVersion\":1}";
}

bool ProvenanceContainsExecutable(const InstallRequest& request) {
  for (const InstallProvenanceEntry& entry : request.provenance_entries) {
    if (entry.path == request.executable_relative_path &&
        entry.kind == "file") {
      return true;
    }
  }
  return false;
}

InstallResult ProveInstallTarget(const InstallRequest& request,
                                 const std::string& running_executable,
                                 bool legacy_fallback,
                                 InstallTargetProof* proof) {
  std::string canonical_root;
  std::string canonical_requested_executable;
  const std::string requested_executable =
      JoinPath(request.install_root, request.executable_relative_path);
  if (!ResolveExistingPath(request.install_root, &canonical_root) ||
      canonical_root != request.install_root ||
      !ResolveExistingPath(requested_executable,
                           &canonical_requested_executable) ||
      canonical_requested_executable != running_executable) {
    return {false, "Linux install target does not match the running app."};
  }
  if (!ProvenanceContainsExecutable(request) ||
      !IsRealFile(JoinPath(request.staging_path,
                           request.executable_relative_path))) {
    return {false,
            "Linux staged inventory does not contain the running executable."};
  }
  if (!legacy_fallback &&
      ParentDirectory(canonical_requested_executable) != canonical_root) {
    return {false,
            "Linux installed identity cannot authorize an ancestor of the "
            "running executable; use its exact parent as install root."};
  }
  if (legacy_fallback &&
      (!IsRealDirectory(JoinPath(request.install_root,
                                 "data/flutter_assets")) ||
       !IsRealFile(JoinPath(request.install_root,
                            "lib/libflutter_linux_gtk.so")))) {
    return {false,
            "Legacy Linux installs require a self-contained Flutter bundle; "
            "pass explicit installRoot and executableRelativePath or use a "
            "fresh installer."};
  }
  if (!legacy_fallback &&
      !HasMatchingInstallIdentityMarker(request.install_root,
                                        request.package_id)) {
    return {false,
            "Linux explicit install root requires a matching root-level "
            "installed identity marker; use a fresh installer."};
  }
  if (proof != nullptr) {
    *proof = {canonical_root, request.executable_relative_path,
              request.package_id,
              legacy_fallback
                  ? InstallTargetProofSource::kLegacySelfContainedBundle
                  : InstallTargetProofSource::kInstalledIdentityMarker};
  }
  return {true, ""};
}

InstallResult BindProvenanceToMarker(InstallRequest* request,
                                     std::string* canonical_marker) {
  if (request->operation == LinuxInstallOperation::kRestart) {
    return {true, ""};
  }
  try {
    const runtime::internal::StageProvenanceBinding binding =
        runtime::internal::ReadStageProvenanceBinding(request->staging_path);
    const runtime::internal::StageProvenanceMarker& marker = binding.marker;
    if (marker.package_id != request->package_id) {
      return {false, "Linux stage provenance package identity changed."};
    }
    if (canonical_marker != nullptr) {
      *canonical_marker = binding.canonical_json;
    }
    request->provenance_nonce = marker.nonce;
    request->provenance_entries.clear();
    request->provenance_entries.reserve(marker.entries.size());
    for (const runtime::internal::StageProvenanceEntry& entry : marker.entries) {
      request->provenance_entries.push_back(
          {entry.path, entry.kind, entry.length, entry.sha256, entry.target});
    }
  } catch (const std::exception& error) {
    return {false,
            std::string("Linux stage provenance marker is invalid: ") +
                error.what()};
  }
  return {true, ""};
}

InstallResult ValidateNormalizedRequest(const InstallRequest& request,
                                        bool validate_provenance = true) {
  if (!IsCanonicalAbsolutePath(request.install_root)) {
    return {false, "Linux install root must be an absolute canonical path."};
  }
  if (IsProtectedInstallRoot(request.install_root)) {
    return {false, "Linux install root is a protected shared/system root."};
  }
  if (IsTemporaryInstallRoot(request.install_root)) {
    return {false, "Linux install root must not be in a temporary tree."};
  }
  if (HasSymlinkComponent(request.install_root)) {
    return {false, "Linux install root must not contain symbolic links."};
  }
  if (!IsCanonicalRelativePath(request.executable_relative_path)) {
    return {false,
            "Linux executable path must be a canonical relative path without "
            "dot segments."};
  }

  const std::string executable_path =
      JoinPath(request.install_root, request.executable_relative_path);
  if (!IsStrictDescendant(executable_path, request.install_root) ||
      HasSymlinkComponent(executable_path)) {
    return {false, "Linux executable must resolve inside install root."};
  }

  std::string resolved_root;
  if (ResolveExistingPath(request.install_root, &resolved_root) &&
      resolved_root != request.install_root) {
    return {false, "Linux install root must already be canonical."};
  }
  std::string resolved_executable;
  if (ResolveExistingPath(executable_path, &resolved_executable) &&
      !IsStrictDescendant(resolved_executable, request.install_root)) {
    return {false, "Linux executable resolves outside install root."};
  }

  if (request.operation == LinuxInstallOperation::kRestart) {
    return {true, ""};
  }
  if (request.package_id.find_first_not_of(" \t\r\n") == std::string::npos) {
    return {false,
            "Linux install package identity is required; use a fresh "
            "installer when identity cannot be verified."};
  }

  struct stat staging_stat = {};
  std::string canonical_staging_path;
  if (request.staging_path.empty() ||
      lstat(request.staging_path.c_str(), &staging_stat) != 0 ||
      !S_ISDIR(staging_stat.st_mode) || S_ISLNK(staging_stat.st_mode) ||
      !ResolveExistingPath(request.staging_path, &canonical_staging_path)) {
    return {false,
            "Staged update directory does not exist or is not a real "
            "directory."};
  }
  if (PathsOverlap(canonical_staging_path, request.install_root)) {
    return {false, "Staging path must not overlap install root."};
  }
  if (validate_provenance) {
    if (!IsLowercaseSHA256(request.expected_provenance_sha256) ||
        !IsLowercaseUuidNonce(request.provenance_nonce) ||
        BaseName(canonical_staging_path) !=
            "desktop_updater_stage_" + request.provenance_nonce ||
        request.provenance_entries.empty()) {
      return {false,
              "Linux install requires immutable owned stage provenance."};
    }
    for (const InstallProvenanceEntry& entry : request.provenance_entries) {
      if (!IsCanonicalRelativePath(entry.path) ||
          (entry.kind != "file" && entry.kind != "directory" &&
           entry.kind != "symlink") ||
          (entry.kind == "file" &&
           (!IsLowercaseSHA256(entry.sha256) || entry.length < 0)) ||
          (entry.kind == "symlink" &&
           !IsCanonicalRelativePath(entry.target))) {
        return {false, "Linux stage provenance entry is invalid."};
      }
    }
  }

  for (const auto& relative : request.removed_files) {
    if (relative.empty()) {
      continue;
    }
    if (!IsCanonicalRelativePath(relative)) {
      return {false, "Removed file path escapes install root."};
    }
    const std::string candidate = JoinPath(request.install_root, relative);
    if (!IsStrictDescendant(candidate, request.install_root) ||
        HasSymlinkComponent(candidate)) {
      return {false, "Removed file path escapes install root."};
    }
    std::string resolved_candidate;
    if (ResolveExistingPath(candidate, &resolved_candidate) &&
        !IsStrictDescendant(resolved_candidate, request.install_root)) {
      return {false, "Removed file path escapes install root."};
    }
  }
  return {true, ""};
}

std::string CurrentExecutablePath() {
  char executable_path[PATH_MAX];
  const ssize_t length =
      readlink("/proc/self/exe", executable_path, sizeof(executable_path) - 1);
  if (length == -1) {
    return "";
  }
  executable_path[length] = '\0';
  return executable_path;
}

}  // namespace

InstallResult ValidateInstallRequest(const InstallRequest& request) {
  InstallRequest normalized = request;
  const InstallResult request_validation =
      ValidateNormalizedRequest(normalized, false);
  if (!request_validation.ok) {
    return request_validation;
  }
  const InstallResult binding = BindProvenanceToMarker(&normalized, nullptr);
  return binding.ok ? ValidateNormalizedRequest(normalized) : binding;
}

namespace {

InstallResult SerializeCommonInstallRequest(
    const InstallRequest& request,
    std::string* canonical_request) {
  if (canonical_request == nullptr) {
    return {false, "Canonical helper request output must not be null."};
  }
  try {
    using JsonValue = runtime::internal::JsonValue;
    JsonValue::Array removed_files;
    for (const std::string& path : request.removed_files) {
      removed_files.emplace_back(path);
    }
    JsonValue::Array entries;
    for (const InstallProvenanceEntry& entry : request.provenance_entries) {
      JsonValue::Object value;
      value.emplace("path", JsonValue(entry.path));
      value.emplace("kind", JsonValue(entry.kind));
      value.emplace("length", JsonValue(entry.length));
      value.emplace("sha256", JsonValue(entry.sha256));
      value.emplace("target", JsonValue(entry.target));
      entries.emplace_back(std::move(value));
    }
    JsonValue::Object caller;
    caller.emplace("processId",
                   JsonValue(static_cast<std::int64_t>(getpid())));
    caller.emplace("executablePath", JsonValue(CurrentExecutablePath()));
    JsonValue::Object target;
    target.emplace("pathHint", JsonValue(request.install_root));
    target.emplace("executableRelativePath",
                   JsonValue(request.executable_relative_path));
    target.emplace("packageId", JsonValue(request.package_id));
    JsonValue::Object stage;
    stage.emplace("pathHint", JsonValue(request.staging_path));
    stage.emplace("provenanceSha256",
                  JsonValue(request.expected_provenance_sha256));
    stage.emplace("provenanceNonce",
                  JsonValue(request.provenance_nonce));
    stage.emplace("entries", JsonValue(std::move(entries)));
    JsonValue::Object options;
    options.emplace("diagnosticsLogPath",
                    JsonValue(request.diagnostics_log_path));
    options.emplace("removedFiles", JsonValue(std::move(removed_files)));
    options.emplace(
        "operation",
        JsonValue(std::string(
            request.operation == LinuxInstallOperation::kInstall
                ? "install"
                : "restart")));
    JsonValue::Object envelope;
    envelope.emplace("schemaVersion", JsonValue(std::int64_t{1}));
    envelope.emplace("protocolVersion", JsonValue(std::int64_t{1}));
    envelope.emplace("operation",
                     JsonValue(std::string("prepareInstall")));
    envelope.emplace("caller", JsonValue(std::move(caller)));
    envelope.emplace("target", JsonValue(std::move(target)));
    envelope.emplace("stage", JsonValue(std::move(stage)));
    envelope.emplace("options", JsonValue(std::move(options)));
    *canonical_request = runtime::internal::EncodeCanonicalJson(
        JsonValue(std::move(envelope)));
    return canonical_request->empty()
               ? InstallResult{false,
                               "Canonical helper request is empty."}
               : InstallResult{true, ""};
  } catch (const std::exception& error) {
    return {false, std::string("Unable to serialize helper request: ") +
                       error.what()};
  }
}

InstallTransactionStatus EndpointUnavailableStatus(
    const std::string& transaction_id) {
  return {transaction_id, InstallTransactionState::kUnknown,
          InstallTransactionResultCode::kEndpointUnavailable,
          "Packaged Linux install helper endpoint is unavailable.", "", ""};
}

}  // namespace

InstallResult PrepareInstall(const InstallRequest& request,
                             InstallReservation* reservation) {
  if (reservation == nullptr) {
    return {false, "Install reservation output must not be null."};
  }
  *reservation = {};
  const InstallResult validation = ValidateInstallRequest(request);
  if (!validation.ok) {
    return validation;
  }
  std::string canonical_request;
  const InstallResult serialization =
      SerializeCommonInstallRequest(request, &canonical_request);
  if (!serialization.ok) {
    return serialization;
  }
  return {false,
          "Packaged Linux install helper endpoint is unavailable; no durable "
          "authenticated response or reservation was created."};
}

InstallTransactionStatus CommitAfterExit(
    const InstallReservation& reservation) {
  if (!IsLowercaseUuidNonce(reservation.transaction_id) ||
      reservation.ready_token.empty()) {
    return {reservation.transaction_id, InstallTransactionState::kUnknown,
            InstallTransactionResultCode::kInvalidResponse,
            "Install reservation is invalid.", "", ""};
  }
  return EndpointUnavailableStatus(reservation.transaction_id);
}

InstallTransactionStatus CancelReservation(
    const InstallReservation& reservation) {
  if (!IsLowercaseUuidNonce(reservation.transaction_id) ||
      reservation.ready_token.empty()) {
    return {reservation.transaction_id, InstallTransactionState::kUnknown,
            InstallTransactionResultCode::kInvalidResponse,
            "Install reservation is invalid.", "", ""};
  }
  return EndpointUnavailableStatus(reservation.transaction_id);
}

InstallTransactionStatus QueryTransaction(
    const std::string& transaction_id) {
  if (!IsLowercaseUuidNonce(transaction_id)) {
    return {transaction_id, InstallTransactionState::kUnknown,
            InstallTransactionResultCode::kRejected,
            "Transaction ID is invalid.", "", ""};
  }
  return EndpointUnavailableStatus(transaction_id);
}

InstallTransactionStatus RecoverPendingInstall(
    const std::string& transaction_id) {
  if (!IsLowercaseUuidNonce(transaction_id)) {
    return {transaction_id, InstallTransactionState::kUnknown,
            InstallTransactionResultCode::kRejected,
            "Transaction ID is invalid.", "", ""};
  }
  return EndpointUnavailableStatus(transaction_id);
}

InstallResult ScheduleInstallAndRelaunch(const InstallRequest& request) {
  InstallReservation reservation;
  const InstallResult prepare = PrepareInstall(request, &reservation);
  if (!prepare.ok) return prepare;
  if (!IsLowercaseUuidNonce(reservation.transaction_id) ||
      reservation.ready_token.empty() ||
      !IsLowercaseSHA256(reservation.response_digest_sha256) ||
      !IsLowercaseSHA256(reservation.helper_endpoint_identity_sha256)) {
    return {false, "Install helper returned an invalid reservation."};
  }
  const InstallTransactionStatus status = CommitAfterExit(reservation);
  const bool accepted =
      (status.state == InstallTransactionState::kCommitAccepted ||
       status.state == InstallTransactionState::kCompleted) &&
      (status.result_code == InstallTransactionResultCode::kAccepted ||
       status.result_code == InstallTransactionResultCode::kSucceeded) &&
      status.response_digest_sha256 == reservation.response_digest_sha256 &&
      status.helper_endpoint_identity_sha256 ==
          reservation.helper_endpoint_identity_sha256;
  return accepted
             ? InstallResult{true, ""}
             : InstallResult{false,
                             status.detail.empty()
                                 ? "Install helper commit was not accepted."
                                 : status.detail};
}

}  // namespace native
}  // namespace desktop_updater
