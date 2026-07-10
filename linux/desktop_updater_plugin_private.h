#include <flutter_linux/flutter_linux.h>

#include "include/desktop_updater/desktop_updater_plugin.h"

// This file exposes the Flutter adapter surface used by the plugin test.
// The updater implementation is tested independently in linux/native.

FlMethodResponse* get_platform_version();
