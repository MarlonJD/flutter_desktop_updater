#include "desktop_updater_native.h"

#include <fcntl.h>
#include <limits.h>
#include <libgen.h>
#include <poll.h>
#include <signal.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <array>
#include <cctype>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iterator>
#include <filesystem>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <unordered_set>
#include <vector>

#include "json_value.h"
#include "install_helper_policy.h"
#include "linux_control_wire.h"
#include "linux_helper_locator.h"
#include "linux_native_install_request_builder.h"
#include "native_install_request.h"
#include "stage_provenance.h"
#include "unix_socket_transport.h"

namespace desktop_updater {
namespace native {
namespace {

namespace fs = std::filesystem;

const std::unordered_set<std::string> kProtectedInstallRoots = {
    "/",          "/bin",       "/sbin",      "/usr",
    "/usr/bin",   "/usr/sbin",  "/usr/local", "/usr/local/bin",
    "/opt",       "/etc",       "/var",       "/home",
};

constexpr const char* kInstalledIdentityMarkerName =
    ".desktop_updater_install_identity.json";

class ScopedDescriptor {
 public:
  explicit ScopedDescriptor(int descriptor) : descriptor_(descriptor) {}
  ~ScopedDescriptor() {
    if (descriptor_ >= 0) close(descriptor_);
  }
  ScopedDescriptor(const ScopedDescriptor&) = delete;
  ScopedDescriptor& operator=(const ScopedDescriptor&) = delete;
  int get() const { return descriptor_; }
  int release() {
    const int descriptor = descriptor_;
    descriptor_ = -1;
    return descriptor;
  }
  void reset(int descriptor = -1) {
    if (descriptor_ >= 0) close(descriptor_);
    descriptor_ = descriptor;
  }

 private:
  int descriptor_;
};

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

bool RequiresPrivilegedBroker(const std::string& install_root) {
  struct stat target {};
  struct stat parent {};
  const fs::path path(install_root);
  return lstat(path.c_str(), &target) != 0 ||
         lstat(path.parent_path().c_str(), &parent) != 0 ||
         target.st_uid != geteuid() || parent.st_uid != geteuid() ||
         access(path.parent_path().c_str(), W_OK | X_OK) != 0;
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

std::string ReadBoundedFile(const fs::path& path,
                            std::size_t maximum_bytes,
                            const char* label) {
  ScopedDescriptor input(
      open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
  struct stat status {};
  if (input.get() < 0 || fstat(input.get(), &status) != 0 ||
      !S_ISREG(status.st_mode) || status.st_size < 0 ||
      static_cast<std::uint64_t>(status.st_size) > maximum_bytes) {
    throw std::runtime_error(std::string(label) + " identity rejected");
  }
  std::string bytes;
  bytes.reserve(static_cast<std::size_t>(status.st_size));
  std::array<char, 64 * 1024> buffer{};
  for (;;) {
    ssize_t count = -1;
    do {
      count = read(input.get(), buffer.data(), buffer.size());
    } while (count < 0 && errno == EINTR);
    if (count == 0) break;
    if (count < 0 ||
        static_cast<std::size_t>(count) > maximum_bytes - bytes.size()) {
      throw std::runtime_error(std::string(label) + " read failed");
    }
    bytes.append(buffer.data(), static_cast<std::size_t>(count));
  }
  return bytes;
}

std::vector<unsigned char> SecureRandomBytes(std::size_t length) {
  std::vector<unsigned char> result(length);
  std::size_t offset = 0;
  while (offset < result.size()) {
    const ssize_t count =
        getrandom(result.data() + offset, result.size() - offset, 0);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) throw std::runtime_error("secure randomness unavailable");
    offset += static_cast<std::size_t>(count);
  }
  return result;
}

std::string NewTransactionId() {
  std::vector<unsigned char> bytes = SecureRandomBytes(16);
  bytes[6] = static_cast<unsigned char>((bytes[6] & 0x0f) | 0x40);
  bytes[8] = static_cast<unsigned char>((bytes[8] & 0x3f) | 0x80);
  std::ostringstream output;
  output << std::hex << std::setfill('0');
  for (std::size_t index = 0; index < bytes.size(); ++index) {
    if (index == 4 || index == 6 || index == 8 || index == 10) output << '-';
    output << std::setw(2) << static_cast<unsigned int>(bytes[index]);
  }
  return output.str();
}

std::string NewRequestNonce() {
  static constexpr char alphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  const std::vector<unsigned char> bytes = SecureRandomBytes(32);
  std::string output;
  output.reserve(43);
  std::uint32_t buffer = 0;
  int bits = 0;
  for (unsigned char byte : bytes) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 6) {
      bits -= 6;
      output.push_back(alphabet[(buffer >> bits) & 0x3f]);
    }
  }
  if (bits > 0) output.push_back(alphabet[(buffer << (6 - bits)) & 0x3f]);
  return output;
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

InstallResult RestartCurrentApplication() {
  const std::string executable_path = CurrentExecutablePath();
  if (executable_path.empty()) {
    return {false, "Running Linux executable identity is unavailable."};
  }
  int lifetime_pipe[2] = {-1, -1};
  if (pipe2(lifetime_pipe, O_CLOEXEC) != 0) {
    return {false, "Linux restart lifetime barrier failed."};
  }
  ScopedDescriptor lifetime_read(lifetime_pipe[0]);
  ScopedDescriptor lifetime_write(lifetime_pipe[1]);
  int ready_pipe[2] = {-1, -1};
  if (pipe2(ready_pipe, O_CLOEXEC) != 0) {
    return {false, "Linux restart readiness proof failed."};
  }
  ScopedDescriptor ready_read(ready_pipe[0]);
  ScopedDescriptor ready_write(ready_pipe[1]);
  std::vector<char> mutable_argv0(executable_path.begin(),
                                  executable_path.end());
  mutable_argv0.push_back('\0');
  char* child_argv[] = {mutable_argv0.data(), nullptr};

  const pid_t child = fork();
  if (child < 0) {
    return {false, "Linux restart process creation failed."};
  }
  if (child == 0) {
    lifetime_write.reset();
    ready_read.reset();
    const unsigned char ready = 1;
    ssize_t ready_count = -1;
    do {
      ready_count = write(ready_write.get(), &ready, sizeof(ready));
    } while (ready_count < 0 && errno == EINTR);
    if (ready_count != static_cast<ssize_t>(sizeof(ready))) {
      _exit(126);
    }
    ready_write.reset();

    unsigned char ignored = 0;
    ssize_t lifetime_count = -1;
    do {
      lifetime_count = read(lifetime_read.get(), &ignored, sizeof(ignored));
    } while (lifetime_count < 0 && errno == EINTR);
    if (lifetime_count != 0) {
      _exit(126);
    }
    lifetime_read.reset();
    // The procfs magic link remains bound to this process image across fork,
    // including when the original pathname was replaced or removed.
    execve("/proc/self/exe", child_argv, environ);
    _exit(127);
  }

  lifetime_read.reset();
  ready_write.reset();
  pollfd descriptor{ready_read.get(), POLLIN | POLLHUP, 0};
  int observed = -1;
  do {
    observed = poll(&descriptor, 1, 10'000);
  } while (observed < 0 && errno == EINTR);
  if (observed <= 0) {
    (void)kill(child, SIGKILL);
    int child_status = 0;
    while (waitpid(child, &child_status, 0) < 0 && errno == EINTR) {
    }
    return {false, observed == 0 ? "Linux restart readiness timed out."
                                 : "Linux restart readiness failed."};
  }

  unsigned char ready = 0;
  ssize_t count = -1;
  do {
    count = read(ready_read.get(), &ready, sizeof(ready));
  } while (count < 0 && errno == EINTR);
  if (count != static_cast<ssize_t>(sizeof(ready)) || ready != 1) {
    (void)kill(child, SIGKILL);
    int child_status = 0;
    while (waitpid(child, &child_status, 0) < 0 && errno == EINTR) {
    }
    return {false, "Linux restart readiness proof was invalid."};
  }

  // The plugin exits immediately after this success. Deliberately retain the
  // close-on-exec write end until process teardown so the child cannot race a
  // single-instance lock held by the current application.
  (void)lifetime_write.release();
  return {true, ""};
}

namespace {

fs::path PortableHelperPathForCurrentExecutable();
std::string PackagedPolicyId(const InstallRequest& request);

InstallResult SerializeCommonInstallRequest(
    const InstallRequest& request,
    std::string* canonical_request) {
  if (canonical_request == nullptr) {
    return {false, "Canonical helper request output must not be null."};
  }
  try {
    const runtime::internal::StageProvenanceBinding binding =
        runtime::internal::ReadStageProvenanceBinding(request.staging_path);
    const fs::path release_manifest =
        fs::path(request.staging_path) /
        ".desktop_updater_release_manifest.json";
    const std::string manifest =
        ReadBoundedFile(release_manifest, 1024 * 1024,
                        "staged release manifest");
    const fs::path identity_marker =
        fs::path(request.install_root) / kInstalledIdentityMarkerName;
    const std::string installed_identity =
        ReadBoundedFile(identity_marker, 128 * 1024,
                        "installed identity marker");
    const std::string executable_path = CurrentExecutablePath();
    if (executable_path.empty()) {
      throw std::runtime_error("running executable identity unavailable");
    }
    runtime::internal::LinuxNativeInstallEvidenceV1 evidence;
    evidence.transaction_id = NewTransactionId();
    evidence.policy_id = PackagedPolicyId(request);
    evidence.package_id = request.package_id;
    evidence.target_class = RequiresPrivilegedBroker(request.install_root)
                                ? "protectedApplication"
                                : "sameUserWritable";
    evidence.target_path_hint = request.install_root;
    evidence.target_name_hint = BaseName(request.install_root);
    evidence.executable_relative_path = request.executable_relative_path;
    evidence.target_identity_proof_sha256 =
        helper::Sha256LinuxBytes(installed_identity);
    evidence.current_version = "unknown";
    evidence.current_build_number = 0;
    evidence.current_package_identity_sha256 =
        evidence.target_identity_proof_sha256;
    evidence.stage_path_hint = request.staging_path;
    evidence.expected_provenance_sha256 =
        request.expected_provenance_sha256;
    evidence.expected_artifact_sha256 = binding.marker.artifact_sha256;
    evidence.caller_process_id = static_cast<std::int64_t>(getpid());
    evidence.caller_process_start_identity =
        "linux:" + std::to_string(helper::LinuxProcessStartIdentity(getpid()));
    evidence.caller_executable_sha256 =
        helper::Sha256LinuxFile(executable_path);
    evidence.caller_signer_identity = evidence.caller_executable_sha256;
    evidence.request_nonce = NewRequestNonce();
    const auto wire_request = runtime::internal::
        BuildLinuxNativeInstallTransactionRequestV1(
            manifest, binding, evidence, helper::Sha256LinuxBytes);
    *canonical_request = runtime::internal::
        EncodeCanonicalNativeInstallTransactionRequestV1(wire_request);
    return canonical_request->empty()
               ? InstallResult{false,
                               "Canonical helper request is empty."}
               : InstallResult{true, ""};
  } catch (const std::exception& error) {
    return {false, std::string("Unable to serialize helper request: ") +
                       error.what()};
  }
}

struct ActiveLinuxHelperSession {
  InstallReservation reservation;
  std::unique_ptr<helper::LinuxOneShotClientSession> session;
};

std::mutex& ActiveLinuxHelperSessionsMutex() {
  static std::mutex mutex;
  return mutex;
}

std::map<std::string, ActiveLinuxHelperSession>& ActiveLinuxHelperSessions() {
  static std::map<std::string, ActiveLinuxHelperSession> sessions;
  return sessions;
}

bool ReservationsMatch(const InstallReservation& first,
                       const InstallReservation& second) {
  return first.transaction_id == second.transaction_id &&
         first.ready_token == second.ready_token &&
         first.response_digest_sha256 == second.response_digest_sha256 &&
         first.helper_endpoint_identity_sha256 ==
             second.helper_endpoint_identity_sha256 &&
         first.expires_at_unix_milliseconds ==
             second.expires_at_unix_milliseconds;
}

InstallReservation PublicReservation(
    const runtime::internal::NativeInstallReservationV1& reservation) {
  return {reservation.transaction_id,
          reservation.ready_token,
          reservation.journal_sha256,
          reservation.helper_endpoint_identity_sha256,
          reservation.expires_at_unix_milliseconds};
}

fs::path PortableHelperPathForCurrentExecutable() {
  return internal::LocatePackagedLinuxHelper(CurrentExecutablePath());
}

fs::path PortableRecoveryAuthorityHelperPath(
    const std::string& transaction_id) {
  fs::path state_home;
  const std::string configured = EnvironmentPath("XDG_STATE_HOME");
  if (!configured.empty()) {
    state_home = configured;
  } else {
    const std::string home = EnvironmentPath("HOME");
    if (home.empty()) {
      throw std::runtime_error("Linux recovery state home is unavailable");
    }
    state_home = fs::path(home) / ".local" / "state";
  }
  state_home = state_home.lexically_normal();
  if (!state_home.is_absolute()) {
    throw std::runtime_error("Linux recovery state home is invalid");
  }
  return state_home / "desktop-updater" / "transactions" /
         (transaction_id + ".authority") / "desktop-updater-helper";
}

bool HasPortableRecoveryAuthority(const fs::path& helper) {
  struct stat status {};
  return lstat(helper.c_str(), &status) == 0 && S_ISREG(status.st_mode) &&
         !S_ISLNK(status.st_mode) && status.st_uid == geteuid() &&
         (status.st_mode & (S_IWGRP | S_IWOTH)) == 0 &&
         (status.st_mode & S_IXUSR) != 0;
}

std::string PackagedPolicyId(const InstallRequest& request) {
  std::string canonical_policy;
  if (RequiresPrivilegedBroker(request.install_root)) {
    const fs::path sealed_policy =
        fs::path("/etc/desktop-updater/policies") /
        (request.package_id + ".json");
    const auto wrapper = runtime::internal::ParseJson(
        ReadBoundedFile(sealed_policy, 128 * 1024,
                        "sealed helper policy"));
    canonical_policy = wrapper.at("canonicalPolicyJson").string();
  } else {
    canonical_policy = ReadBoundedFile(
        PortableHelperPathForCurrentExecutable().parent_path() /
            "desktop-updater-helper.policy.json",
        128 * 1024, "packaged helper policy");
    if (!canonical_policy.empty() && canonical_policy.back() == '\n') {
      canonical_policy.pop_back();
    }
  }
  const auto policy = runtime::internal::ParseHelperPolicyV1(
      canonical_policy, request.package_id, 1);
  if (canonical_policy != policy.canonical_json) {
    throw std::runtime_error("packaged helper policy is not canonical");
  }
  return policy.policy_id;
}

bool CurrentPackagedHelperRequiresBroker() {
  const fs::path helper = PortableHelperPathForCurrentExecutable();
  struct stat status {};
  return lstat(helper.c_str(), &status) != 0 ||
         status.st_uid != geteuid();
}

helper::LinuxControlRequestV1 ControlRequest(
    const std::string& operation,
    const std::string& transaction_id) {
  const std::string executable = CurrentExecutablePath();
  if (executable.empty()) {
    throw std::runtime_error("running executable identity unavailable");
  }
  const std::string executable_sha256 = helper::Sha256LinuxFile(executable);
  return {1,
          operation,
          transaction_id,
          NewRequestNonce(),
          static_cast<std::int64_t>(getpid()),
          "linux:" +
              std::to_string(helper::LinuxProcessStartIdentity(getpid())),
          executable_sha256,
          executable_sha256};
}

InstallTransactionState PublicState(const std::string& state) {
  if (state == "prepared") return InstallTransactionState::kPrepared;
  if (state == "completed" || state == "launchPending" ||
      state == "launchAttempting" || state == "launched" ||
      state == "launchFailed") {
    return InstallTransactionState::kCompleted;
  }
  if (state == "rolledBack") return InstallTransactionState::kRolledBack;
  if (state == "manualActionRequired") {
    return InstallTransactionState::kManualActionRequired;
  }
  return InstallTransactionState::kUnknown;
}

InstallTransactionResultCode PublicResultCode(const std::string& result) {
  if (result == "completed" || result == "rolledBack") {
    return InstallTransactionResultCode::kSucceeded;
  }
  if (result == "recoveryRequired" || result == "manualActionRequired") {
    return InstallTransactionResultCode::kRecoveryRequired;
  }
  if (result == "relaunchFailure") {
    return InstallTransactionResultCode::kRelaunchFailure;
  }
  return InstallTransactionResultCode::kInvalidResponse;
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
  InstallRequest normalized = request;
  if (normalized.operation != LinuxInstallOperation::kRestart) {
    const InstallResult binding = BindProvenanceToMarker(&normalized, nullptr);
    if (!binding.ok) {
      return binding;
    }
    const InstallResult target_proof =
        ProveInstallTarget(normalized, CurrentExecutablePath(), false, nullptr);
    if (!target_proof.ok) {
      return target_proof;
    }
  }
  std::string canonical_request;
  const InstallResult serialization =
      SerializeCommonInstallRequest(normalized, &canonical_request);
  if (!serialization.ok) {
    return serialization;
  }
  try {
    auto session = RequiresPrivilegedBroker(normalized.install_root)
                       ? helper::LaunchPrivilegedLinuxBroker(canonical_request,
                                                             30'000)
                       : helper::LaunchUnprivilegedLinuxHelper(
                             PortableHelperPathForCurrentExecutable(),
                             canonical_request,
                             30'000);
    const InstallReservation public_reservation =
        PublicReservation(session->reservation());
    {
      std::lock_guard<std::mutex> lock(ActiveLinuxHelperSessionsMutex());
      if (!ActiveLinuxHelperSessions()
               .emplace(public_reservation.transaction_id,
                        ActiveLinuxHelperSession{public_reservation,
                                                 std::move(session)})
               .second) {
        return {false, "Linux helper transaction ID collision."};
      }
    }
    *reservation = public_reservation;
    return {true, ""};
  } catch (const std::exception& error) {
    return {false, std::string("Linux helper handoff failed: ") + error.what()};
  }
}

InstallTransactionStatus CommitAfterExit(
    const InstallReservation& reservation) {
  if (!IsLowercaseUuidNonce(reservation.transaction_id) ||
      reservation.ready_token.empty()) {
    return {reservation.transaction_id, InstallTransactionState::kUnknown,
            InstallTransactionResultCode::kInvalidResponse,
            "Install reservation is invalid.", "", ""};
  }
  std::unique_ptr<helper::LinuxOneShotClientSession> session;
  {
    std::lock_guard<std::mutex> lock(ActiveLinuxHelperSessionsMutex());
    const auto active =
        ActiveLinuxHelperSessions().find(reservation.transaction_id);
    if (active == ActiveLinuxHelperSessions().end()) {
      return EndpointUnavailableStatus(reservation.transaction_id);
    }
    if (!ReservationsMatch(active->second.reservation, reservation)) {
      return {reservation.transaction_id, InstallTransactionState::kUnknown,
              InstallTransactionResultCode::kInvalidResponse,
              "Install reservation binding changed.", "", ""};
    }
    session = std::move(active->second.session);
    ActiveLinuxHelperSessions().erase(active);
  }
  try {
    const auto acknowledged = session->CommitAfterExit();
    return {reservation.transaction_id,
            InstallTransactionState::kCommitAccepted,
            InstallTransactionResultCode::kAccepted,
            "Linux helper accepted the canonical commit command.",
            acknowledged.journal_sha256,
            acknowledged.helper_endpoint_identity_sha256};
  } catch (const std::exception& error) {
    return {reservation.transaction_id,
            InstallTransactionState::kUnknown,
            InstallTransactionResultCode::kEndpointUnavailable,
            std::string("Linux helper commit was not accepted: ") +
                error.what(),
            "", ""};
  }
}

InstallTransactionStatus CancelReservation(
    const InstallReservation& reservation) {
  if (!IsLowercaseUuidNonce(reservation.transaction_id) ||
      reservation.ready_token.empty()) {
    return {reservation.transaction_id, InstallTransactionState::kUnknown,
            InstallTransactionResultCode::kInvalidResponse,
            "Install reservation is invalid.", "", ""};
  }
  std::unique_ptr<helper::LinuxOneShotClientSession> session;
  {
    std::lock_guard<std::mutex> lock(ActiveLinuxHelperSessionsMutex());
    const auto active =
        ActiveLinuxHelperSessions().find(reservation.transaction_id);
    if (active == ActiveLinuxHelperSessions().end()) {
      return EndpointUnavailableStatus(reservation.transaction_id);
    }
    if (!ReservationsMatch(active->second.reservation, reservation)) {
      return {reservation.transaction_id, InstallTransactionState::kUnknown,
              InstallTransactionResultCode::kInvalidResponse,
              "Install reservation binding changed.", "", ""};
    }
    session = std::move(active->second.session);
    ActiveLinuxHelperSessions().erase(active);
  }
  try {
    const auto cancelled = session->CancelReservation();
    return {reservation.transaction_id,
            InstallTransactionState::kCancelled,
            InstallTransactionResultCode::kSucceeded,
            "Linux helper cancelled the prepared transaction.",
            cancelled.journal_sha256,
            reservation.helper_endpoint_identity_sha256};
  } catch (const std::exception& error) {
    return {reservation.transaction_id,
            InstallTransactionState::kUnknown,
            InstallTransactionResultCode::kEndpointUnavailable,
            std::string("Linux helper cancellation failed: ") + error.what(),
            "", ""};
  }
}

InstallTransactionStatus QueryTransaction(
    const std::string& transaction_id) {
  if (!IsLowercaseUuidNonce(transaction_id)) {
    return {transaction_id, InstallTransactionState::kUnknown,
            InstallTransactionResultCode::kRejected,
            "Transaction ID is invalid.", "", ""};
  }
  try {
    const auto request = ControlRequest("queryTransaction", transaction_id);
    const auto encoded = helper::EncodeLinuxControlRequestV1(request);
    const fs::path recovery_helper =
        PortableRecoveryAuthorityHelperPath(transaction_id);
    const auto exchange =
        HasPortableRecoveryAuthority(recovery_helper)
            ? helper::ExchangeUnprivilegedLinuxHelperControl(
                  recovery_helper, encoded, request.request_nonce, 30'000)
        : CurrentPackagedHelperRequiresBroker()
            ? helper::ExchangePrivilegedLinuxBrokerControl(
                  encoded, request.request_nonce, 30'000)
            : helper::ExchangeUnprivilegedLinuxHelperControl(
                  PortableHelperPathForCurrentExecutable(), encoded,
                  request.request_nonce, 30'000);
    const auto status = runtime::internal::
        ParseNativeInstallTransactionStatusV1(exchange.canonical_response);
    if (status.transaction_id != transaction_id) {
      throw std::runtime_error("transaction query binding changed");
    }
    return {transaction_id,
            PublicState(status.state),
            PublicResultCode(status.result_code),
            "Linux helper returned the durable transaction state.",
            status.journal_sha256,
            exchange.helper_endpoint_identity_sha256};
  } catch (const std::exception& error) {
    return {transaction_id,
            InstallTransactionState::kUnknown,
            InstallTransactionResultCode::kEndpointUnavailable,
            std::string("Linux helper query failed: ") + error.what(),
            "",
            ""};
  }
}

InstallTransactionStatus RecoverPendingInstall(
    const std::string& transaction_id) {
  if (!IsLowercaseUuidNonce(transaction_id)) {
    return {transaction_id, InstallTransactionState::kUnknown,
            InstallTransactionResultCode::kRejected,
            "Transaction ID is invalid.", "", ""};
  }
  try {
    const auto request =
        ControlRequest("recoverPendingInstall", transaction_id);
    const auto encoded = helper::EncodeLinuxControlRequestV1(request);
    const fs::path recovery_helper =
        PortableRecoveryAuthorityHelperPath(transaction_id);
    const auto exchange =
        HasPortableRecoveryAuthority(recovery_helper)
            ? helper::ExchangeUnprivilegedLinuxHelperControl(
                  recovery_helper, encoded, request.request_nonce, 30'000)
        : CurrentPackagedHelperRequiresBroker()
            ? helper::ExchangePrivilegedLinuxBrokerControl(
                  encoded, request.request_nonce, 30'000)
            : helper::ExchangeUnprivilegedLinuxHelperControl(
                  PortableHelperPathForCurrentExecutable(), encoded,
                  request.request_nonce, 30'000);
    const auto recovery = runtime::internal::
        ParseNativeInstallRecoveryResultV1(exchange.canonical_response);
    if (recovery.transaction_id != transaction_id) {
      throw std::runtime_error("transaction recovery binding changed");
    }
    InstallTransactionState state = InstallTransactionState::kUnknown;
    if (recovery.verified_outcome == "newTarget" &&
        (recovery.result_code == "completed" ||
         recovery.result_code == "relaunchFailure")) {
      state = InstallTransactionState::kCompleted;
    } else if (recovery.verified_outcome == "oldTarget" &&
               recovery.result_code == "rolledBack") {
      state = InstallTransactionState::kRolledBack;
    } else if (recovery.result_code == "manualActionRequired") {
      state = InstallTransactionState::kManualActionRequired;
    } else if (recovery.result_code == "recoveryRequired") {
      state = InstallTransactionState::kPrepared;
    }
    return {transaction_id,
            state,
            PublicResultCode(recovery.result_code),
            "Linux helper completed the durable recovery query.",
            recovery.journal_sha256,
            exchange.helper_endpoint_identity_sha256};
  } catch (const std::exception& error) {
    return {transaction_id,
            InstallTransactionState::kUnknown,
            InstallTransactionResultCode::kEndpointUnavailable,
            std::string("Linux helper recovery failed: ") + error.what(),
            "",
            ""};
  }
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
