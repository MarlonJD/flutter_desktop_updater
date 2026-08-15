#include <gtest/gtest.h>

#include <windows.h>

#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "windows_protected_helper_locator.h"

namespace desktop_updater::helper {
namespace {

ProtectedWindowsHelperEndpointV1 Endpoint() {
  return {ProtectedWindowsHelperEndpointV1::kSchemaVersion,
          "com.example.desktop-updater.privileged",
          "com.example.app",
          "com.example.desktop-updater.helper",
          std::filesystem::path(
              L"C:\\Program Files\\Common Files\\DesktopUpdater\\Example\\1"
              L"\\desktop_updater_install_helper.exe"),
          std::filesystem::path(
              L"C:\\Program Files\\Common Files\\DesktopUpdater\\Example\\1"
              L"\\desktop_updater_helper_policy.json"),
          std::string(64, 'a'),
          std::string(64, 'b')};
}

constexpr char kTransactionId[] =
    "00000000-0000-4000-8000-000000000025";
constexpr wchar_t kRecordValueName[] = L"Record";
constexpr wchar_t kFreshReaderEnvironment[] =
    L"DESKTOP_UPDATER_FRESH_PROTECTED_LOCATOR_REGISTRY_ROOT";

bool IsProcessElevatedForProtectedAclTest() {
  HANDLE raw_token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &raw_token)) {
    return false;
  }
  TOKEN_ELEVATION elevation{};
  DWORD received = 0;
  const BOOL queried = GetTokenInformation(
      raw_token, TokenElevation, &elevation, sizeof(elevation), &received);
  CloseHandle(raw_token);
  return queried && received == sizeof(elevation) && elevation.TokenIsElevated;
}

std::string ReadFile(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) throw std::runtime_error("could not read frozen fixture");
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

std::string FrozenEndpointBytes() {
  return ReadFile(std::filesystem::path(
      DESKTOP_UPDATER_DURABLE_STATE_FIXTURE_DIRECTORY) /
                  "protected-helper-endpoint-schema1.json");
}

class RegistrySandbox {
 public:
  RegistrySandbox()
      : path_(L"Software\\DesktopUpdaterTask1Fixture\\" +
              std::to_wstring(GetCurrentProcessId()) + L"-" +
              std::to_wstring(GetTickCount64())) {
    HKEY key = nullptr;
    const LSTATUS status = RegCreateKeyExW(
        HKEY_CURRENT_USER, path_.c_str(), 0, nullptr, REG_OPTION_NON_VOLATILE,
        KEY_ALL_ACCESS, nullptr, &key, nullptr);
    if (status != ERROR_SUCCESS || key == nullptr) {
      throw std::runtime_error("could not create test registry sandbox");
    }
    RegCloseKey(key);
  }

  ~RegistrySandbox() { (void)RegDeleteTreeW(HKEY_CURRENT_USER, path_.c_str()); }

  const std::wstring& path() const { return path_; }

 private:
  std::wstring path_;
};

class ScopedLocalMachineOverride {
 public:
  explicit ScopedLocalMachineOverride(const std::wstring& path) {
    HKEY key = nullptr;
    const LSTATUS opened = RegOpenKeyExW(HKEY_CURRENT_USER, path.c_str(), 0,
                                         KEY_ALL_ACCESS, &key);
    if (opened != ERROR_SUCCESS || key == nullptr) {
      throw std::runtime_error("could not open test registry sandbox");
    }
    if (RegOverridePredefKey(HKEY_LOCAL_MACHINE, key) != ERROR_SUCCESS) {
      RegCloseKey(key);
      throw std::runtime_error("could not override local-machine registry");
    }
    key_ = key;
  }

  ~ScopedLocalMachineOverride() {
    (void)RegOverridePredefKey(HKEY_LOCAL_MACHINE, nullptr);
    if (key_ != nullptr) RegCloseKey(key_);
  }

  ScopedLocalMachineOverride(const ScopedLocalMachineOverride&) = delete;
  ScopedLocalMachineOverride& operator=(const ScopedLocalMachineOverride&) =
      delete;

 private:
  HKEY key_ = nullptr;
};

class ScopedEnvironmentVariable {
 public:
  explicit ScopedEnvironmentVariable(std::wstring name) : name_(std::move(name)) {
    const DWORD required = GetEnvironmentVariableW(name_.c_str(), nullptr, 0);
    if (required == 0) return;
    previous_.resize(required);
    const DWORD copied =
        GetEnvironmentVariableW(name_.c_str(), previous_.data(), required);
    if (copied == 0 || copied >= required) {
      throw std::runtime_error("could not read process environment");
    }
    previous_.resize(copied);
    had_value_ = true;
  }

  ~ScopedEnvironmentVariable() {
    (void)SetEnvironmentVariableW(name_.c_str(),
                                  had_value_ ? previous_.c_str() : nullptr);
  }

  void Set(const std::wstring& value) {
    if (!SetEnvironmentVariableW(name_.c_str(), value.c_str())) {
      throw std::runtime_error("could not set process environment");
    }
  }

 private:
  std::wstring name_;
  std::wstring previous_;
  bool had_value_ = false;
};

std::filesystem::path TestExecutable() {
  std::vector<wchar_t> buffer(32'768);
  const DWORD length = GetModuleFileNameW(nullptr, buffer.data(),
                                          static_cast<DWORD>(buffer.size()));
  if (length == 0 || length >= buffer.size()) {
    throw std::runtime_error("fresh locator test executable is unavailable");
  }
  return std::filesystem::path(std::wstring(buffer.data(), length));
}

int RunFreshLocatorReader(const std::wstring& registry_root) {
  ScopedEnvironmentVariable worker_environment(kFreshReaderEnvironment);
  worker_environment.Set(registry_root);
  const std::filesystem::path executable = TestExecutable();
  std::wstring command_line =
      L"\"" + executable.wstring() + L"\" --gtest_filter=" +
      L"WindowsProtectedHelperLocator.FreshProcessReadsFrozenEndpoint";
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(executable.c_str(), command_line.data(), nullptr,
                      nullptr, FALSE, CREATE_UNICODE_ENVIRONMENT, nullptr,
                      executable.parent_path().c_str(), &startup, &process)) {
    return -1;
  }
  CloseHandle(process.hThread);
  if (WaitForSingleObject(process.hProcess, 30'000) != WAIT_OBJECT_0) {
    (void)TerminateProcess(process.hProcess, 124);
    (void)WaitForSingleObject(process.hProcess, 5'000);
    CloseHandle(process.hProcess);
    return -1;
  }
  DWORD exit_code = 0;
  const BOOL has_exit_code = GetExitCodeProcess(process.hProcess, &exit_code);
  CloseHandle(process.hProcess);
  return has_exit_code ? static_cast<int>(exit_code) : -1;
}

void WriteRawRegistryRecord(const std::wstring& key_path,
                            const std::string& bytes) {
  HKEY key = nullptr;
  const LSTATUS opened = RegOpenKeyExW(
      HKEY_LOCAL_MACHINE, key_path.c_str(), 0,
      KEY_QUERY_VALUE | KEY_SET_VALUE | READ_CONTROL | KEY_WOW64_64KEY, &key);
  if (opened != ERROR_SUCCESS || key == nullptr) {
    throw std::runtime_error("could not open protected locator record");
  }
  const LSTATUS written = RegSetValueExW(
      key, kRecordValueName, 0, REG_BINARY,
      reinterpret_cast<const BYTE*>(bytes.data()), static_cast<DWORD>(bytes.size()));
  const LSTATUS flushed = written == ERROR_SUCCESS ? RegFlushKey(key) : written;
  RegCloseKey(key);
  if (flushed != ERROR_SUCCESS) {
    throw std::runtime_error("could not write frozen protected locator");
  }
}

std::string ReadRawRegistryRecord(const std::wstring& key_path) {
  HKEY key = nullptr;
  const LSTATUS opened = RegOpenKeyExW(
      HKEY_LOCAL_MACHINE, key_path.c_str(), 0,
      KEY_QUERY_VALUE | READ_CONTROL | KEY_WOW64_64KEY, &key);
  if (opened != ERROR_SUCCESS || key == nullptr) {
    throw std::runtime_error("could not open frozen protected locator");
  }
  DWORD type = 0;
  DWORD size = 0;
  LSTATUS status = RegQueryValueExW(key, kRecordValueName, nullptr, &type,
                                    nullptr, &size);
  if (status != ERROR_SUCCESS || type != REG_BINARY || size == 0) {
    RegCloseKey(key);
    throw std::runtime_error("frozen protected locator is unavailable");
  }
  std::string bytes(size, '\0');
  status = RegQueryValueExW(key, kRecordValueName, nullptr, &type,
                            reinterpret_cast<BYTE*>(bytes.data()), &size);
  RegCloseKey(key);
  if (status != ERROR_SUCCESS || type != REG_BINARY) {
    throw std::runtime_error("could not read frozen protected locator");
  }
  return bytes;
}

TEST(WindowsProtectedHelperLocator, CanonicalEndpointRoundTrips) {
  const auto endpoint = Endpoint();
  const std::string encoded = endpoint.EncodeCanonical();
  EXPECT_EQ(endpoint,
            ProtectedWindowsHelperEndpointV1::DecodeStrict(encoded));
  EXPECT_EQ('{', encoded.front());
  EXPECT_EQ('}', encoded.back());
}

TEST(WindowsProtectedHelperLocator, RejectsMutableOrAmbiguousBindings) {
  auto endpoint = Endpoint();
  endpoint.policy_path = L"C:\\Users\\caller\\policy.json";
  EXPECT_THROW(endpoint.EncodeCanonical(),
               WindowsProtectedHelperLocatorError);

  endpoint = Endpoint();
  endpoint.helper_sha256 = std::string(64, 'A');
  EXPECT_THROW(endpoint.EncodeCanonical(),
               WindowsProtectedHelperLocatorError);

  EXPECT_THROW(
      ProtectedWindowsTransactionEndpointRegistryPath("not-a-uuid"),
      WindowsProtectedHelperLocatorError);
}

TEST(WindowsProtectedHelperLocator, RegistryNamesAreExactAndNonEnumerable) {
  const auto first = Endpoint();
  auto second = first;
  second.helper_path =
      L"C:\\Program Files\\Common Files\\DesktopUpdater\\Example\\2"
      L"\\desktop_updater_install_helper.exe";
  second.policy_path =
      L"C:\\Program Files\\Common Files\\DesktopUpdater\\Example\\2"
      L"\\desktop_updater_helper_policy.json";
  second.helper_sha256 = std::string(64, 'c');
  second.policy_sha256 = std::string(64, 'd');
  const std::wstring package =
      ProtectedWindowsEndpointPackageRegistryPath("com.example.app");
  const std::wstring endpoint = ProtectedWindowsEndpointRegistryPath(
      "com.example.app", first.helper_path);
  const std::wstring second_endpoint = ProtectedWindowsEndpointRegistryPath(
      "com.example.app", second.helper_path);
  const std::wstring transaction =
      ProtectedWindowsTransactionEndpointRegistryPath(
          "00000000-0000-4000-8000-000000000025");
  EXPECT_EQ(64U, package.substr(package.find_last_of(L'\\') + 1).size());
  EXPECT_EQ(package + L"\\", endpoint.substr(0, package.size() + 1));
  EXPECT_EQ(64U, endpoint.substr(endpoint.find_last_of(L'\\') + 1).size());
  EXPECT_NE(endpoint, second_endpoint);
  EXPECT_NE(std::wstring::npos, transaction.find(L"TransactionEndpoints"));
  EXPECT_EQ(std::wstring::npos, transaction.find(L"*"));

  const std::wstring sddl = BuildProtectedWindowsRegistrySddl();
  EXPECT_NE(std::wstring::npos, sddl.find(L"(A;;KA;;;SY)"));
  EXPECT_NE(std::wstring::npos, sddl.find(L"(A;;KA;;;BA)"));
  EXPECT_NE(std::wstring::npos, sddl.find(L"(A;;KR;;;AU)"));
  EXPECT_EQ(std::wstring::npos, sddl.find(L";;;WD"));
}

TEST(WindowsProtectedHelperLocator, FreshProcessReadsFrozenEndpoint) {
  const DWORD required =
      GetEnvironmentVariableW(kFreshReaderEnvironment, nullptr, 0);
  if (required == 0) {
    GTEST_SKIP() << "run only by the protected-locator orchestrator";
  }
  std::wstring registry_root(required, L'\0');
  const DWORD copied = GetEnvironmentVariableW(
      kFreshReaderEnvironment, registry_root.data(), required);
  ASSERT_GT(copied, 0U);
  ASSERT_LT(copied, required);
  registry_root.resize(copied);
  ScopedLocalMachineOverride override(registry_root);

  const std::string frozen = FrozenEndpointBytes();
  const auto expected = ProtectedWindowsHelperEndpointV1::DecodeStrict(frozen);
  const auto endpoint =
      LoadProtectedWindowsHelperEndpoint(expected.package_id, expected.helper_path);
  const auto transaction = LoadProtectedWindowsTransactionEndpoint(kTransactionId);
  ASSERT_TRUE(endpoint.has_value());
  ASSERT_TRUE(transaction.has_value());
  EXPECT_EQ(expected, *endpoint);
  EXPECT_EQ(expected, *transaction);
}

TEST(WindowsProtectedHelperLocator,
     FrozenEndpointAuthenticatesAndLoadsInFreshProcessWithoutRewrite) {
  if (!IsProcessElevatedForProtectedAclTest()) {
    GTEST_SKIP() << "production Administrators-owned registry ACL requires "
                    "an elevated token";
  }
  RegistrySandbox sandbox;
  ScopedLocalMachineOverride override(sandbox.path());
  const std::string frozen = FrozenEndpointBytes();
  const auto endpoint = ProtectedWindowsHelperEndpointV1::DecodeStrict(frozen);
  const std::wstring endpoint_path = ProtectedWindowsEndpointRegistryPath(
      endpoint.package_id, endpoint.helper_path);
  const std::wstring transaction_path =
      ProtectedWindowsTransactionEndpointRegistryPath(kTransactionId);

  // The registrar creates the production ACL. The test then installs the
  // immutable fixture bytes directly so the reader never depends on a v3
  // encoder before it authenticates the locator in the separate process.
  ASSERT_NO_THROW(RegisterProtectedWindowsHelperEndpoint(endpoint));
  ASSERT_NO_THROW(BindProtectedWindowsTransactionEndpoint(kTransactionId,
                                                          endpoint));
  ASSERT_NO_THROW(WriteRawRegistryRecord(endpoint_path, frozen));
  ASSERT_NO_THROW(WriteRawRegistryRecord(transaction_path, frozen));
  ASSERT_EQ(frozen, ReadRawRegistryRecord(endpoint_path));
  ASSERT_EQ(frozen, ReadRawRegistryRecord(transaction_path));

  ASSERT_EQ(0, RunFreshLocatorReader(sandbox.path()));
  EXPECT_EQ(frozen, ReadRawRegistryRecord(endpoint_path));
  EXPECT_EQ(frozen, ReadRawRegistryRecord(transaction_path));
}

}  // namespace
}  // namespace desktop_updater::helper
