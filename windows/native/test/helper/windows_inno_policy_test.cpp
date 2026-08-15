#include <gtest/gtest.h>

#include <string>

#include "json_value.h"
#include "windows_inno_policy.h"

namespace desktop_updater::helper {
namespace {

class RecordingVerifier final : public ProtectedWindowsInnoVerifier {
 public:
  void VerifyInstaller(
      const ProtectedWindowsInnoExpectation& expectation) override {
    installer = expectation.installer_path;
  }
  void VerifyInstalledPackage(
      const ProtectedWindowsInnoExpectation& expectation) override {
    installed = expectation.install_root /
                expectation.execution.installed_executable_relative_path;
  }

  std::filesystem::path installer;
  std::filesystem::path installed;
};

class RecordingRunner final : public ProtectedWindowsInnoRunner {
 public:
  std::string Launch(
      const ProtectedWindowsInnoExpectation& expectation) override {
    installer = expectation.installer_path;
    return "inno-process:42";
  }

  std::filesystem::path installer;
};

desktop_updater::runtime::internal::ReleaseDescriptor Descriptor(
    const std::string& elevation = "always",
    bool authenticode_required = true,
    const std::string& arguments =
        "[\"/VERYSILENT\",\"/SUPPRESSMSGBOXES\",\"/NORESTART\"]") {
  using desktop_updater::runtime::internal::ParseJson;
  desktop_updater::runtime::internal::ReleaseDescriptor descriptor;
  descriptor.platform = "windows";
  descriptor.artifact.kind = "innoInstaller";
  descriptor.install = ParseJson(
      "{\"inno\":{\"authenticode\":{\"required\":" +
      std::string(authenticode_required ? "true" : "false") +
      ",\"sha256Thumbprints\":[\"" + std::string(64, 'A') +
      "\"]},\"inheritInstallDirectory\":true,\"logFileName\":"
      "\"desktop-updater-inno.log\",\"installedExecutableRelativePath\":"
      "\"bin\\\\example.exe\",\"installedExecutableSha256\":\"" +
      std::string(64, 'c') +
      "\",\"relaunchAfterInstall\":false,"
      "\"requiresElevation\":\"" + elevation +
      "\",\"silentArgs\":" + arguments +
      "},\"strategy\":\"innoInstaller\"}");
  return descriptor;
}

TEST(WindowsInnoPolicy, AcceptsOnlySignedFixedProtectedExecution) {
  const ProtectedWindowsInnoExecutionPolicy policy =
      ParseProtectedWindowsInnoExecutionPolicy(Descriptor());
  ASSERT_EQ(1U, policy.signer_certificate_sha256.size());
  EXPECT_EQ(std::string(64, 'a'), policy.signer_certificate_sha256.front());
  EXPECT_EQ(std::filesystem::path(L"bin\\example.exe"),
            policy.installed_executable_relative_path);
  EXPECT_EQ(std::string(64, 'c'), policy.installed_executable_sha256);
  EXPECT_FALSE(policy.relaunch_after_install);

  const auto arguments = BuildProtectedWindowsInnoArguments(
      policy, L"C:\\Program Files\\Example", L"C:\\Windows\\Temp");
  ASSERT_EQ(5U, arguments.size());
  EXPECT_EQ(L"/DIR=C:\\Program Files\\Example", arguments[3]);
  EXPECT_EQ(L"/LOG=C:\\Windows\\Temp\\desktop-updater-inno.log",
            arguments[4]);
}

TEST(WindowsInnoPolicy, RejectsUnsignedPortableAndArgumentDrift) {
  EXPECT_THROW(ParseProtectedWindowsInnoExecutionPolicy(Descriptor("never")),
               WindowsInnoPolicyError);
  EXPECT_THROW(
      ParseProtectedWindowsInnoExecutionPolicy(Descriptor("always", false)),
      WindowsInnoPolicyError);
  EXPECT_THROW(ParseProtectedWindowsInnoExecutionPolicy(Descriptor(
                   "always", true,
                   "[\"/VERYSILENT\",\"/NORESTART\","
                   "\"/LOADINF=attacker.ini\"]")),
               WindowsInnoPolicyError);
  EXPECT_THROW(ParseProtectedWindowsInnoExecutionPolicy(Descriptor(
                   "always", true, "[\"/VERYSILENT\"]")),
               WindowsInnoPolicyError);
}

TEST(WindowsInnoPolicy, HandoffIsStructuredAndPostVerified) {
  ProtectedWindowsInnoExpectation expectation;
  expectation.installer_path = L"C:\\ProgramData\\DesktopUpdater\\setup.exe";
  expectation.installer_sha256 = std::string(64, 'b');
  expectation.package_id = "com.example.app";
  expectation.expected_version = "3.1.3";
  expectation.expected_build_number = 313;
  expectation.install_root = L"C:\\Program Files\\Example";
  expectation.log_root = L"C:\\Windows\\Temp";
  expectation.execution =
      ParseProtectedWindowsInnoExecutionPolicy(Descriptor());
  RecordingVerifier verifier;
  RecordingRunner runner;

  const auto result =
      ExecuteProtectedWindowsInnoHandoff(expectation, verifier, runner);

  EXPECT_TRUE(result.completed);
  EXPECT_EQ("inno-process:42", result.provider_transaction_identity);
  EXPECT_EQ(expectation.installer_path, verifier.installer);
  EXPECT_EQ(expectation.installer_path, runner.installer);
  EXPECT_EQ(expectation.install_root /
                expectation.execution.installed_executable_relative_path,
            verifier.installed);
}

}  // namespace
}  // namespace desktop_updater::helper
