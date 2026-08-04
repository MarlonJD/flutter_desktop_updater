#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "linux_relaunch_service.h"

#include <fcntl.h>
#include <grp.h>
#include <openssl/evp.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <climits>
#include <cstring>
#include <iomanip>
#include <map>
#include <memory>
#include <regex>
#include <set>
#include <sstream>
#include <utility>
#include <vector>

#include "json_value.h"
#include "unix_socket_transport.h"

namespace desktop_updater::helper {
namespace {

using desktop_updater::runtime::internal::EncodeCanonicalJson;
using desktop_updater::runtime::internal::JsonValue;
using desktop_updater::runtime::internal::ParseJson;

constexpr char kStageProvenance[] =
    ".desktop_updater_stage_provenance.json";
constexpr char stageProvenance[] = "stageProvenance";

void RequireKeys(const JsonValue& value,
                 const std::set<std::string>& expected) {
  const auto& object = value.object();
  if (object.size() != expected.size()) {
    throw LinuxRelaunchError("stage provenance fields rejected");
  }
  for (const auto& key : expected) {
    if (object.find(key) == object.end()) {
      throw LinuxRelaunchError("stage provenance fields rejected");
    }
  }
}

std::vector<std::string> SplitRelative(const std::string& path) {
  if (path.empty() || path.front() == '/') {
    throw LinuxRelaunchError("executable path is not relative");
  }
  std::vector<std::string> result;
  std::size_t start = 0;
  while (start <= path.size()) {
    const std::size_t separator = path.find('/', start);
    const std::string component =
        path.substr(start, separator == std::string::npos
                               ? std::string::npos
                               : separator - start);
    ValidateLinuxLeaf(component);
    result.push_back(component);
    if (separator == std::string::npos) break;
    start = separator + 1;
  }
  return result;
}

UniqueLinuxFd OpenPayloadRoot(int parent, const std::string& leaf) {
  auto result = OpenLinuxRelativeNoFollow(parent, leaf, O_PATH);
  if (!ReadLinuxFileIdentity(result.get()).directory) {
    throw LinuxRelaunchError("payload root is not a directory");
  }
  return result;
}

UniqueLinuxFd OpenExecutable(int root, const std::string& relative_path) {
  const auto components = SplitRelative(relative_path);
  UniqueLinuxFd current(dup(root));
  if (!current.valid()) throw LinuxRelaunchError("payload root duplicate failed");
  for (std::size_t index = 0; index < components.size(); ++index) {
    const bool last = index + 1 == components.size();
    current = OpenLinuxRelativeNoFollow(
        current.get(), components[index],
        last ? O_RDONLY : O_PATH | O_DIRECTORY);
  }
  const auto identity = ReadLinuxFileIdentity(current.get());
  if (identity.directory || (identity.mode & S_IFMT) != S_IFREG ||
      (identity.mode & 0111) == 0 || identity.link_count != 1) {
    throw LinuxRelaunchError("verified executable type or permissions rejected");
  }
  return current;
}

std::string ReadFd(int fd, std::size_t maximum_bytes) {
  if (lseek(fd, 0, SEEK_SET) < 0) {
    throw LinuxRelaunchError("payload read seek failed");
  }
  std::string result;
  std::array<char, 4096> buffer{};
  for (;;) {
    const ssize_t count = read(fd, buffer.data(), buffer.size());
    if (count < 0) throw LinuxRelaunchError("payload read failed");
    if (count == 0) break;
    result.append(buffer.data(), static_cast<std::size_t>(count));
    if (result.size() > maximum_bytes) {
      throw LinuxRelaunchError("payload file exceeds size limit");
    }
  }
  return result;
}

std::string Sha256Fd(int fd) {
  std::unique_ptr<EVP_MD_CTX, decltype(&EVP_MD_CTX_free)> context(
      EVP_MD_CTX_new(), EVP_MD_CTX_free);
  if (!context || EVP_DigestInit_ex(context.get(), EVP_sha256(), nullptr) != 1 ||
      lseek(fd, 0, SEEK_SET) < 0) {
    throw LinuxRelaunchError("SHA-256 setup failed");
  }
  std::array<unsigned char, 64 * 1024> buffer{};
  for (;;) {
    const ssize_t count = read(fd, buffer.data(), buffer.size());
    if (count < 0) throw LinuxRelaunchError("SHA-256 read failed");
    if (count == 0) break;
    if (EVP_DigestUpdate(context.get(), buffer.data(),
                         static_cast<std::size_t>(count)) != 1) {
      throw LinuxRelaunchError("SHA-256 update failed");
    }
  }
  std::array<unsigned char, EVP_MAX_MD_SIZE> digest{};
  unsigned int length = 0;
  if (EVP_DigestFinal_ex(context.get(), digest.data(), &length) != 1 ||
      length != 32) {
    throw LinuxRelaunchError("SHA-256 finalization failed");
  }
  std::ostringstream output;
  output << std::hex << std::setfill('0');
  for (unsigned int index = 0; index < length; ++index) {
    output << std::setw(2) << static_cast<unsigned int>(digest[index]);
  }
  return output.str();
}

std::string ReadProcFile(pid_t process_id,
                         const char* leaf,
                         std::size_t maximum_bytes) {
  const std::filesystem::path path =
      std::filesystem::path("/proc") / std::to_string(process_id) / leaf;
  UniqueLinuxFd file(open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
  if (!file.valid()) {
    throw LinuxRelaunchError("caller process metadata unavailable");
  }
  std::string bytes;
  std::array<char, 8192> buffer{};
  for (;;) {
    ssize_t count = -1;
    do {
      count = read(file.get(), buffer.data(), buffer.size());
    } while (count < 0 && errno == EINTR);
    if (count == 0) break;
    if (count < 0 || static_cast<std::size_t>(count) >
                         maximum_bytes - std::min(maximum_bytes, bytes.size())) {
      throw LinuxRelaunchError("caller process metadata read rejected");
    }
    bytes.append(buffer.data(), static_cast<std::size_t>(count));
  }
  return bytes;
}

std::vector<unsigned long> ParseStatusIds(const std::string& status,
                                          const char* label) {
  const std::string prefix = std::string(label) + ":";
  const std::size_t start = status.find(prefix);
  if (start == std::string::npos) {
    throw LinuxRelaunchError("caller credential metadata rejected");
  }
  const std::size_t end = status.find('\n', start);
  std::istringstream input(status.substr(start + prefix.size(), end - start));
  std::vector<unsigned long> values;
  unsigned long value = 0;
  while (input >> value) values.push_back(value);
  return values;
}

std::vector<gid_t> ParseSupplementaryGroups(const std::string& status) {
  const auto values = ParseStatusIds(status, "Groups");
  if (values.size() > 256) {
    throw LinuxRelaunchError("caller supplementary groups rejected");
  }
  std::vector<gid_t> groups;
  groups.reserve(values.size());
  for (unsigned long value : values) {
    if (value > static_cast<unsigned long>(UINT_MAX)) {
      throw LinuxRelaunchError("caller supplementary group rejected");
    }
    groups.push_back(static_cast<gid_t>(value));
  }
  std::sort(groups.begin(), groups.end());
  groups.erase(std::unique(groups.begin(), groups.end()), groups.end());
  return groups;
}

std::map<std::string, std::string> ParseEnvironment(const std::string& bytes) {
  std::map<std::string, std::string> result;
  std::size_t start = 0;
  while (start < bytes.size()) {
    const std::size_t end = bytes.find('\0', start);
    if (end == std::string::npos) {
      throw LinuxRelaunchError("caller environment framing rejected");
    }
    const std::string entry = bytes.substr(start, end - start);
    const std::size_t separator = entry.find('=');
    if (separator != std::string::npos && separator != 0) {
      result.emplace(entry.substr(0, separator), entry.substr(separator + 1));
    }
    start = end + 1;
  }
  return result;
}

bool SafeValue(const std::string& value, std::size_t maximum) {
  return !value.empty() && value.size() <= maximum &&
         value.find('\n') == std::string::npos &&
         value.find('\r') == std::string::npos &&
         value.find('\0') == std::string::npos;
}

void AddEnvironment(std::vector<std::string>* result,
                    const std::string& key,
                    const std::string& value) {
  if (!SafeValue(value, 4096) || key.find('=') != std::string::npos) {
    throw LinuxRelaunchError("sanitized relaunch environment rejected");
  }
  result->push_back(key + "=" + value);
}

bool IsHomeFile(const std::string& path, const std::string& home, uid_t uid) {
  const std::filesystem::path normalized =
      std::filesystem::path(path).lexically_normal();
  const std::filesystem::path normalized_home =
      std::filesystem::path(home).lexically_normal();
  auto candidate = normalized.begin();
  for (auto expected = normalized_home.begin(); expected != normalized_home.end();
       ++expected, ++candidate) {
    if (candidate == normalized.end() || *candidate != *expected) return false;
  }
  if (candidate == normalized.end()) return false;
  struct stat status {};
  return normalized.is_absolute() && lstat(normalized.c_str(), &status) == 0 &&
         S_ISREG(status.st_mode) && !S_ISLNK(status.st_mode) &&
         status.st_uid == uid && (status.st_mode & (S_IWGRP | S_IWOTH)) == 0;
}

bool IsOwnedHomeDirectory(const std::string& path, uid_t uid) {
  const std::filesystem::path normalized =
      std::filesystem::path(path).lexically_normal();
  struct stat status {};
  return normalized.is_absolute() && normalized != "/" &&
         lstat(normalized.c_str(), &status) == 0 && S_ISDIR(status.st_mode) &&
         !S_ISLNK(status.st_mode) && status.st_uid == uid &&
         (status.st_mode & (S_IWGRP | S_IWOTH)) == 0;
}

std::vector<std::string> SanitizedEnvironment(
    uid_t uid,
    const std::string& user,
    const std::string& home,
    const std::string& shell,
    const std::map<std::string, std::string>& source) {
  std::vector<std::string> result;
  AddEnvironment(&result, "HOME", home);
  AddEnvironment(&result, "USER", user);
  AddEnvironment(&result, "LOGNAME", user);
  AddEnvironment(&result, "PATH", "/usr/local/bin:/usr/bin:/bin");
  if (SafeValue(shell, 4096) && shell.front() == '/') {
    AddEnvironment(&result, "SHELL", shell);
  }
  const std::string runtime = "/run/user/" + std::to_string(uid);
  const auto xdg = source.find("XDG_RUNTIME_DIR");
  if (xdg != source.end() && xdg->second == runtime) {
    AddEnvironment(&result, xdg->first, xdg->second);
  }
  const auto bus = source.find("DBUS_SESSION_BUS_ADDRESS");
  if (bus != source.end() && bus->second == "unix:path=" + runtime + "/bus") {
    AddEnvironment(&result, bus->first, bus->second);
  }
  static const std::regex display("^:[0-9]{1,5}(\\.[0-9]{1,3})?$");
  static const std::regex leaf("^[A-Za-z0-9._-]{1,128}$");
  static const std::regex locale("^[A-Za-z0-9_.@-]{1,64}$");
  for (const char* key : {"DISPLAY", "WAYLAND_DISPLAY", "LANG", "LC_ALL",
                          "XDG_CURRENT_DESKTOP"}) {
    const auto found = source.find(key);
    if (found == source.end()) continue;
    const bool accepted =
        (std::string(key) == "DISPLAY" &&
         std::regex_match(found->second, display)) ||
        ((std::string(key) == "WAYLAND_DISPLAY" ||
          std::string(key) == "XDG_CURRENT_DESKTOP") &&
         std::regex_match(found->second, leaf)) ||
        ((std::string(key) == "LANG" || std::string(key) == "LC_ALL") &&
         std::regex_match(found->second, locale));
    if (accepted) AddEnvironment(&result, found->first, found->second);
  }
  const auto authority = source.find("XAUTHORITY");
  if (authority != source.end() &&
      IsHomeFile(authority->second, home, uid)) {
    AddEnvironment(&result, authority->first, authority->second);
  }
#if defined(DESKTOP_UPDATER_NATIVE_TESTING)
  const auto proof = source.find("DESKTOP_UPDATER_TEST_RELAUNCH_PROOF");
  if (proof != source.end() && SafeValue(proof->second, 4096) &&
      std::filesystem::path(proof->second).is_absolute()) {
    AddEnvironment(&result, proof->first, proof->second);
  }
#endif
  return result;
}

[[noreturn]] void ChildExecFailure(int pipe_fd, int stage) {
  const std::array<int, 2> failure{stage, errno};
  const unsigned char* bytes =
      reinterpret_cast<const unsigned char*>(failure.data());
  std::size_t offset = 0;
  while (offset < sizeof(failure)) {
    const ssize_t count = write(pipe_fd, bytes + offset,
                                sizeof(failure) - offset);
    if (count > 0) {
      offset += static_cast<std::size_t>(count);
    } else if (count < 0 && errno == EINTR) {
      continue;
    } else {
      break;
    }
  }
  _exit(127);
}

void ReapFailedChild(pid_t child) {
  int status = 0;
  for (;;) {
    const pid_t result = waitpid(child, &status, 0);
    if (result == child || (result < 0 && errno == ECHILD)) return;
    if (result < 0 && errno == EINTR) continue;
    return;
  }
}

}  // namespace

LinuxProcessLauncher::Identity CaptureLinuxRelaunchIdentity(
    pid_t process_id,
    std::uint64_t process_start_identity,
    uid_t uid,
    gid_t gid) {
  if (process_id <= 0 ||
      LinuxProcessStartIdentity(process_id) != process_start_identity) {
    throw LinuxRelaunchError("relaunch caller process identity changed");
  }
  const std::string status = ReadProcFile(process_id, "status", 128 * 1024);
  const auto uids = ParseStatusIds(status, "Uid");
  const auto gids = ParseStatusIds(status, "Gid");
  if (uids.size() != 4 || gids.size() != 4 ||
      !std::all_of(uids.begin(), uids.end(),
                   [uid](unsigned long value) { return value == uid; }) ||
      !std::all_of(gids.begin(), gids.end(),
                   [gid](unsigned long value) { return value == gid; })) {
    throw LinuxRelaunchError("relaunch caller credentials changed");
  }
  std::array<char, 16 * 1024> password_buffer{};
  passwd password{};
  passwd* resolved = nullptr;
  const auto source_environment = ParseEnvironment(
      ReadProcFile(process_id, "environ", 1024 * 1024));
  const int password_result =
      getpwuid_r(uid, &password, password_buffer.data(),
                 password_buffer.size(), &resolved);
  std::string user;
  std::string home;
  std::string shell;
  if (password_result == 0 && resolved != nullptr &&
      password.pw_name != nullptr && password.pw_dir != nullptr &&
      IsOwnedHomeDirectory(password.pw_dir, uid)) {
    user = password.pw_name;
    home = password.pw_dir;
    shell = password.pw_shell == nullptr ? "" : password.pw_shell;
  } else {
    const auto source_home = source_environment.find("HOME");
    if (source_home == source_environment.end() ||
        !IsOwnedHomeDirectory(source_home->second, uid)) {
      throw LinuxRelaunchError("relaunch user account unavailable");
    }
    user = std::to_string(uid);
    home = source_home->second;
    shell = "/bin/sh";
  }
  LinuxProcessLauncher::Identity result;
  result.source_process_id = process_id;
  result.source_process_start_identity = process_start_identity;
  result.uid = uid;
  result.gid = gid;
  result.supplementary_groups = ParseSupplementaryGroups(status);
  result.home_directory = home;
  result.sanitized_environment = SanitizedEnvironment(
      uid, user, home, shell, source_environment);
  if (LinuxProcessStartIdentity(process_id) != process_start_identity) {
    throw LinuxRelaunchError("relaunch caller process changed during capture");
  }
  return result;
}

FdRelativeLinuxPayloadVerifier::FdRelativeLinuxPayloadVerifier(
    LinuxVerifiedPayloadIdentity expectation)
    : expectation_(std::move(expectation)) {}

LinuxVerifiedPayloadIdentity FdRelativeLinuxPayloadVerifier::Verify(
    int parent,
    const std::string& payload_leaf) {
  (void)stageProvenance;
  auto root = OpenPayloadRoot(parent, payload_leaf);
  auto provenance =
      OpenLinuxRelativeNoFollow(root.get(), kStageProvenance, O_RDONLY);
  const std::string provenance_json = ReadFd(provenance.get(), 1024 * 1024);
  const std::string provenance_sha256 = Sha256Fd(provenance.get());
  JsonValue marker;
  try {
    marker = ParseJson(provenance_json);
  } catch (const std::exception&) {
    throw LinuxRelaunchError("stage provenance JSON rejected");
  }
  if (EncodeCanonicalJson(marker) != provenance_json) {
    throw LinuxRelaunchError("stage provenance is not canonical JSON");
  }
  RequireKeys(marker, {"artifactSha256", "descriptorSha256", "entries",
                       "nonce", "packageId", "schemaVersion"});
  if (marker.at("schemaVersion").integer() != 1) {
    throw LinuxRelaunchError("stage provenance schema rejected");
  }

  auto executable =
      OpenExecutable(root.get(), expectation_.executable_relative_path);
  const LinuxFileIdentity executable_identity =
      ReadLinuxFileIdentity(executable.get());
  const std::string executable_sha256 = Sha256Fd(executable.get());
  bool executable_bound = false;
  for (const auto& entry : marker.at("entries").array()) {
    if (entry.at("path").string() == expectation_.executable_relative_path) {
      executable_bound = entry.at("kind").string() == "file" &&
                         entry.at("sha256").string() == executable_sha256;
    }
  }
  if (!executable_bound) {
    throw LinuxRelaunchError("executable is absent from stage provenance");
  }

  // Linux signer_identity is the policy-sealed identity of the signed release
  // descriptor. Its descriptor and artifact digests are re-bound below.
  LinuxVerifiedPayloadIdentity observed{
      marker.at("packageId").string(),
      expectation_.signer_identity,
      marker.at("descriptorSha256").string(),
      provenance_sha256,
      marker.at("artifactSha256").string(),
      expectation_.executable_relative_path,
      executable_sha256,
      executable_identity.mode,
      executable_identity.uid,
      executable_identity.gid,
  };
  if (observed != expectation_) {
    throw LinuxRelaunchError(
        "payload policy, provenance, artifact, executable, owner, or mode mismatch");
  }
  return observed;
}

void FexecveLinuxProcessLauncher::Launch(
    int executable_fd,
    const std::string& argv0,
    const LinuxProcessLauncher::Identity& identity) {
  if (executable_fd < 0 || argv0.empty() || identity.source_process_id <= 0 ||
      identity.home_directory.empty() ||
      identity.sanitized_environment.empty()) {
    throw LinuxRelaunchError("verified relaunch launch context rejected");
  }
  std::vector<char> mutable_argv0(argv0.begin(), argv0.end());
  mutable_argv0.push_back('\0');
  std::vector<std::vector<char>> environment_storage;
  std::vector<char*> environment;
  environment_storage.reserve(identity.sanitized_environment.size());
  environment.reserve(identity.sanitized_environment.size() + 1);
  for (const std::string& entry : identity.sanitized_environment) {
    if (entry.empty() || entry.find('=') == std::string::npos ||
        entry.find('\0') != std::string::npos) {
      throw LinuxRelaunchError("verified relaunch environment rejected");
    }
    environment_storage.emplace_back(entry.begin(), entry.end());
    environment_storage.back().push_back('\0');
  }
  for (auto& entry : environment_storage) environment.push_back(entry.data());
  environment.push_back(nullptr);
  int error_pipe[2] = {-1, -1};
  if (pipe2(error_pipe, O_CLOEXEC) != 0) {
    throw LinuxRelaunchError("verified relaunch exec proof pipe failed");
  }
  UniqueLinuxFd read_end(error_pipe[0]);
  UniqueLinuxFd write_end(error_pipe[1]);
  // Keep one descriptor for the executable open across exec. In particular,
  // fexecve(3) implementations that route through /proc/self/fd cannot launch
  // a script or some dynamically linked executables from an O_CLOEXEC
  // descriptor: the interpreter observes a descriptor that has already been
  // closed and exec fails with ENOENT. F_DUPFD preserves the pinned open-file
  // description while deliberately clearing FD_CLOEXEC.
  const int inherited_executable_fd = fcntl(executable_fd, F_DUPFD, 64);
  if (inherited_executable_fd < 0) {
    throw LinuxRelaunchError("verified relaunch executable duplicate failed");
  }
  UniqueLinuxFd inherited_executable(inherited_executable_fd);
  const pid_t child = fork();
  if (child < 0) {
    throw LinuxRelaunchError("verified relaunch fork failed");
  }
  if (child == 0) {
    read_end.reset();
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
      ChildExecFailure(write_end.get(), 1);
    }
    if (geteuid() == 0) {
      if (setgroups(identity.supplementary_groups.size(),
                    identity.supplementary_groups.empty()
                        ? nullptr
                        : identity.supplementary_groups.data()) != 0) {
        ChildExecFailure(write_end.get(), 2);
      }
      if (setresgid(identity.gid, identity.gid, identity.gid) != 0) {
        ChildExecFailure(write_end.get(), 3);
      }
      if (setresuid(identity.uid, identity.uid, identity.uid) != 0) {
        ChildExecFailure(write_end.get(), 4);
      }
    }
    gid_t real_gid = 0;
    gid_t effective_gid = 0;
    gid_t saved_gid = 0;
    uid_t real_uid = 0;
    uid_t effective_uid = 0;
    uid_t saved_uid = 0;
    if (getresgid(&real_gid, &effective_gid, &saved_gid) != 0 ||
        getresuid(&real_uid, &effective_uid, &saved_uid) != 0 ||
        real_gid != identity.gid || effective_gid != identity.gid ||
        saved_gid != identity.gid || real_uid != identity.uid ||
        effective_uid != identity.uid || saved_uid != identity.uid) {
      ChildExecFailure(write_end.get(), 5);
    }
    std::array<gid_t, 256> observed_groups{};
    const int count = getgroups(observed_groups.size(),
                                observed_groups.data());
    if (count < 0 ||
        static_cast<std::size_t>(count) !=
            identity.supplementary_groups.size()) {
      ChildExecFailure(write_end.get(), 6);
    }
    std::sort(observed_groups.begin(), observed_groups.begin() + count);
    if (!std::equal(observed_groups.begin(), observed_groups.begin() + count,
                    identity.supplementary_groups.begin())) {
      errno = EPERM;
      ChildExecFailure(write_end.get(), 7);
    }
    (void)umask(022);
    if (chdir(identity.home_directory.c_str()) != 0 && chdir("/") != 0) {
      ChildExecFailure(write_end.get(), 8);
    }
    char* argv[] = {mutable_argv0.data(), nullptr};
#if defined(SYS_execveat)
    syscall(SYS_execveat, inherited_executable.get(), "", argv,
            environment.data(),
            AT_EMPTY_PATH);
    if (errno != ENOSYS && errno != ENOENT) {
      ChildExecFailure(write_end.get(), 9);
    }
#endif
    fexecve(inherited_executable.get(), argv, environment.data());
    ChildExecFailure(write_end.get(), 10);
  }
  write_end.reset();
  pollfd descriptor{read_end.get(), POLLIN | POLLHUP, 0};
  int observed = -1;
  do {
    observed = poll(&descriptor, 1, 10'000);
  } while (observed < 0 && errno == EINTR);
  if (observed <= 0) {
    (void)kill(child, SIGKILL);
    ReapFailedChild(child);
    throw LinuxRelaunchError("verified relaunch exec proof timed out");
  }
  std::array<int, 2> failure{};
  ssize_t count = -1;
  do {
    count = read(read_end.get(), failure.data(), sizeof(failure));
  } while (count < 0 && errno == EINTR);
  if (count == 0) {
    int status = 0;
    (void)waitpid(child, &status, WNOHANG);
    return;
  }
  ReapFailedChild(child);
  throw LinuxRelaunchError(
      "fexecve verified relaunch failed at child stage " +
      std::to_string(failure[0]) + " (errno " +
      std::to_string(failure[1]) + ")");
}

LinuxRelaunchService::LinuxRelaunchService(
    LinuxVerifiedPayloadIdentity expected_payload_identity,
    LinuxInstallPayloadVerifier& verifier,
    LinuxProcessLauncher& launcher,
    LinuxProcessLauncher::Identity launch_identity)
    : expected_payload_identity_(std::move(expected_payload_identity)),
      verifier_(verifier),
      launcher_(launcher),
      launch_identity_(std::move(launch_identity)) {}

void LinuxRelaunchService::Relaunch(
    const std::filesystem::path& application_path) {
  const auto application =
      std::filesystem::absolute(application_path).lexically_normal();
  auto parent = OpenLinuxDirectory(application.parent_path().string());
  const std::string leaf = application.filename().string();
  if (verifier_.Verify(parent.get(), leaf) != expected_payload_identity_) {
    throw LinuxRelaunchError("activated payload identity mismatch");
  }
  auto root = OpenPayloadRoot(parent.get(), leaf);
  auto executable =
      OpenExecutable(root.get(), expected_payload_identity_.executable_relative_path);
  const LinuxFileIdentity retained = ReadLinuxFileIdentity(executable.get());
  if (retained.mode != expected_payload_identity_.executable_mode ||
      retained.uid != expected_payload_identity_.executable_uid ||
      retained.gid != expected_payload_identity_.executable_gid ||
      Sha256Fd(executable.get()) != expected_payload_identity_.executable_sha256) {
    throw LinuxRelaunchError("verified executable proof changed before launch");
  }
  launcher_.Launch(executable.get(),
                   expected_payload_identity_.executable_relative_path,
                   launch_identity_);
}

}  // namespace desktop_updater::helper
