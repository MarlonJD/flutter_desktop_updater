#include "desktop_updater_native.h"

int main() {
  const desktop_updater::native::InstallRequest request = {
      desktop_updater::native::LinuxInstallOperation::kInstall,
      "/tmp/desktop_updater_consumer_staging",
      "/usr/bin",
      "desktop-updater-consumer",
      "com.example.desktop-updater-consumer",
      {},
      "",
  };
  const auto result =
      desktop_updater::native::ValidateInstallRequest(request);
  if (result.ok || result.error.find("protected") == std::string::npos) {
    return 1;
  }
  return 0;
}
