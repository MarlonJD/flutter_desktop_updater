#include <flutter_linux/flutter_linux.h>

#include <string>
#include <vector>

#include "include/desktop_updater/desktop_updater_plugin.h"

// This file exposes some plugin internals for unit testing. See
// https://github.com/flutter/flutter/issues/88724 for current limitations
// in the unit-testable API.

// Handles the getPlatformVersion method call.
FlMethodResponse *get_platform_version();

// Schedules an absolute-path update helper for tests and plugin calls.
bool schedule_install_update(const std::string &staging_path,
                             const std::vector<std::string> &removed_files,
                             const std::string &diagnostics_log_path,
                             std::string *error);
