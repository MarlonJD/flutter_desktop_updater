#include <flutter_linux/flutter_linux.h>
#include <gmock/gmock.h>
#include <gtest/gtest.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdlib>
#include <string>

#include "include/desktop_updater/desktop_updater_plugin.h"
#include "desktop_updater_plugin_private.h"
#include "desktop_updater_native.h"

// This demonstrates a simple unit test of the C portion of this plugin's
// implementation.
//
// Once you have built the plugin's example app, you can run these tests
// from the command line. For instance, for a plugin called my_plugin
// built for x64 debug, run:
// $ build/linux/x64/debug/plugins/my_plugin/my_plugin_test

namespace desktop_updater {
namespace test {

using native::InstallRequest;
using native::LinuxInstallOperation;

TEST(DesktopUpdaterPlugin, GetPlatformVersion) {
  g_autoptr(FlMethodResponse) response = get_platform_version();
  ASSERT_NE(response, nullptr);
  ASSERT_TRUE(FL_IS_METHOD_SUCCESS_RESPONSE(response));
  FlValue* result = fl_method_success_response_get_result(
      FL_METHOD_SUCCESS_RESPONSE(response));
  ASSERT_EQ(fl_value_get_type(result), FL_VALUE_TYPE_STRING);
  // The full string varies, so just validate that it has the right format.
  EXPECT_THAT(fl_value_get_string(result), testing::StartsWith("Linux "));
}

TEST(DesktopUpdaterPlugin, InstallUpdateRequiresExistingStagingDirectory) {
  InstallRequest request = {
      LinuxInstallOperation::kInstall,
      "/tmp/desktop_updater_missing_staging",
      "",
      "",
      "com.example.app",
      {},
      "",
  };
  const auto result = native::ScheduleInstallAndRelaunch(request);
  EXPECT_FALSE(result.ok);
  EXPECT_THAT(result.error, testing::HasSubstr("Staged update directory"));
}

TEST(LinuxInstallTarget, RejectsUsrBinExecutableParent) {
  const auto result = native::ValidateInstallRequest({
      LinuxInstallOperation::kInstall,
      "/tmp/staging",
      "/usr/bin",
      "my-app",
      "com.example.app",
      {},
      "",
  });
  EXPECT_FALSE(result.ok);
}

TEST(LinuxInstallTarget, AcceptsSelfContainedBundle) {
  char* current_directory = getcwd(nullptr, 0);
  ASSERT_NE(current_directory, nullptr);
  const std::string install_root =
      std::string(current_directory) + "/desktop_updater_install_" +
      std::to_string(getpid());
  free(current_directory);
  rmdir(install_root.c_str());
  ASSERT_EQ(mkdir(install_root.c_str(), 0700), 0);

  char staging_template[] = "/tmp/desktop_updater_staging_XXXXXX";
  char* staging_root = mkdtemp(staging_template);
  ASSERT_NE(staging_root, nullptr);
  const auto result = native::ValidateInstallRequest({
      LinuxInstallOperation::kInstall,
      staging_root,
      install_root,
      "bin/my-app",
      "com.example.app",
      {},
      "",
  });
  EXPECT_TRUE(result.ok) << result.error;
  rmdir(staging_root);
  rmdir(install_root.c_str());
}

TEST(LinuxInstallTarget, RejectsEveryProtectedRoot) {
  for (const auto* root : {"/", "/bin", "/sbin", "/usr", "/usr/bin",
                           "/usr/sbin", "/usr/local", "/usr/local/bin",
                           "/opt", "/etc", "/var", "/home"}) {
    const auto result = native::ValidateInstallRequest({
        LinuxInstallOperation::kInstall,
        "/tmp/staging",
        root,
        "bin/my-app",
        "com.example.app",
        {},
        "",
    });
    EXPECT_FALSE(result.ok) << root;
  }
}

TEST(LinuxInstallTarget, RestartDoesNotRequirePackageIdentity) {
  const auto result = native::ValidateInstallRequest({
      LinuxInstallOperation::kRestart,
      "",
      "/opt/example-app",
      "bin/my-app",
      "",
      {},
      "",
  });
  EXPECT_TRUE(result.ok) << result.error;
}

TEST(LinuxInstallTarget, InstallRejectsBlankPackageIdentity) {
  const auto result = native::ValidateInstallRequest({
      LinuxInstallOperation::kInstall,
      "/tmp/staging",
      "/opt/example-app",
      "bin/my-app",
      "   ",
      {},
      "",
  });
  EXPECT_FALSE(result.ok);
}

TEST(LinuxInstallTarget, RejectsNonCanonicalRootAndExecutableTraversal) {
  EXPECT_FALSE(native::ValidateInstallRequest({
      LinuxInstallOperation::kInstall,
      "/tmp/staging",
      "/opt/../usr/bin",
      "my-app",
      "com.example.app",
      {},
      "",
  }).ok);
  EXPECT_FALSE(native::ValidateInstallRequest({
      LinuxInstallOperation::kInstall,
      "/tmp/staging",
      "/opt/example-app",
      "bin/../my-app",
      "com.example.app",
      {},
      "",
  }).ok);
}

TEST(LinuxInstallTarget, RejectsSymlinkedInstallRoot) {
  char root_template[] = "/tmp/desktop_updater_target_XXXXXX";
  char* real_root = mkdtemp(root_template);
  ASSERT_NE(real_root, nullptr);
  const std::string link_path = std::string(real_root) + "-link";
  ASSERT_EQ(symlink(real_root, link_path.c_str()), 0);

  const auto result = native::ValidateInstallRequest({
      LinuxInstallOperation::kInstall,
      "/tmp/staging",
      link_path,
      "my-app",
      "com.example.app",
      {},
      "",
  });

  EXPECT_FALSE(result.ok);
  unlink(link_path.c_str());
  rmdir(real_root);
}

TEST(LinuxInstallTarget, ValidationFailureCreatesNoHelperScript) {
  const std::string script_path =
      "/tmp/desktop_updater_" + std::to_string(getpid()) + ".sh";
  unlink(script_path.c_str());

  const auto result = native::ScheduleInstallAndRelaunch({
      LinuxInstallOperation::kInstall,
      "/tmp",
      "/usr/bin",
      "my-app",
      "com.example.app",
      {},
      "",
  });
  EXPECT_FALSE(result.ok);
  EXPECT_NE(result.error.find("protected"), std::string::npos);
  EXPECT_NE(access(script_path.c_str(), F_OK), 0);
}

TEST(LinuxInstallTarget, RemovedTraversalCreatesNoHelperScript) {
  const std::string script_path =
      "/tmp/desktop_updater_" + std::to_string(getpid()) + ".sh";
  unlink(script_path.c_str());

  const auto result = native::ScheduleInstallAndRelaunch({
      LinuxInstallOperation::kInstall,
      "/tmp",
      "",
      "",
      "com.example.app",
      {"../escape"},
      "",
  });
  EXPECT_FALSE(result.ok);
  EXPECT_NE(result.error.find("Removed file path"), std::string::npos);
  EXPECT_NE(access(script_path.c_str(), F_OK), 0);
}

}  // namespace test
}  // namespace desktop_updater
