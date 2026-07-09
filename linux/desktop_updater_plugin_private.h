#include <flutter_linux/flutter_linux.h>

#include <string>
#include <vector>

#include "include/desktop_updater/desktop_updater_plugin.h"

// This file exposes some plugin internals for unit testing. See
// https://github.com/flutter/flutter/issues/88724 for current limitations
// in the unit-testable API.

// Handles the getPlatformVersion method call.
FlMethodResponse *get_platform_version();

struct InstallResult
{
  bool ok;
  std::string error;
};

enum class LinuxInstallOperation
{
  kRestart,
  kInstall,
};

struct LinuxInstallTarget
{
  LinuxInstallOperation operation;
  std::string install_root;
  std::string executable_relative_path;
  std::string package_id;
};

// Validates that a Linux update target is an app-owned directory bundle.
InstallResult ValidateLinuxInstallTarget(const LinuxInstallTarget &target);

// Schedules a validated absolute-path update helper for tests and plugin calls.
bool schedule_install_update(LinuxInstallOperation operation,
                             const std::string &staging_path,
                             const std::vector<std::string> &removed_files,
                             const std::string &diagnostics_log_path,
                             const std::string &install_root,
                             const std::string &executable_relative_path,
                             const std::string &package_id,
                             std::string *error);
