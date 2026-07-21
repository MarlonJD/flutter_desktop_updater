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
