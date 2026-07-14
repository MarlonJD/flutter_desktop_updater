#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#include <chrono>
#include <filesystem>
#include <regex>
#include <string>

#include "json_value.h"
#include "linux_helper_policy.h"
#include "linux_reservation.h"
#include "unix_socket_transport.h"

namespace {

constexpr char kInstalledBroker[] = "/usr/libexec/desktop-updater-helper";
const std::regex kPackageId("^[a-z0-9][a-z0-9._-]{1,127}$");

std::string SelfExecutablePath() {
  std::string result(4096, '\0');
  const ssize_t length = readlink("/proc/self/exe", result.data(), result.size());
  if (length <= 0 || static_cast<std::size_t>(length) == result.size()) {
    throw desktop_updater::helper::LinuxHelperPolicyError(
        "helper self path unavailable");
  }
  result.resize(static_cast<std::size_t>(length));
  return result;
}

int Run(int argc, char** argv) {
  if (argc == 2 && std::string(argv[1]) == "--version") return 0;
  if (argc != 5 || std::string(argv[1]) != "--socket" ||
      std::string(argv[3]) != "--nonce") {
    return 64;
  }
  const std::filesystem::path socket_path(argv[2]);
  const std::string nonce(argv[4]);
  const int socket_fd =
      desktop_updater::helper::ConnectAuthenticatedUnixSocket(socket_path,
                                                               nonce);
  try {
    const auto peer =
        desktop_updater::helper::ReadLinuxPeerBinding(socket_fd, nonce);
    const std::string canonical_request =
        desktop_updater::helper::ReceiveCanonicalRequest(socket_fd, 1024 * 1024);
    const auto request =
        desktop_updater::runtime::internal::ParseJson(canonical_request);
    const std::string package_id = request.at("packageId").string();
    if (!std::regex_match(package_id, kPackageId)) {
      throw desktop_updater::helper::LinuxHelperPolicyError(
          "request package ID rejected");
    }

    if (geteuid() == 0) {
      if (SelfExecutablePath() != kInstalledBroker) {
        throw desktop_updater::helper::LinuxHelperPolicyError(
            "root mode requires fixed installed broker");
      }
      const auto policy = desktop_updater::helper::LinuxHelperPolicy::Load(
          std::filesystem::path("/etc/desktop-updater/policies") /
              (package_id + ".json"),
          package_id);
      const auto broker =
          desktop_updater::helper::VerifyProtectedLinuxFile(kInstalledBroker);
      desktop_updater::helper::ValidateLinuxBrokerIdentity(broker, policy);
      desktop_updater::helper::VerifyLinuxPeerExecutable(
          peer.pid, peer.process_start_identity, policy.application_signer());
    }

    const pid_t caller_pid = static_cast<pid_t>(
        request.at("caller").at("processId").integer());
    if (caller_pid != peer.pid || request.at("requestNonce").string() != nonce) {
      throw desktop_updater::helper::UnixSocketTransportError(
          "request caller or nonce does not match authenticated peer");
    }
    const std::filesystem::path target_path(
        request.at("target").at("pathHint").string());
    const std::filesystem::path stage_path(
        request.at("stage").at("pathHint").string());
    struct stat target_status {};
    const bool root_owned_target =
        lstat(target_path.c_str(), &target_status) == 0 &&
        target_status.st_uid == 0;
    const bool broker_mode = geteuid() == 0;
    desktop_updater::helper::LinuxReservationStore store(broker_mode);
    const auto expires = std::chrono::duration_cast<std::chrono::milliseconds>(
                             std::chrono::system_clock::now()
                                 .time_since_epoch())
                             .count() +
                         30'000;
    auto reservation = store.Prepare({
        request.at("transactionId").string(), target_path.parent_path(),
        target_path.filename().string(), stage_path, caller_pid, nonce, expires,
        root_owned_target});
    const std::string response = "READY " + reservation->ready_token();
    if (send(socket_fd, response.data(), response.size(), MSG_NOSIGNAL) !=
        static_cast<ssize_t>(response.size())) {
      throw desktop_updater::helper::UnixSocketTransportError(
          "authenticated response failed");
    }
    std::string command(256, '\0');
    const ssize_t command_length = recv(socket_fd, command.data(), command.size(), 0);
    if (command_length <= 0) {
      store.CallerExited(reservation->transaction_id());
    } else {
      command.resize(static_cast<std::size_t>(command_length));
      const std::string cancel = "CANCEL " + reservation->ready_token();
      const std::string commit = "COMMIT " + reservation->ready_token();
      if (command == cancel) {
        store.Cancel(reservation->transaction_id(), reservation->ready_token());
      } else if (command == commit) {
        const auto now =
            std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::system_clock::now().time_since_epoch())
                .count();
        store.Commit(reservation->transaction_id(), reservation->ready_token(),
                     now);
      } else {
        throw desktop_updater::helper::UnixSocketTransportError(
            "reservation command rejected");
      }
    }
    close(socket_fd);
    return 0;
  } catch (...) {
    close(socket_fd);
    throw;
  }
}

}  // namespace

int main(int argc, char** argv) {
  try {
    return Run(argc, argv);
  } catch (const std::exception&) {
    return 77;
  }
}
