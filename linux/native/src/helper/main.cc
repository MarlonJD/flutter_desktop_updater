#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <regex>
#include <string>

#include "json_value.h"
#include "linux_control_wire.h"
#include "linux_helper_policy.h"
#include "linux_native_install_service.h"
#include "linux_reservation.h"
#include "native_install_request.h"
#include "native_install_wire.h"
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
    desktop_updater::helper::LinuxSeqpacketWireChannel channel(socket_fd);
    const auto peer =
        desktop_updater::helper::ReadLinuxPeerBinding(socket_fd, nonce);
    const std::string canonical_request =
        channel.ReadFrame();
    const std::string self_executable = SelfExecutablePath();
    const bool broker_mode = self_executable == kInstalledBroker;
    if (geteuid() == 0 && !broker_mode) {
      throw desktop_updater::helper::LinuxHelperPolicyError(
          "root mode requires the fixed installed broker");
    }
    if (broker_mode && geteuid() != 0) {
      throw desktop_updater::helper::LinuxHelperPolicyError(
          "installed broker requires root credentials");
    }
    const auto envelope =
        desktop_updater::runtime::internal::ParseJson(canonical_request);
    if (envelope.find("operation") != nullptr) {
      const auto control =
          desktop_updater::helper::ParseLinuxControlRequestV1(
              canonical_request);
      if (control.request_nonce != nonce ||
          control.caller_process_id != peer.pid ||
          control.caller_process_start_identity !=
              "linux:" + std::to_string(peer.process_start_identity)) {
        throw desktop_updater::helper::UnixSocketTransportError(
            "control caller or nonce does not match authenticated peer");
      }
      desktop_updater::helper::RunLinuxNativeInstallControlService(
          channel, peer, self_executable, broker_mode, canonical_request);
      close(socket_fd);
      return 0;
    }
    const auto request =
        desktop_updater::runtime::internal::
            ParseNativeInstallTransactionRequestV1(canonical_request);
    const std::string package_id = request.package_id;
    if (!std::regex_match(package_id, kPackageId)) {
      throw desktop_updater::helper::LinuxHelperPolicyError(
          "request package ID rejected");
    }

    const pid_t caller_pid = static_cast<pid_t>(request.caller.process_id);
    if (caller_pid != peer.pid || request.request_nonce != nonce ||
        request.caller.process_start_identity !=
            "linux:" + std::to_string(peer.process_start_identity)) {
      throw desktop_updater::helper::UnixSocketTransportError(
          "request caller or nonce does not match authenticated peer");
    }
    const std::filesystem::path target_path(request.target.path_hint);
    if (target_path.filename().string() != request.target.target_name_hint) {
      throw desktop_updater::helper::UnixSocketTransportError(
          "request target name hint changed");
    }
    desktop_updater::helper::RunLinuxNativeInstallService(
        channel, peer, self_executable, broker_mode, canonical_request);
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
  } catch (const std::exception& error) {
    const char* test_diagnostics =
        std::getenv("DESKTOP_UPDATER_TEST_REPORT_HELPER_ERRORS");
    if (test_diagnostics != nullptr && std::string(test_diagnostics) == "1") {
      std::cerr << "desktop-updater-helper test diagnostic: " << error.what()
                << std::endl;
    }
    return 77;
  }
}
