#include <sys/stat.h>

#include <cstdint>
#include <fstream>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

#include "desktop_updater_runtime.h"

namespace {

class Arguments {
 public:
  Arguments(int count, char** values) {
    for (int index = 1; index < count; ++index) {
      const std::string argument = values[index];
      if (argument == "--smoke" || argument == "--verify-protected-root") {
        flags_[argument] = true;
        continue;
      }
      if (argument.rfind("--", 0) != 0 || index + 1 >= count) {
        throw std::invalid_argument("Invalid smoke argument: " + argument);
      }
      values_[argument] = values[++index];
    }
  }

  bool Has(const std::string& name) const {
    return flags_.find(name) != flags_.end();
  }

  std::string Required(const std::string& name) const {
    const auto found = values_.find(name);
    if (found == values_.end() || found->second.empty()) {
      throw std::invalid_argument("Missing required smoke argument: " + name);
    }
    return found->second;
  }

 private:
  std::map<std::string, bool> flags_;
  std::map<std::string, std::string> values_;
};

std::vector<std::uint8_t> DecodeHex(const std::string& value) {
  if (value.size() != 64) {
    throw std::invalid_argument("Smoke Ed25519 key must contain 32 bytes.");
  }
  std::vector<std::uint8_t> result;
  result.reserve(32);
  for (std::size_t index = 0; index < value.size(); index += 2) {
    const std::string byte = value.substr(index, 2);
    std::size_t parsed = 0;
    const unsigned long number = std::stoul(byte, &parsed, 16);
    if (parsed != 2 || number > 255) {
      throw std::invalid_argument("Smoke Ed25519 key is not hexadecimal.");
    }
    result.push_back(static_cast<std::uint8_t>(number));
  }
  return result;
}

desktop_updater::runtime::RuntimeConfiguration Configuration(
    const std::string& archive_url,
    const std::string& package_id,
    const std::vector<std::uint8_t>& public_key) {
  desktop_updater::runtime::RuntimeConfiguration configuration;
  configuration.app_archive_url = archive_url;
  configuration.expected_package_id = package_id;
  configuration.current_version = "2.7.0";
  configuration.has_current_build_number = true;
  configuration.current_build_number = 270;
  configuration.current_updater_version = "2.7.0";
  configuration.platform = "linux";
  configuration.channel = "stable";
  configuration.installation_identity = "linux-native-runtime-smoke";
  configuration.pinned_public_keys_by_id["native-runtime-smoke-stable"] =
      public_key;
  configuration.minimum_os_resolver =
      [](const std::string&, const std::string&) { return true; };
  configuration.request_headers_provider = [](const std::string&) {
    return std::map<std::string, std::string>();
  };
  return configuration;
}

void WriteDiagnostics(const std::string& path,
                      const std::vector<std::string>& lines) {
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  for (const std::string& line : lines) output << line << '\n';
  if (!output) throw std::runtime_error("Unable to write runtime diagnostics.");
}

bool SameMetadata(const struct stat& left, const struct stat& right) {
  return left.st_dev == right.st_dev && left.st_ino == right.st_ino &&
         left.st_mode == right.st_mode && left.st_size == right.st_size &&
         left.st_mtime == right.st_mtime;
}

}  // namespace

int main(int argc, char** argv) try {
  const Arguments arguments(argc, argv);
  if (!arguments.Has("--smoke")) {
    const auto configuration = Configuration(
        "https://updates.example.test/app-archive.json",
        "com.example.native-runtime-smoke", std::vector<std::uint8_t>(32, 1));
    const auto validation =
        desktop_updater::runtime::ValidateRuntimeConfiguration(configuration);
    if (!validation.ok) {
      std::cerr << validation.error << std::endl;
      return 1;
    }
    std::cout << "desktop_updater Linux runtime API compiled: "
              << static_cast<int>(
                     desktop_updater::runtime::RuntimeOutcome::kNoUpdate)
              << std::endl;
    return 0;
  }

  auto client = desktop_updater::runtime::UpdateClient(Configuration(
      arguments.Required("--app-archive-url"),
      arguments.Required("--package-id"),
      DecodeHex(arguments.Required("--public-key-hex"))));
  const auto check = client.CheckForUpdate();
  if (check.outcome !=
      desktop_updater::runtime::RuntimeOutcome::kUpdateAvailable) {
    throw std::runtime_error("CheckForUpdate failed: " + check.message);
  }
  const std::string smoke_root = arguments.Required("--smoke-root");
  const std::string executable_relative_path =
      arguments.Required("--executable-relative-path");
  const auto staged = client.DownloadVerifyAndStage(
      smoke_root + "/downloads", smoke_root + "/staging",
      executable_relative_path);
  if (staged.outcome !=
      desktop_updater::runtime::RuntimeOutcome::kUpdateAvailable) {
    throw std::runtime_error("DownloadVerifyAndStage failed: " +
                             staged.message);
  }

  if (arguments.Has("--verify-protected-root")) {
    struct stat before {};
    struct stat after {};
    if (lstat("/usr/bin", &before) != 0) {
      throw std::runtime_error("Unable to inspect protected /usr/bin root.");
    }
    const auto rejected = client.InstallAndRelaunch(
        "/usr/bin", executable_relative_path, {},
        arguments.Required("--diagnostics-log"));
    if (rejected.outcome !=
            desktop_updater::runtime::RuntimeOutcome::kInstallHandoffFailure ||
        lstat("/usr/bin", &after) != 0 || !SameMetadata(before, after)) {
      throw std::runtime_error(
          "Protected /usr/bin must remain unchanged after rejection.");
    }
  }

  WriteDiagnostics(smoke_root + "/runtime-diagnostics.log",
                   client.RedactedDiagnostics());
  const auto handoff = client.InstallAndRelaunch(
      arguments.Required("--install-root"), executable_relative_path, {},
      arguments.Required("--diagnostics-log"));
  if (handoff.outcome !=
      desktop_updater::runtime::RuntimeOutcome::kUpdateAvailable) {
    throw std::runtime_error("InstallAndRelaunch failed: " + handoff.message);
  }
  std::cout << "InstallAndRelaunch scheduled " << handoff.release_version
            << " from " << handoff.artifact_kind << std::endl;
  return 0;
} catch (const std::exception& error) {
  std::cerr << error.what() << std::endl;
  return 1;
}
