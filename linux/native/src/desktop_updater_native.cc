#include "desktop_updater_native.h"

#include <limits.h>
#include <libgen.h>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdint>
#include <cctype>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iterator>
#include <sstream>
#include <string>
#include <unordered_set>
#include <vector>

#include "desktop_updater_native_internal.h"
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

std::string ShellQuote(const std::string& value) {
  std::string quoted = "'";
  for (char character : value) {
    if (character == '\'') {
      quoted += "'\\''";
    } else {
      quoted += character;
    }
  }
  quoted += "'";
  return quoted;
}

std::string ShellArray(const std::vector<std::string>& values) {
  std::string result;
  for (const auto& value : values) {
    result += " " + ShellQuote(value);
  }
  return result;
}

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

std::string DecodeMountInfoPathImpl(const std::string& encoded) {
  std::string decoded;
  decoded.reserve(encoded.size());
  for (std::size_t index = 0; index < encoded.size(); ++index) {
    if (encoded[index] == '\\' && index + 3 < encoded.size() &&
        encoded[index + 1] >= '0' && encoded[index + 1] <= '7' &&
        encoded[index + 2] >= '0' && encoded[index + 2] <= '7' &&
        encoded[index + 3] >= '0' && encoded[index + 3] <= '7') {
      const int value = (encoded[index + 1] - '0') * 64 +
                        (encoded[index + 2] - '0') * 8 +
                        (encoded[index + 3] - '0');
      decoded.push_back(static_cast<char>(value));
      index += 3;
    } else {
      decoded.push_back(encoded[index]);
    }
  }
  return decoded;
}

bool IsSameOrDescendant(const std::string& path, const std::string& root) {
  return path == root || IsStrictDescendant(path, root);
}

InstallResult RejectMountInfoEntries(const std::string& target,
                                     const std::string& stage,
                                     const std::string& mount_info) {
  std::istringstream lines(mount_info);
  std::string line;
  while (std::getline(lines, line)) {
    std::istringstream fields(line);
    std::string mount_id;
    std::string parent_id;
    std::string device;
    std::string root;
    std::string encoded_mount_point;
    if (!(fields >> mount_id >> parent_id >> device >> root >>
          encoded_mount_point)) {
      return {false, "Linux mountinfo is malformed."};
    }
    const std::string mount_point =
        DecodeMountInfoPathImpl(encoded_mount_point);
    if (IsSameOrDescendant(mount_point, target) ||
        IsSameOrDescendant(mount_point, stage)) {
      return {false,
              "Linux install target or staging tree contains a mount or bind "
              "mount boundary."};
    }
  }
  return {true, ""};
}

InstallResult TraverseSameDeviceAt(int directory_fd, dev_t root_device) {
  const int iterator_fd = dup(directory_fd);
  if (iterator_fd < 0) {
    return {false, "Linux directory traversal could not duplicate a handle."};
  }
  DIR* directory = fdopendir(iterator_fd);
  if (directory == nullptr) {
    close(iterator_fd);
    return {false, "Linux directory traversal could not open a handle."};
  }
  InstallResult result = {true, ""};
  errno = 0;
  while (dirent* entry = readdir(directory)) {
    const std::string name(entry->d_name);
    if (name == "." || name == "..") continue;
    struct stat metadata = {};
    if (fstatat(directory_fd, name.c_str(), &metadata,
                AT_SYMLINK_NOFOLLOW) != 0) {
      result = {false, "Linux tree entry changed during safe traversal."};
      break;
    }
    if (metadata.st_dev != root_device) {
      result = {false,
                "Linux install target or staging tree crosses a filesystem "
                "device boundary."};
      break;
    }
    if (!S_ISDIR(metadata.st_mode)) continue;
    const int child = openat(directory_fd, name.c_str(),
                             O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (child < 0) {
      result = {false, "Linux directory changed during safe traversal."};
      break;
    }
    result = TraverseSameDeviceAt(child, root_device);
    close(child);
    if (!result.ok) break;
  }
  if (errno != 0 && result.ok) {
    result = {false, "Linux directory traversal failed."};
  }
  closedir(directory);
  return result;
}

InstallResult ValidateSameDeviceTree(const std::string& root) {
  const int root_fd =
      open(root.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (root_fd < 0) {
    return {false, "Linux tree root could not be opened without following links."};
  }
  struct stat metadata = {};
  InstallResult result = {true, ""};
  if (fstat(root_fd, &metadata) != 0 || !S_ISDIR(metadata.st_mode)) {
    result = {false, "Linux tree root metadata is unavailable."};
  } else {
    result = TraverseSameDeviceAt(root_fd, metadata.st_dev);
  }
  close(root_fd);
  return result;
}

InstallResult RejectNestedMounts(const std::string& target,
                                 const std::string& stage) {
  InstallResult result = ValidateSameDeviceTree(target);
  if (!result.ok) return result;
  result = ValidateSameDeviceTree(stage);
  if (!result.ok) return result;
#if defined(__linux__)
  std::ifstream input("/proc/self/mountinfo", std::ios::binary);
  if (!input.is_open()) {
    return {false, "Linux mountinfo is unavailable; refusing install."};
  }
  const std::string mount_info((std::istreambuf_iterator<char>(input)),
                               std::istreambuf_iterator<char>());
  if ((!input.good() && !input.eof()) || mount_info.empty()) {
    return {false, "Linux mountinfo is unreadable; refusing install."};
  }
  return RejectMountInfoEntries(target, stage, mount_info);
#else
  return {true, ""};
#endif
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
  const InstallResult mount_safety =
      RejectNestedMounts(request.install_root, canonical_staging_path);
  if (!mount_safety.ok) {
    return mount_safety;
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

std::string CreateUuidNonce() {
  unsigned char bytes[16] = {};
  const int random = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
  if (random < 0) {
    return "";
  }
  std::size_t offset = 0;
  while (offset < sizeof(bytes)) {
    const ssize_t count = read(random, bytes + offset, sizeof(bytes) - offset);
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count <= 0) {
      close(random);
      return "";
    }
    offset += static_cast<std::size_t>(count);
  }
  close(random);
  bytes[6] = static_cast<unsigned char>((bytes[6] & 0x0f) | 0x40);
  bytes[8] = static_cast<unsigned char>((bytes[8] & 0x3f) | 0x80);
  std::ostringstream nonce;
  nonce << std::hex << std::setfill('0');
  for (std::size_t index = 0; index < sizeof(bytes); ++index) {
    if (index == 4 || index == 6 || index == 8 || index == 10) {
      nonce << '-';
    }
    nonce << std::setw(2) << static_cast<unsigned int>(bytes[index]);
  }
  return nonce.str();
}

bool WriteFile(const std::string& path, const std::string& contents) {
  const int file = open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL, 0700);
  if (file < 0) {
    return false;
  }
  std::size_t offset = 0;
  bool ok = true;
  while (offset < contents.size()) {
    const ssize_t count = write(
        file, contents.data() + offset, contents.size() - offset);
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count <= 0) {
      ok = false;
      break;
    }
    offset += static_cast<std::size_t>(count);
  }
  if (close(file) != 0) {
    ok = false;
  }
  if (!ok) {
    unlink(path.c_str());
  }
  return ok;
}

bool StartDetachedScript(const std::string& script_path) {
  const pid_t child = fork();
  if (child == 0) {
    execl("/bin/bash", "bash", script_path.c_str(), nullptr);
    _exit(1);
  }
  return child > 0;
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

namespace internal {

std::string DecodeMountInfoPath(const std::string& encoded) {
  return DecodeMountInfoPathImpl(encoded);
}

InstallResult RejectNestedMountsForTesting(
    const std::string& target,
    const std::string& stage,
    const std::string& mount_info) {
  return RejectMountInfoEntries(target, stage, mount_info);
}

bool RemoveTreeAtForRecovery(int parent_fd,
                             const std::string& name,
                             dev_t root_device) {
  struct stat metadata = {};
  if (fstatat(parent_fd, name.c_str(), &metadata, AT_SYMLINK_NOFOLLOW) != 0 ||
      metadata.st_dev != root_device) {
    return false;
  }
  if (!S_ISDIR(metadata.st_mode)) {
    return unlinkat(parent_fd, name.c_str(), 0) == 0;
  }
  const int child = openat(parent_fd, name.c_str(),
                           O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (child < 0) return false;
  const int iterator_fd = dup(child);
  DIR* directory = iterator_fd < 0 ? nullptr : fdopendir(iterator_fd);
  bool ok = directory != nullptr;
  while (ok) {
    errno = 0;
    dirent* entry = readdir(directory);
    if (entry == nullptr) {
      if (errno != 0) ok = false;
      break;
    }
    const std::string child_name(entry->d_name);
    if (child_name == "." || child_name == "..") continue;
    ok = RemoveTreeAtForRecovery(child, child_name, root_device);
  }
  if (directory != nullptr) closedir(directory);
  close(child);
  return ok && unlinkat(parent_fd, name.c_str(), AT_REMOVEDIR) == 0;
}

InstallResult BuildInstallScriptForTesting(
    const InstallRequest& request,
    const std::string& running_executable,
    int64_t process_identifier,
    std::string* script) {
  if (script == nullptr) {
    return {false, "Install helper script output is required."};
  }
  script->clear();

  std::string executable_path;
  if (!ResolveExistingPath(running_executable, &executable_path)) {
    return {false, "Unable to resolve executable path."};
  }

  InstallRequest normalized = request;
  const bool has_install_root = !normalized.install_root.empty();
  const bool has_executable_path =
      !normalized.executable_relative_path.empty();
  if (has_install_root != has_executable_path) {
    return {false,
            "Linux install root and executable path must be provided "
            "together."};
  }
  const bool legacy_fallback = !has_install_root;
  if (legacy_fallback) {
    normalized.install_root = ParentDirectory(executable_path);
    normalized.executable_relative_path = BaseName(executable_path);
    if (IsProtectedInstallRoot(normalized.install_root) ||
        IsTemporaryInstallRoot(normalized.install_root)) {
      return {false,
              "Legacy Linux installs require a self-contained Flutter "
              "bundle; pass explicit installRoot and "
              "executableRelativePath or use a fresh installer."};
    }
  }

  const InstallResult request_validation =
      ValidateNormalizedRequest(normalized, false);
  if (!request_validation.ok) {
    return request_validation;
  }
  std::string bound_provenance_marker;
  const InstallResult binding =
      BindProvenanceToMarker(&normalized, &bound_provenance_marker);
  if (!binding.ok) {
    return binding;
  }
  const InstallResult validation = ValidateNormalizedRequest(normalized);
  if (!validation.ok) {
    return validation;
  }

  InstallTargetProof target_proof;
  if (normalized.operation == LinuxInstallOperation::kInstall) {
    const InstallResult target = ProveInstallTarget(
        normalized, executable_path, legacy_fallback, &target_proof);
    if (!target.ok) {
      return target;
    }
  }

  std::string canonical_staging_path;
  if (normalized.operation == LinuxInstallOperation::kInstall &&
      !ResolveExistingPath(normalized.staging_path, &canonical_staging_path)) {
    return {false,
            "Staged update directory does not exist or is not a real "
            "directory."};
  }

  std::string provenance_checks;
  for (const InstallProvenanceEntry& entry : normalized.provenance_entries) {
    provenance_checks += "  candidate=\"$staging/\"" + ShellQuote(entry.path) + "\n";
    if (entry.kind == "directory") {
      provenance_checks +=
          "  [ -d \"$candidate\" ] && [ ! -L \"$candidate\" ] || { log_event \"stage provenance validation failure\"; return 1; }\n";
    } else if (entry.kind == "symlink") {
      provenance_checks +=
          "  [ -L \"$candidate\" ] && [ \"$(readlink -- \"$candidate\")\" = " +
          ShellQuote(entry.target) +
          " ] || { log_event \"stage provenance validation failure\"; return 1; }\n";
    } else {
      provenance_checks +=
          "  [ -f \"$candidate\" ] && [ ! -L \"$candidate\" ] && [ \"$(stat -c %s -- \"$candidate\")\" = " +
          ShellQuote(std::to_string(entry.length)) +
          " ] && [ \"$(sha256sum -- \"$candidate\" | awk '{print $1}')\" = " +
          ShellQuote(entry.sha256) +
          " ] || { log_event \"stage provenance validation failure\"; return 1; }\n";
    }
  }

  std::string generated =
      "#!/bin/bash\n"
      "set -euo pipefail\n"
      "pid_to_wait=" +
      std::to_string(process_identifier) + "\n"
                                           "staging=" +
      ShellQuote(canonical_staging_path) + "\n"
                                           "target=" +
      ShellQuote(normalized.install_root) + "\n"
                                     "exe=" +
      ShellQuote(executable_path) + "\n"
                                    "diagnostics_log=" +
      ShellQuote(normalized.diagnostics_log_path) + "\n"
                                                      "expected_provenance_sha256=" +
      ShellQuote(normalized.expected_provenance_sha256) + "\n"
      "provenance_nonce=" + ShellQuote(normalized.provenance_nonce) + "\n"
      "bound_provenance_marker=" + ShellQuote(bound_provenance_marker) + "\n"
      "expected_provenance_entry_count=" +
      std::to_string(normalized.provenance_entries.size()) + "\n"
                                                      "removed=(''" +
      ShellArray(normalized.removed_files) +
      ")\n"
      "skip_relaunch=\"${DESKTOP_UPDATER_SMOKE_SKIP_RELAUNCH:-}\"\n"
      "log_event() {\n"
      "  [ -n \"$diagnostics_log\" ] || return 0\n"
      "  printf '{\"timestamp\":\"%s\",\"event\":\"%s\"}\\n' \"$(date -u "+
      "'+%Y-%m-%dT%H:%M:%SZ')\" \"$1\" >> \"$diagnostics_log\" 2>/dev/null || true\n"
      "}\n"
      "log_event \"helper scheduled\"\n"
      "log_event \"waiting for parent process\"\n"
      "while kill -0 \"$pid_to_wait\" 2>/dev/null; do sleep 0.5; done\n"
      "log_event \"parent process exited\"\n"
      "if [ -d \"$target\" ]; then\n"
      "  resolved_target=\"$(cd \"$target\" && pwd -P)\"\n"
      "  if [ \"$resolved_target\" != \"$target\" ]; then exit 1; fi\n"
      "else\n"
      "  resolved_target=\"$target\"\n"
      "fi\n";

  if (normalized.operation == LinuxInstallOperation::kRestart) {
    generated +=
        "if [ \"$skip_relaunch\" != \"1\" ]; then\n"
        "  log_event \"relaunch attempt\"\n"
        "  cd \"$target\"\n"
        "  \"$exe\" &\n"
        "fi\n"
        "rm -f \"$0\"\n";
  } else {
    generated +=
        "target_root=\"$resolved_target\"\n"
        "if [ -d \"$staging\" ]; then staging_root=\"$(cd \"$staging\" && pwd -P)\"; else staging_root=\"$staging\"; fi\n"
        "case \"$staging_root\" in\n"
        "  \"$target_root\"|\"$target_root\"/*) exit 1 ;;\n"
        "esac\n"
        "case \"$target_root\" in\n"
        "  \"$staging_root\"/*) exit 1 ;;\n"
        "esac\n"
        "verify_stage_provenance() {\n"
        "  log_event \"stage provenance validation\"\n"
        "  marker=\"$staging/.desktop_updater_stage_provenance.json\"\n"
        "  [ -n \"$expected_provenance_sha256\" ] && [ -f \"$marker\" ] && [ ! -L \"$marker\" ] || { log_event \"stage provenance validation failure\"; return 1; }\n"
        "  actual_marker_sha256=\"$(sha256sum -- \"$marker\" | awk '{print $1}')\"\n"
        "  [ \"$actual_marker_sha256\" = \"$expected_provenance_sha256\" ] || { log_event \"stage provenance validation failure\"; return 1; }\n"
        "  bound_marker_sha256=\"$(printf '%s' \"$bound_provenance_marker\" | sha256sum | awk '{print $1}')\"\n"
        "  [ \"$bound_marker_sha256\" = \"$expected_provenance_sha256\" ] || { log_event \"stage provenance validation failure\"; return 1; }\n"
        "  [ \"$(basename \"$staging\")\" = \"desktop_updater_stage_$provenance_nonce\" ] || { log_event \"stage provenance validation failure\"; return 1; }\n" +
        provenance_checks +
        "  actual_entry_count=\"$(find \"$staging\" -mindepth 1 ! -path \"$marker\" -printf . | wc -c | tr -d ' ')\"\n"
        "  [ \"$actual_entry_count\" = \"$expected_provenance_entry_count\" ] || { log_event \"stage provenance validation failure\"; return 1; }\n"
        "  log_event \"stage provenance validation success\"\n"
        "}\n"
        "target_parent=\"$(dirname \"$target\")\"\n"
        "target_name=\"$(basename \"$target\")\"\n"
        "prepared=\"$target_parent/.$target_name.prepared-$provenance_nonce\"\n"
        "backup=\"$target_parent/.$target_name.backup-$provenance_nonce\"\n"
        "journal=\"$target_parent/.$target_name.desktop_updater_transaction.json\"\n"
        "owner_start=\"$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf unknown):$(awk '{print $22}' /proc/$$/stat 2>/dev/null || printf unknown)\"\n"
        "durable_sync() { sync \"$1\" 2>/dev/null || sync; }\n"
        "reject_mount_boundaries() {\n"
        "  checked_root=\"$1\"\n"
        "  [ -d \"$checked_root\" ] && [ ! -L \"$checked_root\" ] || return 1\n"
        "  checked_device=\"$(stat -c %d -- \"$checked_root\")\"\n"
        "  while IFS= read -r directory; do [ \"$(stat -c %d -- \"$directory\")\" = \"$checked_device\" ] || return 1; done < <(find \"$checked_root\" -xdev -type d -print)\n"
        "  if [ -r /proc/self/mountinfo ]; then\n"
        "    while IFS=' ' read -r mount_id mount_parent mount_device mount_source mount_point mount_rest; do\n"
        "      decoded_mount=\"$(printf '%b' \"$mount_point\")\"\n"
        "      case \"$decoded_mount\" in \"$checked_root\"|\"$checked_root\"/*) return 1 ;; esac\n"
        "    done < /proc/self/mountinfo\n"
        "  fi\n"
        "}\n"
        "journal_string() { sed -n 's/.*\"'\"$1\"'\":\"\\([^\"]*\\)\".*/\\1/p' \"$journal\"; }\n"
        "journal_number() { sed -n 's/.*\"'\"$1\"'\":\\([0-9][0-9]*\\).*/\\1/p' \"$journal\"; }\n"
        "recover_pending_install() {\n"
        "  [ -f \"$journal\" ] || return 0\n"
        "  [ ! -L \"$journal\" ] || return 1\n"
        "  log_event \"recovery detected\"\n"
        "  old_target=\"$(journal_string target)\"\n"
        "  old_package=\"$(journal_string packageId)\"\n"
        "  old_nonce=\"$(journal_string nonce)\"\n"
        "  old_prepared=\"$(journal_string prepared)\"\n"
        "  old_backup=\"$(journal_string backup)\"\n"
        "  old_state=\"$(journal_string state)\"\n"
        "  old_owner=\"$(journal_number ownerPid)\"\n"
        "  old_start=\"$(journal_string ownerProcessStart)\"\n"
        "  [ \"$old_target\" = \"$target\" ] && [ \"$old_package\" = " +
        ShellQuote(normalized.package_id) + " ] || return 1\n"
        "  [ \"$old_prepared\" = \"$target_parent/.$target_name.prepared-$old_nonce\" ] || return 1\n"
        "  [ \"$old_backup\" = \"$target_parent/.$target_name.backup-$old_nonce\" ] || return 1\n"
        "  if [ -n \"$old_owner\" ] && kill -0 \"$old_owner\" 2>/dev/null; then\n"
        "    live_start=\"$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf unknown):$(awk '{print $22}' \"/proc/$old_owner/stat\" 2>/dev/null || true)\"\n"
        "    [ \"$live_start\" != \"$old_start\" ] || return 1\n"
        "  fi\n"
        "  case \"$old_state\" in\n"
        "    prepared)\n"
        "      [ ! -e \"$old_backup\" ] && [ -e \"$target\" ] || return 1\n"
        "      [ ! -e \"$old_prepared\" ] || rm -rf \"$old_prepared\"\n"
        "      ;;\n"
        "    backupCreated)\n"
        "      if [ -e \"$target\" ] && [ ! -e \"$old_backup\" ]; then [ ! -e \"$old_prepared\" ] || rm -rf \"$old_prepared\";\n"
        "      elif [ ! -e \"$target\" ] && [ -e \"$old_backup\" ]; then mv \"$old_backup\" \"$target\"; [ ! -e \"$old_prepared\" ] || rm -rf \"$old_prepared\"; log_event \"recovery restored backup\";\n"
        "      else return 1; fi\n"
        "      ;;\n"
        "    targetActivated)\n"
        "      identity=\"$target/.desktop_updater_install_identity.json\"\n"
        "      if [ -e \"$target\" ] && [ -e \"$old_backup\" ] && [ -f \"$identity\" ] && [ ! -L \"$identity\" ] && grep -F -x -q " +
        ShellQuote("{\"packageId\":\"" + JsonEscape(normalized.package_id) +
                   "\",\"schemaVersion\":1}") +
        " \"$identity\"; then rm -rf \"$old_backup\"; [ ! -e \"$old_prepared\" ] || rm -rf \"$old_prepared\"; log_event \"recovery completed activation\";\n"
        "      elif [ -e \"$old_backup\" ]; then [ ! -e \"$target\" ] || mv \"$target\" \"$old_prepared\"; mv \"$old_backup\" \"$target\"; [ ! -e \"$old_prepared\" ] || rm -rf \"$old_prepared\"; log_event \"recovery restored backup\";\n"
        "      else return 1; fi\n"
        "      ;;\n"
        "    completed)\n"
        "      [ -e \"$target\" ] || return 1\n"
        "      [ ! -e \"$old_backup\" ] || rm -rf \"$old_backup\"\n"
        "      [ ! -e \"$old_prepared\" ] || rm -rf \"$old_prepared\"\n"
        "      log_event \"recovery completed activation\"\n"
        "      ;;\n"
        "    *) return 1 ;;\n"
        "  esac\n"
        "  rm -f \"$journal\"\n"
        "  durable_sync \"$target_parent\"\n"
        "}\n"
        "persist_journal() {\n"
        "  state=\"$1\"\n"
        "  journal_tmp=\"$journal.tmp.$$\"\n"
        "  printf '{\"schemaVersion\":1,\"ownerPid\":%s,\"ownerProcessStart\":\"%s\",\"nonce\":\"%s\",\"packageId\":\"%s\",\"target\":\"%s\",\"prepared\":\"%s\",\"backup\":\"%s\",\"stageProvenanceSha256\":\"%s\",\"state\":\"%s\"}' \"$$\" \"$owner_start\" \"$provenance_nonce\" " + ShellQuote(normalized.package_id) + " \"$target\" \"$prepared\" \"$backup\" \"$expected_provenance_sha256\" \"$state\" > \"$journal_tmp\"\n"
        "  durable_sync \"$journal_tmp\"\n"
        "  mv -f \"$journal_tmp\" \"$journal\"\n"
        "  durable_sync \"$target_parent\"\n"
        "  log_event \"transaction journal persisted\"\n"
        "  [ \"${DESKTOP_UPDATER_TEST_INTERRUPT_AFTER_STATE:-}\" != \"$state\" ] || exit 99\n"
        "}\n"
        "rollback_transaction() {\n"
        "  log_event \"rollback start\"\n"
        "  set +e\n"
        "  [ ! -e \"$target\" ] || mv \"$target\" \"$prepared\"\n"
        "  mv \"$backup\" \"$target\"\n"
        "  rollback_status=$?\n"
        "  [ ! -e \"$prepared\" ] || rm -rf \"$prepared\"\n"
        "  rm -f \"$journal\"\n"
        "  durable_sync \"$target_parent\"\n"
        "  set -e\n"
        "  if [ \"$rollback_status\" -eq 0 ]; then log_event \"rollback success\"; else log_event \"rollback failure\"; fi\n"
        "  return \"$rollback_status\"\n"
        "}\n"
        "recover_pending_install || { log_event \"recovery failure\"; exit 1; }\n"
        "resolved_target=\"$(cd \"$target\" && pwd -P)\"\n"
        "[ \"$resolved_target\" = \"$target\" ] || exit 1\n"
        "log_event \"staging path validation\"\n"
        "verify_stage_provenance || exit 1\n"
        "reject_mount_boundaries \"$target\" || { log_event \"mount boundary rejection\"; exit 1; }\n"
        "reject_mount_boundaries \"$staging\" || { log_event \"mount boundary rejection\"; exit 1; }\n"
        "[ ! -e \"$prepared\" ] && [ ! -e \"$backup\" ] || exit 1\n"
        "mkdir \"$prepared\"\n"
        "cp -a \"$staging/.\" \"$prepared/\"\n"
        "rm -f \"$prepared/.desktop_updater_stage_provenance.json\" \"$prepared/.desktop_updater_release_manifest.json\" \"$prepared/.desktop_updater_artifact.zip\"\n"
        "reject_mount_boundaries \"$prepared\" || { log_event \"mount boundary rejection\"; rm -rf \"$prepared\"; exit 1; }\n"
        "( set -o noclobber; : > \"$journal\" ) 2>/dev/null || { log_event \"transaction lock failure\"; rm -rf \"$prepared\"; exit 1; }\n"
        "log_event \"transaction lock acquired\"\n"
        "persist_journal prepared\n"
        "log_event \"backup start\"\n"
        "persist_journal backupCreated\n"
        "if mv \"$target\" \"$backup\"; then log_event \"backup success\"; else log_event \"backup failure\"; rm -f \"$journal\"; rm -rf \"$prepared\"; exit 1; fi\n"
        "durable_sync \"$target_parent\"\n"
        "log_event \"move start\"\n"
        "persist_journal targetActivated\n"
        "if mv \"$prepared\" \"$target\"; then log_event \"move success\"; else log_event \"move failure\"; rollback_transaction || true; exit 1; fi\n"
        "durable_sync \"$target_parent\"\n"
        "if [ -e \"$exe\" ] && [ ! -x \"$exe\" ]; then\n"
        "  log_event \"permission restore start\"\n"
        "  if chmod +x \"$exe\"; then log_event \"permission restore success\"; else log_event \"permission restore failure\"; rollback_transaction || true; exit 1; fi\n"
        "elif [ ! -e \"$exe\" ] && [ \"$skip_relaunch\" != \"1\" ]; then\n"
        "  log_event \"permission restore failure\"\n"
        "  rollback_transaction || true\n"
        "  exit 1\n"
        "fi\n"
        "persist_journal completed\n"
        "log_event \"cleanup start\"\n"
        "if rm -rf \"$backup\" && verify_stage_provenance && rm -rf \"$staging\"; then log_event \"cleanup success\"; else log_event \"cleanup failure\"; fi\n"
        "rm -f \"$journal\"\n"
        "durable_sync \"$target_parent\"\n"
        "if [ \"$skip_relaunch\" != \"1\" ]; then\n"
        "  log_event \"relaunch attempt\"\n"
        "  cd \"$target\"\n"
        "  \"$exe\" &\n"
        "fi\n"
        "rm -f \"$0\"\n";
  }

  *script = generated;
  return {true, ""};
}

}  // namespace internal

InstallResult ScheduleInstallAndRelaunch(const InstallRequest& request) {
  const int64_t process_identifier = static_cast<int64_t>(getpid());
  std::string script;
  const InstallResult build = internal::BuildInstallScriptForTesting(
      request, CurrentExecutablePath(), process_identifier, &script);
  if (!build.ok) {
    return build;
  }

  const std::string nonce = CreateUuidNonce();
  if (nonce.empty()) {
    return {false, "Unable to generate update helper nonce."};
  }
  const std::string script_path = "/tmp/desktop_updater_" +
      std::to_string(process_identifier) + "_" + nonce + ".sh";
  if (!WriteFile(script_path, script)) {
    return {false, "Unable to write update helper script."};
  }
  if (chmod(script_path.c_str(), 0755) != 0) {
    unlink(script_path.c_str());
    return {false, "Unable to make update helper script executable."};
  }
  if (!StartDetachedScript(script_path)) {
    unlink(script_path.c_str());
    return {false, "Unable to start update helper script."};
  }
  return {true, ""};
}

}  // namespace native
}  // namespace desktop_updater
