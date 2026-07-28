#include "windows_helper_diagnostics.h"

#include <array>
#include <stdexcept>

namespace desktop_updater::helper {
namespace {

constexpr wchar_t kWindowsHelperEventSource[] =
    L"DesktopUpdater.InstallHelper.ProtocolV1";

constexpr std::array<WindowsHelperEventDescriptor,
                     static_cast<std::size_t>(WindowsHelperEvent::kCount)>
    kWindowsHelperEvents = {{
        {1000, EVENTLOG_INFORMATION_TYPE, "helper scheduled",
         L"helper scheduled"},
        {1001, EVENTLOG_INFORMATION_TYPE, "waiting for parent process",
         L"waiting for parent process"},
        {1002, EVENTLOG_INFORMATION_TYPE, "parent process exited",
         L"parent process exited"},
        {1003, EVENTLOG_INFORMATION_TYPE, "staging path validation",
         L"staging path validation"},
        {1004, EVENTLOG_INFORMATION_TYPE, "backup start", L"backup start"},
        {1005, EVENTLOG_INFORMATION_TYPE, "backup success",
         L"backup success"},
        {1006, EVENTLOG_ERROR_TYPE, "backup failure", L"backup failure"},
        {1007, EVENTLOG_INFORMATION_TYPE, "move start", L"move start"},
        {1008, EVENTLOG_INFORMATION_TYPE, "move success", L"move success"},
        {1009, EVENTLOG_ERROR_TYPE, "move failure", L"move failure"},
        {1010, EVENTLOG_INFORMATION_TYPE, "rollback start",
         L"rollback start"},
        {1011, EVENTLOG_INFORMATION_TYPE, "rollback success",
         L"rollback success"},
        {1012, EVENTLOG_ERROR_TYPE, "rollback failure",
         L"rollback failure"},
        {1013, EVENTLOG_INFORMATION_TYPE, "cleanup start", L"cleanup start"},
        {1014, EVENTLOG_INFORMATION_TYPE, "cleanup success",
         L"cleanup success"},
        {1015, EVENTLOG_ERROR_TYPE, "cleanup failure", L"cleanup failure"},
        {1016, EVENTLOG_INFORMATION_TYPE, "relaunch attempt",
         L"relaunch attempt"},
        {1017, EVENTLOG_ERROR_TYPE, "portable bootstrap failure",
         L"portable bootstrap failure"},
        {1018, EVENTLOG_ERROR_TYPE, "portable recovery host failure",
         L"portable recovery host failure"},
        {1019, EVENTLOG_ERROR_TYPE, "portable session failure",
         L"portable session failure"},
        {1020, EVENTLOG_ERROR_TYPE, "portable recovery authority failure",
         L"portable recovery authority failure"},
        {1021, EVENTLOG_ERROR_TYPE, "portable recovery source failure",
         L"portable recovery source failure"},
        {1022, EVENTLOG_ERROR_TYPE, "portable recovery storage failure",
         L"portable recovery storage failure"},
        {1023, EVENTLOG_ERROR_TYPE, "portable recovery artifact failure",
         L"portable recovery artifact failure"},
        {1024, EVENTLOG_ERROR_TYPE, "portable authorization failure",
         L"portable authorization failure"},
        {1025, EVENTLOG_ERROR_TYPE, "portable preparation failure",
         L"portable preparation failure"},
        {1026, EVENTLOG_ERROR_TYPE, "portable request validation failure",
         L"portable request validation failure"},
        {1027, EVENTLOG_ERROR_TYPE, "portable caller identity failure",
         L"portable caller identity failure"},
        {1028, EVENTLOG_ERROR_TYPE, "portable target authority failure",
         L"portable target authority failure"},
        {1029, EVENTLOG_ERROR_TYPE, "portable stage authorization failure",
         L"portable stage authorization failure"},
        {1030, EVENTLOG_ERROR_TYPE, "portable target request failure",
         L"portable target request failure"},
        {1031, EVENTLOG_ERROR_TYPE,
         "portable target executable identity failure",
         L"portable target executable identity failure"},
        {1032, EVENTLOG_ERROR_TYPE, "portable target caller root failure",
         L"portable target caller root failure"},
        {1033, EVENTLOG_ERROR_TYPE, "portable target read authority failure",
         L"portable target read authority failure"},
        {1034, EVENTLOG_ERROR_TYPE,
         "portable parent mutation authority failure",
         L"portable parent mutation authority failure"},
        {1035, EVENTLOG_ERROR_TYPE, "portable target marker failure",
         L"portable target marker failure"},
        {1036, EVENTLOG_ERROR_TYPE, "portable directory handle failure",
         L"portable directory handle failure"},
        {1037, EVENTLOG_ERROR_TYPE, "portable security descriptor failure",
         L"portable security descriptor failure"},
        {1038, EVENTLOG_ERROR_TYPE, "portable caller token failure",
         L"portable caller token failure"},
        {1039, EVENTLOG_ERROR_TYPE, "portable impersonation token failure",
         L"portable impersonation token failure"},
        {1040, EVENTLOG_ERROR_TYPE, "portable access check failure",
         L"portable access check failure"},
        {1041, EVENTLOG_ERROR_TYPE, "portable directory access denied",
         L"portable directory access denied"},
    }};

}  // namespace

const WindowsHelperEventDescriptor& DescribeWindowsHelperEvent(
    WindowsHelperEvent event) {
  const std::size_t index = static_cast<std::size_t>(event);
  if (index >= kWindowsHelperEvents.size()) {
    throw std::out_of_range("Windows helper event is invalid");
  }
  return kWindowsHelperEvents[index];
}

void RecordWindowsHelperEvent(WindowsHelperEvent event) noexcept {
  try {
    const WindowsHelperEventDescriptor& descriptor =
        DescribeWindowsHelperEvent(event);
    HANDLE source = RegisterEventSourceW(nullptr, kWindowsHelperEventSource);
    if (source == nullptr) return;
    const wchar_t* messages[] = {descriptor.event_message};
    (void)ReportEventW(source, descriptor.event_type, 0, descriptor.event_id,
                       nullptr, 1, 0, messages, nullptr);
    (void)DeregisterEventSource(source);
  } catch (...) {
    // Diagnostics are support evidence, never transaction authority.
  }
}

}  // namespace desktop_updater::helper
