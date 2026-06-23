#include "child_hwnd_probe.h"

#include <commctrl.h>

#include <algorithm>
#include <cstdint>
#include <filesystem>
#include <iomanip>
#include <ios>
#include <sstream>

namespace {

constexpr int kProbeChildId = 19001;
constexpr int kProbeMargin = 24;
constexpr int kProbeHeight = 32;
constexpr int kProbeMinimumWidth = 120;
constexpr int kProbeMaximumWidth = 360;

std::wstring HwndToString(HWND hwnd) {
  std::wstringstream stream;
  stream << L"0x" << std::hex << reinterpret_cast<std::uintptr_t>(hwnd);
  return stream.str();
}

std::wstring RectToString(const RECT& rect) {
  std::wstringstream stream;
  stream << L"[" << rect.left << L"," << rect.top << L"," << rect.right
         << L"," << rect.bottom << L"]";
  return stream.str();
}

std::wstring KeyToString(WPARAM key) {
  std::wstringstream stream;
  stream << key;
  return stream.str();
}

}  // namespace

ChildHwndProbe::ChildHwndProbe() = default;

ChildHwndProbe::~ChildHwndProbe() {
  Destroy();
}

bool ChildHwndProbe::Create(HWND parent) {
  if (child_) {
    return true;
  }

  parent_ = parent;
  log_.open(std::filesystem::path(LogPath()), std::ios::out | std::ios::app);
  Log(L"probe-start parent=" + HwndToString(parent_));

  child_ = CreateWindowExW(
      WS_EX_CLIENTEDGE, L"EDIT", L"Win32 child HWND probe",
      WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_BORDER | ES_LEFT |
          ES_AUTOHSCROLL,
      kProbeMargin, kProbeMargin, kProbeMaximumWidth, kProbeHeight, parent_,
      reinterpret_cast<HMENU>(kProbeChildId), GetModuleHandle(nullptr),
      nullptr);

  if (!child_) {
    Log(L"create-failed error=" + std::to_wstring(GetLastError()));
    return false;
  }

  SetWindowSubclass(child_, ChildSubclassProc, 1,
                    reinterpret_cast<DWORD_PTR>(this));
  LogWindowEvent(L"create", child_);

  SetFocus(child_);
  LogWindowEvent(L"focus-request", child_);
  return true;
}

void ChildHwndProbe::Resize(const RECT& client_area) {
  if (!child_) {
    return;
  }

  const LONG client_width = client_area.right - client_area.left;
  const LONG available_width = client_width - (kProbeMargin * 2);
  const LONG width = std::max<LONG>(
      kProbeMinimumWidth, std::min<LONG>(kProbeMaximumWidth, available_width));

  SetWindowPos(child_, HWND_TOP, kProbeMargin, kProbeMargin, width,
               kProbeHeight, SWP_NOACTIVATE | SWP_SHOWWINDOW);

  RECT bounds = {};
  GetWindowRect(child_, &bounds);
  Log(L"resize child=" + HwndToString(child_) +
      L" client=" + RectToString(client_area) +
      L" screen_bounds=" + RectToString(bounds));
}

void ChildHwndProbe::Destroy() {
  if (child_) {
    const HWND child = child_;
    LogWindowEvent(L"dispose-start", child);
    DestroyWindow(child);
    child_ = nullptr;
    parent_ = nullptr;
    Log(L"dispose-complete");
  }

  if (log_.is_open()) {
    log_.close();
  }
}

LRESULT CALLBACK ChildHwndProbe::ChildSubclassProc(HWND hwnd,
                                                   UINT message,
                                                   WPARAM wparam,
                                                   LPARAM lparam,
                                                   UINT_PTR subclass_id,
                                                   DWORD_PTR ref_data) {
  auto* probe = reinterpret_cast<ChildHwndProbe*>(ref_data);
  if (probe) {
    switch (message) {
      case WM_SETFOCUS:
        probe->LogWindowEvent(L"child-focus", hwnd);
        break;
      case WM_KILLFOCUS:
        probe->LogWindowEvent(L"child-blur", hwnd);
        break;
      case WM_KEYDOWN:
        probe->LogWindowEvent(L"child-keydown key=" + KeyToString(wparam),
                              hwnd);
        break;
      case WM_DESTROY:
        probe->LogWindowEvent(L"child-destroy", hwnd);
        break;
      case WM_NCDESTROY:
        probe->LogWindowEvent(L"child-nc-destroy", hwnd);
        RemoveWindowSubclass(hwnd, ChildSubclassProc, subclass_id);
        break;
    }
  }

  return DefSubclassProc(hwnd, message, wparam, lparam);
}

void ChildHwndProbe::Log(const std::wstring& event) {
  std::wstringstream line;
  line << L"[tick=" << GetTickCount64() << L"] " << event << L"\n";

  const std::wstring message = line.str();
  OutputDebugStringW(message.c_str());

  if (log_.is_open()) {
    log_ << message;
    log_.flush();
  }
}

void ChildHwndProbe::LogWindowEvent(const std::wstring& event, HWND hwnd) {
  Log(event + L" hwnd=" + HwndToString(hwnd));
}

std::wstring ChildHwndProbe::LogPath() const {
  wchar_t temp_path[MAX_PATH] = {};
  const DWORD length = GetTempPathW(MAX_PATH, temp_path);

  std::wstring path =
      length > 0 && length < MAX_PATH ? std::wstring(temp_path) : L".\\";
  if (!path.empty() && path.back() != L'\\' && path.back() != L'/') {
    path.push_back(L'\\');
  }

  return path + L"flutter_child_hwnd_probe.log";
}
