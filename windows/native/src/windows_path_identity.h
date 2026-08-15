#pragma once

#include <cwchar>
#include <filesystem>
#include <string>

namespace desktop_updater::native::windows_path_identity {

inline std::wstring ExtendedLengthPath(const std::filesystem::path& path) {
  const std::wstring value = path.wstring();
  if (value.rfind(L"\\\\?\\", 0) == 0) return value;
  if (value.rfind(L"\\\\", 0) == 0) {
    return std::wstring(L"\\\\?\\UNC\\") + value.substr(2);
  }
  if (value.size() >= 2 && value[1] == L':') {
    return std::wstring(L"\\\\?\\") + value;
  }
  return value;
}

inline std::wstring NormalizedPath(const std::filesystem::path& path) {
  std::wstring value = path.lexically_normal().wstring();
  if (value.rfind(L"\\\\?\\", 0) == 0) {
    value.erase(0, 4);
  }
  while (!value.empty() && (value.back() == L'\\' || value.back() == L'/')) {
    value.pop_back();
  }
  return value;
}

inline bool PathEquals(const std::filesystem::path& first,
                       const std::filesystem::path& second) {
  const std::wstring first_value = NormalizedPath(first);
  const std::wstring second_value = NormalizedPath(second);
  return !first_value.empty() && !second_value.empty() &&
         _wcsicmp(first_value.c_str(), second_value.c_str()) == 0;
}

}  // namespace desktop_updater::native::windows_path_identity
