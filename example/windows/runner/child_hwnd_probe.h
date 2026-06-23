#ifndef RUNNER_CHILD_HWND_PROBE_H_
#define RUNNER_CHILD_HWND_PROBE_H_

#include <windows.h>

#include <fstream>
#include <string>

// Opt-in evidence probe for a native child HWND hosted by the example runner.
// This is not a production API surface and is compiled only when explicitly
// enabled by CMake.
class ChildHwndProbe {
 public:
  ChildHwndProbe();
  ~ChildHwndProbe();

  bool Create(HWND parent);
  void Resize(const RECT& client_area);
  void Destroy();

 private:
  static LRESULT CALLBACK ChildSubclassProc(HWND hwnd,
                                            UINT message,
                                            WPARAM wparam,
                                            LPARAM lparam,
                                            UINT_PTR subclass_id,
                                            DWORD_PTR ref_data);

  void Log(const std::wstring& event);
  void LogWindowEvent(const std::wstring& event, HWND hwnd);
  std::wstring LogPath() const;

  HWND parent_ = nullptr;
  HWND child_ = nullptr;
  std::wofstream log_;
};

#endif  // RUNNER_CHILD_HWND_PROBE_H_
