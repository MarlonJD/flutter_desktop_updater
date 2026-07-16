#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "install_strategy.h"

#include <fcntl.h>
#include <openssl/evp.h>
#include <poll.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <iomanip>
#include <optional>
#include <regex>
#include <sstream>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "unix_socket_transport.h"

namespace desktop_updater::helper {
namespace {

namespace fs = std::filesystem;

constexpr std::size_t kMaximumProviderOutput = 1024 * 1024;
constexpr auto kMaximumProviderRuntime = std::chrono::minutes(15);
const std::regex kSha256("^[0-9a-f]{64}$");
const std::regex kPackage("^[A-Za-z0-9][A-Za-z0-9+._-]{0,255}$");
const std::regex kVersion("^[A-Za-z0-9][A-Za-z0-9.+:~_-]{0,127}$");
const std::regex kAuthority("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$");
const std::regex kArchitecture("^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$");
const std::regex kScope("^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$");

class ScopedFd {
 public:
  explicit ScopedFd(int value = -1) : value_(value) {}
  ~ScopedFd() {
    if (value_ >= 0) close(value_);
  }
  ScopedFd(const ScopedFd&) = delete;
  ScopedFd& operator=(const ScopedFd&) = delete;
  int get() const { return value_; }
  int release() {
    const int value = value_;
    value_ = -1;
    return value;
  }
  void reset(int value = -1) {
    if (value_ >= 0) close(value_);
    value_ = value;
  }

 private:
  int value_;
};

std::string Hex(const std::array<unsigned char, 32>& value) {
  std::ostringstream encoded;
  encoded << std::hex << std::setfill('0');
  for (unsigned char byte : value) {
    encoded << std::setw(2) << static_cast<unsigned int>(byte);
  }
  return encoded.str();
}

std::string Sha256RetainedFile(int fd) {
  if (lseek(fd, 0, SEEK_SET) < 0) {
    throw LinuxInstallStrategyError("provider proof seek failed");
  }
  EVP_MD_CTX* context = EVP_MD_CTX_new();
  if (context == nullptr || EVP_DigestInit_ex(context, EVP_sha256(), nullptr) != 1) {
    if (context != nullptr) EVP_MD_CTX_free(context);
    throw LinuxInstallStrategyError("provider proof SHA-256 setup failed");
  }
  std::array<unsigned char, 64 * 1024> buffer{};
  for (;;) {
    ssize_t count = -1;
    do {
      count = read(fd, buffer.data(), buffer.size());
    } while (count < 0 && errno == EINTR);
    if (count == 0) break;
    if (count < 0 || EVP_DigestUpdate(
                         context, buffer.data(),
                         static_cast<std::size_t>(count)) != 1) {
      EVP_MD_CTX_free(context);
      throw LinuxInstallStrategyError("provider proof SHA-256 read failed");
    }
  }
  std::array<unsigned char, 32> digest{};
  unsigned int digest_size = 0;
  if (EVP_DigestFinal_ex(context, digest.data(), &digest_size) != 1 ||
      digest_size != digest.size()) {
    EVP_MD_CTX_free(context);
    throw LinuxInstallStrategyError("provider proof SHA-256 finish failed");
  }
  EVP_MD_CTX_free(context);
  return Hex(digest);
}

void VerifyPinnedProviderFile(const fs::path& path,
                              const std::string& expected_sha256) {
  if (!path.is_absolute() || path.lexically_normal() != path ||
      !std::regex_match(expected_sha256, kSha256)) {
    throw LinuxInstallStrategyError("provider file proof rejected");
  }
  struct stat parent_status {};
  struct stat before {};
  const fs::path parent = path.parent_path();
  const uid_t required_uid = geteuid() == 0 ? 0 : geteuid();
  if (lstat(parent.c_str(), &parent_status) != 0 ||
      !S_ISDIR(parent_status.st_mode) || S_ISLNK(parent_status.st_mode) ||
      parent_status.st_uid != required_uid ||
      (parent_status.st_mode & (S_IWGRP | S_IWOTH)) != 0 ||
      lstat(path.c_str(), &before) != 0 || !S_ISREG(before.st_mode) ||
      S_ISLNK(before.st_mode) || before.st_uid != required_uid ||
      before.st_nlink != 1 ||
      (before.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
    throw LinuxInstallStrategyError(
        "provider file ownership or permissions rejected");
  }
  ScopedFd file(open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
  struct stat retained {};
  if (file.get() < 0 || fstat(file.get(), &retained) != 0 ||
      before.st_dev != retained.st_dev || before.st_ino != retained.st_ino ||
      before.st_size != retained.st_size || before.st_mtim.tv_sec != retained.st_mtim.tv_sec ||
      before.st_mtim.tv_nsec != retained.st_mtim.tv_nsec ||
      Sha256RetainedFile(file.get()) != expected_sha256) {
    throw LinuxInstallStrategyError("provider file identity changed");
  }
}

fs::path RepositoryConfiguration(const LinuxProviderCommand& command) {
  if (command.provider == "apt") {
    const std::string prefix = "Dir::Etc::sourcelist=";
    if (command.arguments.size() != 9 || command.arguments[0] != "-o" ||
        command.arguments[1].rfind(prefix, 0) != 0) {
      throw LinuxInstallStrategyError("APT fixed template rejected");
    }
    return command.arguments[1].substr(prefix.size());
  }
  if (command.provider == "dnf") {
    fs::path root;
#if defined(DESKTOP_UPDATER_NATIVE_TESTING)
    const char* override_root =
        std::getenv("DESKTOP_UPDATER_TEST_REPOSITORY_ROOT");
    if (override_root != nullptr && override_root[0] != '\0') {
      root = override_root;
    }
#endif
    if (root.empty()) root = "/etc/yum.repos.d";
    return root /
           ("desktop-updater-" + command.repository_or_remote_identity +
            ".repo");
  }
  return {};
}

void ValidateFixedCommand(const LinuxProviderCommand& command) {
  if (!std::regex_match(command.package_id, kPackage) ||
      !std::regex_match(command.expected_version_or_revision, kVersion)) {
    throw LinuxInstallStrategyError("provider command identity rejected");
  }
  if (command.provider == "apt") {
    if (!std::regex_match(command.repository_or_remote_identity, kSha256) ||
        !std::regex_match(command.source_artifact_sha256, kSha256)) {
      throw LinuxInstallStrategyError("APT proof identity rejected");
    }
    const std::string repository =
        "Dir::Etc::sourcelist=" + RepositoryConfiguration(command).string();
    const std::vector<std::string> expected = {
        "-o", repository, "-o", "Dir::Etc::sourceparts=-", "install",
        "--yes", "--only-upgrade", "--",
        command.source_artifact_path.string()};
    if (command.executable != "/usr/bin/apt-get" ||
        command.arguments != expected ||
        !std::regex_match(command.expected_architecture,
                          std::regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$"))) {
      throw LinuxInstallStrategyError("APT fixed template rejected");
    }
  } else if (command.provider == "dnf") {
    if (!std::regex_match(command.repository_or_remote_identity, kSha256) ||
        !std::regex_match(command.source_artifact_sha256, kSha256)) {
      throw LinuxInstallStrategyError("DNF proof identity rejected");
    }
    const std::vector<std::string> expected = {
        "upgrade", "-y", "--disablerepo=*",
        "--enablerepo=desktop-updater-" +
            command.repository_or_remote_identity,
        "--", command.source_artifact_path.string()};
    if (command.executable != "/usr/bin/dnf" ||
        command.arguments != expected ||
        !std::regex_match(command.expected_architecture,
                          std::regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$"))) {
      throw LinuxInstallStrategyError("DNF fixed template rejected");
    }
  } else if (command.provider == "flatpak") {
    if (command.arguments.size() != 4 || command.provider_scope.empty() ||
        !std::regex_match(command.repository_or_remote_identity, kAuthority)) {
      throw LinuxInstallStrategyError("Flatpak fixed template rejected");
    }
    const std::vector<std::string> expected = {
        "update", "--noninteractive", "--or-update",
        command.repository_or_remote_identity + ":" + command.package_id +
            "//" + command.provider_scope};
    if (command.executable != "/usr/bin/flatpak" ||
        command.arguments != expected) {
      throw LinuxInstallStrategyError("Flatpak fixed template rejected");
    }
  } else if (command.provider == "snap") {
    if (command.executable != "/usr/bin/snap" ||
        command.arguments.size() != 3 || command.arguments[0] != "refresh" ||
        command.arguments[1] != command.package_id ||
        command.arguments[2] != "--channel=" + command.provider_scope ||
        command.provider_scope.empty() ||
        !std::regex_match(command.repository_or_remote_identity, kAuthority)) {
      throw LinuxInstallStrategyError("Snap fixed template rejected");
    }
  } else {
    throw LinuxInstallStrategyError("provider executable rejected");
  }
}

std::vector<std::string> Lines(const std::string& output) {
  std::vector<std::string> lines;
  std::size_t start = 0;
  while (start < output.size()) {
    const std::size_t end = output.find('\n', start);
    lines.push_back(output.substr(start, end - start));
    if (end == std::string::npos) break;
    start = end + 1;
  }
  return lines;
}

void RequireSuccess(const LinuxProviderProcessResult& result,
                    const char* operation) {
  if (result.exit_code != 0) {
    throw LinuxInstallStrategyError(std::string(operation) + " failed");
  }
}

std::optional<std::string> SingleLine(const std::string& output) {
  std::string value = output;
  if (!value.empty() && value.back() == '\n') value.pop_back();
  if (value.empty() || value.find('\n') != std::string::npos ||
      value.find('\r') != std::string::npos) {
    return std::nullopt;
  }
  return value;
}

bool DecimalIdentity(const std::string& value) {
  return !value.empty() &&
         std::all_of(value.begin(), value.end(), [](unsigned char byte) {
           return byte >= '0' && byte <= '9';
         });
}

std::optional<std::string> ParenthesizedRevision(const std::string& line) {
  const std::size_t open = line.find('(');
  const std::size_t close =
      open == std::string::npos ? std::string::npos
                                : line.find(')', open + 1);
  if (open == std::string::npos || close == std::string::npos ||
      close == open + 1 || line.find('(', open + 1) != std::string::npos ||
      line.find(')', close + 1) != std::string::npos) {
    return std::nullopt;
  }
  return line.substr(open + 1, close - open - 1);
}

std::optional<std::string> SnapChannelRevision(
    const std::string& output,
    const std::string& channel) {
  const std::string prefix = "  " + channel + ": ";
  std::optional<std::string> revision;
  for (const std::string& line : Lines(output)) {
    if (line.rfind(prefix, 0) != 0) continue;
    if (revision.has_value()) return std::nullopt;
    revision = ParenthesizedRevision(line);
  }
  return revision;
}

std::string ProviderStateIdentity(
    const std::string& provider,
    const std::vector<std::string>& provider_owned_fields) {
  std::ostringstream framed;
  framed << provider.size() << ':' << provider << '\n';
  for (const std::string& field : provider_owned_fields) {
    framed << field.size() << ':' << field << '\n';
  }
  return provider + "-state-" + Sha256LinuxBytes(framed.str());
}

std::optional<std::string> ObserveInstalledProviderState(
    LinuxProviderProcessExecutor& executor,
    const LinuxProviderTransaction& transaction,
    const std::string& expected_version_or_revision) {
  if (transaction.provider == "apt") {
    const LinuxProviderProcessResult query = executor.Run(
        "/usr/bin/dpkg-query",
        {"-W", "--showformat=${db:Status-Abbrev}\\n${Version}\\n"
               "${Architecture}\\n",
         transaction.package_id});
    if (query.exit_code != 0) return std::nullopt;
    const auto fields = Lines(query.standard_output);
    if (fields.size() != 3 || fields[0] != "ii " ||
        fields[1] != expected_version_or_revision ||
        fields[2] != transaction.expected_architecture) {
      return std::nullopt;
    }
    return ProviderStateIdentity(
        transaction.provider,
        {transaction.package_id, fields[0], fields[1], fields[2]});
  }
  if (transaction.provider == "dnf") {
    const LinuxProviderProcessResult query = executor.Run(
        "/usr/bin/rpm",
        {"-q", "--qf",
         "%{NAME}\\n%{VERSION}-%{RELEASE}\\n%{ARCH}\\n%{INSTALLTIME}\\n"
         "%{INSTALLTID}\\n",
         transaction.package_id});
    if (query.exit_code != 0) return std::nullopt;
    const auto fields = Lines(query.standard_output);
    if (fields.size() != 5 || fields[0] != transaction.package_id ||
        fields[1] != expected_version_or_revision ||
        fields[2] != transaction.expected_architecture ||
        !DecimalIdentity(fields[3]) || !DecimalIdentity(fields[4])) {
      return std::nullopt;
    }
    return ProviderStateIdentity(transaction.provider, fields);
  }
  if (transaction.provider == "flatpak") {
    const std::string ref =
        transaction.package_id + "//" + transaction.provider_scope;
    const LinuxProviderProcessResult origin = executor.Run(
        "/usr/bin/flatpak", {"info", "--show-origin", ref});
    const LinuxProviderProcessResult commit = executor.Run(
        "/usr/bin/flatpak", {"info", "--show-commit", ref});
    const auto observed_origin = SingleLine(origin.standard_output);
    const auto observed_commit = SingleLine(commit.standard_output);
    if (origin.exit_code != 0 || commit.exit_code != 0 ||
        !observed_origin.has_value() || !observed_commit.has_value() ||
        *observed_origin != transaction.provider_authority ||
        *observed_commit != expected_version_or_revision) {
      return std::nullopt;
    }
    return ProviderStateIdentity(
        transaction.provider,
        {transaction.provider_authority, ref, *observed_commit});
  }
  if (transaction.provider == "snap") {
    if (transaction.provider_authority != "public") {
      const LinuxProviderProcessResult model = executor.Run(
          "/usr/bin/snap", {"model", "--assertion"});
      bool expected_store = false;
      for (const std::string& line : Lines(model.standard_output)) {
        if (line == "store: " + transaction.provider_authority) {
          expected_store = true;
        }
      }
      if (model.exit_code != 0 || !expected_store) {
        return std::nullopt;
      }
    }
    const LinuxProviderProcessResult info =
        executor.Run("/usr/bin/snap", {"info", transaction.package_id});
    if (info.exit_code != 0) return std::nullopt;
    std::optional<std::string> tracking;
    std::optional<std::string> revision;
    for (const std::string& line : Lines(info.standard_output)) {
      constexpr char kTracking[] = "tracking: ";
      constexpr char kInstalled[] = "installed: ";
      if (line.rfind(kTracking, 0) == 0) {
        if (tracking.has_value()) return std::nullopt;
        tracking = line.substr(sizeof(kTracking) - 1);
      } else if (line.rfind(kInstalled, 0) == 0) {
        if (revision.has_value()) return std::nullopt;
        revision = ParenthesizedRevision(line);
        if (!revision.has_value()) return std::nullopt;
      }
    }
    if (!tracking.has_value() || !revision.has_value() ||
        *tracking != transaction.provider_scope ||
        *revision != expected_version_or_revision) {
      return std::nullopt;
    }
    return ProviderStateIdentity(
        transaction.provider,
        {transaction.provider_authority, transaction.package_id,
         *tracking, *revision});
  }
  return std::nullopt;
}

}  // namespace

std::string Sha256LinuxProviderCommand(
    const LinuxProviderCommand& command) {
  std::ostringstream framed;
  auto append = [&framed](const std::string& value) {
    framed << value.size() << ':' << value << '\n';
  };
  append(command.executable);
  append(command.provider);
  append(command.package_id);
  append(command.expected_version_or_revision);
  append(command.expected_architecture);
  append(command.provider_scope);
  append(command.repository_or_remote_identity);
  append(command.source_artifact_path.string());
  append(command.source_artifact_sha256);
  framed << command.arguments.size() << '\n';
  for (const std::string& argument : command.arguments) append(argument);
  return Sha256LinuxBytes(framed.str());
}

LinuxProviderProcessResult PosixLinuxProviderProcessExecutor::Run(
    const std::string& executable,
    const std::vector<std::string>& arguments) {
  if (executable.empty() || executable.front() != '/' ||
      executable.find('\0') != std::string::npos ||
      std::any_of(arguments.begin(), arguments.end(), [](const std::string& arg) {
        return arg.find('\0') != std::string::npos;
      })) {
    throw LinuxInstallStrategyError("provider argv rejected");
  }
  int output_pipe[2] = {-1, -1};
  if (pipe2(output_pipe, O_CLOEXEC) != 0) {
    throw LinuxInstallStrategyError("provider output pipe failed");
  }
  ScopedFd read_end(output_pipe[0]);
  ScopedFd write_end(output_pipe[1]);
  const pid_t child = fork();
  if (child < 0) {
    throw LinuxInstallStrategyError("provider fork failed");
  }
  if (child == 0) {
    read_end.reset();
    if (dup2(write_end.get(), STDOUT_FILENO) < 0) _exit(126);
    const int null_fd = open("/dev/null", O_WRONLY | O_CLOEXEC);
    if (null_fd < 0 || dup2(null_fd, STDERR_FILENO) < 0) _exit(126);
    std::vector<std::vector<char>> storage;
    storage.reserve(arguments.size() + 1);
    storage.emplace_back(executable.begin(), executable.end());
    storage.back().push_back('\0');
    for (const std::string& argument : arguments) {
      storage.emplace_back(argument.begin(), argument.end());
      storage.back().push_back('\0');
    }
    std::vector<char*> argv;
    argv.reserve(storage.size() + 1);
    for (auto& entry : storage) argv.push_back(entry.data());
    argv.push_back(nullptr);
    std::array<char*, 5> environment = {
        const_cast<char*>("PATH=/usr/sbin:/usr/bin:/sbin:/bin"),
        const_cast<char*>("LANG=C"), const_cast<char*>("LC_ALL=C"),
        const_cast<char*>("HOME=/root"), nullptr};
    execve(executable.c_str(), argv.data(), environment.data());
    _exit(127);
  }
  write_end.reset();
  const int flags = fcntl(read_end.get(), F_GETFL, 0);
  if (flags < 0 || fcntl(read_end.get(), F_SETFL, flags | O_NONBLOCK) != 0) {
    (void)kill(child, SIGKILL);
    (void)waitpid(child, nullptr, 0);
    throw LinuxInstallStrategyError("provider output setup failed");
  }
  const auto deadline = std::chrono::steady_clock::now() +
                        kMaximumProviderRuntime;
  std::string output;
  bool pipe_closed = false;
  bool child_exited = false;
  int status = 0;
  while (!pipe_closed || !child_exited) {
    if (std::chrono::steady_clock::now() >= deadline) {
      (void)kill(child, SIGKILL);
      (void)waitpid(child, nullptr, 0);
      throw LinuxInstallStrategyError("provider process timed out");
    }
    pollfd observed{read_end.get(), POLLIN | POLLHUP, 0};
    (void)poll(&observed, 1, 100);
    if ((observed.revents & (POLLIN | POLLHUP)) != 0) {
      std::array<char, 8192> buffer{};
      for (;;) {
        const ssize_t count = read(read_end.get(), buffer.data(), buffer.size());
        if (count > 0) {
          if (output.size() + static_cast<std::size_t>(count) >
              kMaximumProviderOutput) {
            (void)kill(child, SIGKILL);
            (void)waitpid(child, nullptr, 0);
            throw LinuxInstallStrategyError("provider output exceeded bound");
          }
          output.append(buffer.data(), static_cast<std::size_t>(count));
          continue;
        }
        if (count == 0) pipe_closed = true;
        if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK &&
            errno != EINTR) {
          (void)kill(child, SIGKILL);
          (void)waitpid(child, nullptr, 0);
          throw LinuxInstallStrategyError("provider output read failed");
        }
        break;
      }
    }
    if (!child_exited) {
      const pid_t waited = waitpid(child, &status, WNOHANG);
      child_exited = waited == child;
      if (waited < 0 && errno != EINTR) {
        throw LinuxInstallStrategyError("provider wait failed");
      }
    }
  }
  const int exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 128;
  return {exit_code, std::move(output), ""};
}

LinuxFixedProviderRunner::LinuxFixedProviderRunner(
    LinuxProviderProcessExecutor& executor)
    : executor_(executor) {}

std::string LinuxFixedProviderRunner::StartFixed(
    const LinuxProviderCommand& command) {
  ValidateFixedCommand(command);
  if (command.provider == "apt" || command.provider == "dnf") {
    VerifyPinnedProviderFile(RepositoryConfiguration(command),
                             command.repository_or_remote_identity);
    VerifyPinnedProviderFile(command.source_artifact_path,
                             command.source_artifact_sha256);
    LinuxProviderProcessResult metadata;
    if (command.provider == "apt") {
      metadata = executor_.Run(
          "/usr/bin/dpkg-deb",
          {"--show", "--showformat=${Package}\\n${Version}\\n${Architecture}\\n",
           command.source_artifact_path.string()});
    } else {
      metadata = executor_.Run(
          "/usr/bin/rpm",
          {"-qp", "--qf", "%{NAME}\\n%{VERSION}-%{RELEASE}\\n%{ARCH}\\n",
           command.source_artifact_path.string()});
    }
    RequireSuccess(metadata, "provider package metadata verification");
    const auto fields = Lines(metadata.standard_output);
    if (fields.size() < 3 || fields[0] != command.package_id ||
        fields[1] != command.expected_version_or_revision ||
        fields[2] != command.expected_architecture) {
      throw LinuxInstallStrategyError("provider package metadata changed");
    }
    VerifyPinnedProviderFile(RepositoryConfiguration(command),
                             command.repository_or_remote_identity);
    VerifyPinnedProviderFile(command.source_artifact_path,
                             command.source_artifact_sha256);
  } else if (command.provider == "flatpak") {
    const auto remote = executor_.Run(
        "/usr/bin/flatpak",
        {"remote-info", "--show-commit",
         command.repository_or_remote_identity,
         command.package_id + "//" + command.provider_scope});
    RequireSuccess(remote, "Flatpak remote verification");
    if (Lines(remote.standard_output).empty() ||
        Lines(remote.standard_output).front() !=
            command.expected_version_or_revision) {
      throw LinuxInstallStrategyError("Flatpak remote revision changed");
    }
  } else if (command.provider == "snap") {
    const auto store =
        executor_.Run("/usr/bin/snap", {"info", command.package_id});
    RequireSuccess(store, "Snap Store verification");
    const auto advertised = SnapChannelRevision(
        store.standard_output, command.provider_scope);
    if (!advertised.has_value() ||
        *advertised != command.expected_version_or_revision) {
      throw LinuxInstallStrategyError("Snap Store revision changed");
    }
  }
  const auto started = executor_.Run(command.executable, command.arguments);
  RequireSuccess(started, "provider transaction");
  LinuxProviderTransaction transaction{
      command.provider, command.package_id, "",
      LinuxProviderTransactionState::kManagerStarted};
  transaction.expected_architecture = command.expected_architecture;
  transaction.provider_scope = command.provider_scope;
  transaction.provider_authority = command.repository_or_remote_identity;
  const auto provider_identity = ObserveInstalledProviderState(
      executor_, transaction, command.expected_version_or_revision);
  if (!provider_identity.has_value()) {
    throw LinuxInstallStrategyError(
        "provider-owned installed state could not be verified");
  }
  return *provider_identity;
}

LinuxProviderStateObservation LinuxFixedProviderRunner::QueryInstalledState(
    const LinuxProviderTransaction& transaction,
    const std::string& expected_version_or_revision) {
  if (transaction.transaction_identity.empty() ||
      !std::regex_match(transaction.package_id, kPackage) ||
      !std::regex_match(expected_version_or_revision, kVersion)) {
    return {LinuxProviderTransactionState::kManualActionRequired,
            transaction.transaction_identity};
  }
  const bool system_provider = transaction.provider == "apt" ||
                               transaction.provider == "dnf";
  const bool external_provider = transaction.provider == "flatpak" ||
                                 transaction.provider == "snap";
  if ((!system_provider && !external_provider) ||
      (system_provider &&
       (!std::regex_match(transaction.expected_architecture, kArchitecture) ||
        !transaction.provider_scope.empty() ||
        !std::regex_match(transaction.provider_authority, kSha256))) ||
      (external_provider &&
       (!transaction.expected_architecture.empty() ||
        !std::regex_match(transaction.provider_scope, kScope) ||
        !std::regex_match(transaction.provider_authority, kAuthority)))) {
    return {LinuxProviderTransactionState::kManualActionRequired,
            transaction.transaction_identity};
  }
  std::optional<std::string> observed;
  try {
    observed = ObserveInstalledProviderState(
        executor_, transaction, expected_version_or_revision);
  } catch (...) {
    return {LinuxProviderTransactionState::kVerificationPending,
            transaction.transaction_identity};
  }
  if (!observed.has_value()) {
    return {LinuxProviderTransactionState::kVerificationPending,
            transaction.transaction_identity};
  }
  const bool pending = transaction.transaction_identity.rfind("pending-", 0) == 0;
  if (!pending && transaction.transaction_identity != *observed) {
    return {LinuxProviderTransactionState::kManualActionRequired,
            transaction.transaction_identity};
  }
  return {LinuxProviderTransactionState::kCompleted, *observed};
}

}  // namespace desktop_updater::helper
