#include "desktop_updater_native.h"

#include <limits.h>
#include <libgen.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdint>
#include <cctype>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <iomanip>
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
  if (proof != nullptr) {
    *proof = {canonical_root, request.executable_relative_path,
              request.package_id,
              legacy_fallback
                  ? InstallTargetProofSource::kSelfContainedFlutterBundle
                  : InstallTargetProofSource::kRunningExecutableContext};
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
      "resolved_target=\"$(cd \"$target\" && pwd -P)\"\n"
      "if [ \"$resolved_target\" != \"$target\" ]; then exit 1; fi\n";

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
        "staging_root=\"$(cd \"$staging\" && pwd -P)\"\n"
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
        "verify_stage_provenance || exit 1\n"
        "backup=\"$(mktemp -d /tmp/desktop_updater_backup_XXXXXX)\"\n"
        "rollback() {\n"
        "  [ -d \"$backup\" ] || return 0\n"
        "  log_event \"rollback start\"\n"
        "  set +e\n"
        "  rm -rf \"$target\"\n"
        "  mkdir -p \"$(dirname \"$target\")\"\n"
        "  cp -a \"$backup/.\" \"$target/\"\n"
        "  rollback_status=$?\n"
        "  set -e\n"
        "  if [ \"$rollback_status\" -eq 0 ]; then\n"
        "    log_event \"rollback success\"\n"
        "  else\n"
        "    log_event \"rollback failure\"\n"
        "  fi\n"
        "  return \"$rollback_status\"\n"
        "}\n"
        "rollback_and_exit() {\n"
        "  rollback || true\n"
        "  rm -rf \"$backup\"\n"
        "  exit 1\n"
        "}\n"
        "trap 'rollback_and_exit' ERR\n"
        "log_event \"backup start\"\n"
        "if cp -a \"$target/.\" \"$backup/\"; then\n"
        "  log_event \"backup success\"\n"
        "else\n"
        "  log_event \"backup failure\"\n"
        "  rm -rf \"$backup\"\n"
        "  exit 1\n"
        "fi\n"
        "for relative in \"${removed[@]}\"; do\n"
        "  [ -z \"$relative\" ] && continue\n"
        "  candidate=\"$(realpath -m \"$target/$relative\")\"\n"
        "  case \"$candidate\" in\n"
        "    \"$target_root\"/*) [ -e \"$candidate\" ] && rm -rf \"$candidate\" ;;\n"
        "    *) echo \"Removed file escapes app root: $relative\" >&2; rollback_and_exit ;;\n"
        "  esac\n"
        "done\n"
        "if [ -n \"$staging\" ]; then\n"
        "  log_event \"staging path validation\"\n"
        "  if [ ! -d \"$staging\" ]; then\n"
        "    log_event \"staging path validation failure\"\n"
        "    rm -rf \"$backup\"\n"
        "    exit 1\n"
        "  fi\n"
        "  log_event \"move start\"\n"
        "  if find \"$target\" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + && cp -a \"$staging/.\" \"$target/\"; then\n"
        "    rm -f \"$target/.desktop_updater_stage_provenance.json\" "
        "\"$target/.desktop_updater_release_manifest.json\" "
        "\"$target/.desktop_updater_artifact.zip\"\n"
        "    log_event \"move success\"\n"
        "  else\n"
        "    log_event \"move failure\"\n"
        "    rollback_and_exit\n"
        "  fi\n"
        "  if [ -e \"$exe\" ] && [ ! -x \"$exe\" ]; then\n"
        "    log_event \"permission restore start\"\n"
        "    if chmod +x \"$exe\"; then\n"
        "      log_event \"permission restore success\"\n"
        "    else\n"
        "      log_event \"permission restore failure\"\n"
        "      rollback_and_exit\n"
        "    fi\n"
        "  elif [ ! -e \"$exe\" ] && [ \"$skip_relaunch\" != \"1\" ]; then\n"
        "    log_event \"permission restore failure\"\n"
        "    rollback_and_exit\n"
        "  fi\n"
        "  log_event \"cleanup start\"\n"
        "  if verify_stage_provenance && rm -rf \"$staging\"; then\n"
        "    log_event \"cleanup success\"\n"
        "  else\n"
        "    log_event \"cleanup failure\"\n"
        "  fi\n"
        "fi\n"
        "rm -rf \"$backup\"\n"
        "trap - ERR\n"
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
