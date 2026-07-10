#include "desktop_updater_native.h"

#include <limits.h>
#include <libgen.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <unordered_set>
#include <vector>

#include "desktop_updater_native_internal.h"

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

bool IsStrictDescendant(const std::string& path, const std::string& root) {
  if (root == "/") {
    return path.size() > 1 && path.front() == '/';
  }
  return path.size() > root.size() && path.compare(0, root.size(), root) == 0 &&
         path[root.size()] == '/';
}

bool PathsOverlap(const std::string& first, const std::string& second) {
  return first == second || IsStrictDescendant(first, second) ||
         IsStrictDescendant(second, first);
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

InstallResult ValidateNormalizedRequest(const InstallRequest& request) {
  if (!IsCanonicalAbsolutePath(request.install_root)) {
    return {false, "Linux install root must be an absolute canonical path."};
  }
  if (kProtectedInstallRoots.count(request.install_root) != 0) {
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

bool WriteFile(const std::string& path, const std::string& contents) {
  std::ofstream file(path, std::ios::binary | std::ios::trunc);
  if (!file.is_open()) {
    return false;
  }
  file << contents;
  return file.good();
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
  return ValidateNormalizedRequest(request);
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
  if (normalized.install_root.empty()) {
    normalized.install_root = ParentDirectory(executable_path);
  }
  if (normalized.executable_relative_path.empty()) {
    if (IsStrictDescendant(executable_path, normalized.install_root)) {
      normalized.executable_relative_path =
          executable_path.substr(normalized.install_root.size() + 1);
    } else {
      normalized.executable_relative_path = BaseName(executable_path);
    }
  }

  const InstallResult validation = ValidateNormalizedRequest(normalized);
  if (!validation.ok) {
    return validation;
  }

  std::string canonical_target;
  if (!ResolveExistingPath(normalized.install_root, &canonical_target) ||
      canonical_target != normalized.install_root) {
    return {false,
            "Linux install root does not resolve to an existing canonical "
            "directory."};
  }
  const std::string requested_executable =
      JoinPath(canonical_target, normalized.executable_relative_path);
  std::string canonical_requested_executable;
  if (!ResolveExistingPath(requested_executable,
                           &canonical_requested_executable) ||
      canonical_requested_executable != executable_path) {
    return {false, "Linux install executable does not match the running app."};
  }

  std::string canonical_staging_path;
  if (normalized.operation == LinuxInstallOperation::kInstall &&
      !ResolveExistingPath(normalized.staging_path, &canonical_staging_path)) {
    return {false,
            "Staged update directory does not exist or is not a real "
            "directory."};
  }

  std::string generated =
      "#!/bin/bash\n"
      "set -euo pipefail\n"
      "pid_to_wait=" +
      std::to_string(process_identifier) + "\n"
                                           "staging=" +
      ShellQuote(canonical_staging_path) + "\n"
                                           "target=" +
      ShellQuote(canonical_target) + "\n"
                                     "exe=" +
      ShellQuote(executable_path) + "\n"
                                    "diagnostics_log=" +
      ShellQuote(normalized.diagnostics_log_path) + "\n"
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
        "  if rm -rf \"$staging\"; then\n"
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

  const std::string script_path =
      "/tmp/desktop_updater_" + std::to_string(process_identifier) + ".sh";
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
