#include <gtest/gtest.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>

#include "desktop_updater_native.h"
#include "desktop_updater_native_internal.h"

namespace desktop_updater {
namespace native {
namespace test {
namespace {

namespace fs = std::filesystem;

class TemporaryDirectory {
 public:
  TemporaryDirectory() {
    char path[] = "/tmp/desktop_updater_native_test_XXXXXX";
    char* created = mkdtemp(path);
    if (created == nullptr) {
      throw std::runtime_error("Unable to create native test directory");
    }
    path_ = created;
  }

  ~TemporaryDirectory() {
    std::error_code error;
    fs::remove_all(path_, error);
  }

  const fs::path& path() const { return path_; }

 private:
  fs::path path_;
};

void WriteFile(const fs::path& path,
               const std::string& contents,
               mode_t mode = 0644) {
  fs::create_directories(path.parent_path());
  std::ofstream file(path);
  file << contents;
  file.close();
  ASSERT_TRUE(file.good());
  ASSERT_EQ(chmod(path.c_str(), mode), 0);
}

std::string ReadFile(const fs::path& path) {
  std::ifstream file(path);
  return std::string(std::istreambuf_iterator<char>(file),
                     std::istreambuf_iterator<char>());
}

InstallRequest RequestFor(const fs::path& install_root,
                          const fs::path& staging_root) {
  return {
      LinuxInstallOperation::kInstall,
      staging_root.string(),
      install_root.string(),
      "bin/example",
      "com.example.app",
      {},
      "",
  };
}

TEST(LinuxNativeInstall, RejectsProtectedSharedRoots) {
  for (const char* root : {"/", "/bin", "/sbin", "/usr", "/usr/bin",
                           "/usr/sbin", "/usr/local", "/usr/local/bin",
                           "/opt", "/etc", "/var", "/home"}) {
    InstallRequest request = {
        LinuxInstallOperation::kInstall,
        "/tmp/staging",
        root,
        "bin/example",
        "com.example.app",
        {},
        "",
    };
    EXPECT_FALSE(ValidateInstallRequest(request).ok) << root;
  }
}

TEST(LinuxNativeInstall, RejectsNonCanonicalAndSymlinkEscapes) {
  TemporaryDirectory temporary;
  const fs::path install_root = temporary.path() / "app";
  const fs::path staging_root = temporary.path() / "staging";
  const fs::path outside = temporary.path() / "outside.txt";
  WriteFile(install_root / "bin/example", "old", 0755);
  WriteFile(staging_root / "bin/example", "new", 0755);
  WriteFile(outside, "outside");

  InstallRequest noncanonical = RequestFor(install_root, staging_root);
  noncanonical.install_root = (install_root / "../app").string();
  EXPECT_FALSE(ValidateInstallRequest(noncanonical).ok);

  InstallRequest executable_traversal = RequestFor(install_root, staging_root);
  executable_traversal.executable_relative_path = "bin/../outside";
  EXPECT_FALSE(ValidateInstallRequest(executable_traversal).ok);

  const fs::path link = install_root / "outside-link";
  ASSERT_EQ(symlink(outside.c_str(), link.c_str()), 0);
  InstallRequest symlink_escape = RequestFor(install_root, staging_root);
  symlink_escape.removed_files = {"outside-link"};
  EXPECT_FALSE(ValidateInstallRequest(symlink_escape).ok);

  InstallRequest executable_symlink = RequestFor(install_root, staging_root);
  executable_symlink.executable_relative_path = "outside-link";
  EXPECT_FALSE(ValidateInstallRequest(executable_symlink).ok);
}

TEST(LinuxNativeInstall, GeneratedScriptBoundsDestructiveCommands) {
  TemporaryDirectory temporary;
  const fs::path install_root = temporary.path() / "app";
  const fs::path staging_root = temporary.path() / "staging";
  const fs::path executable = install_root / "bin/example";
  WriteFile(executable, "old", 0755);
  WriteFile(staging_root / "bin/example", "new", 0755);
  InstallRequest request = RequestFor(install_root, staging_root);
  std::string script;

  const InstallResult result = internal::BuildInstallScriptForTesting(
      request, executable.string(), 2147483647, &script);

  ASSERT_TRUE(result.ok) << result.error;
  EXPECT_NE(script.find("resolved_target=\"$(cd \"$target\" && pwd -P)\""),
            std::string::npos);
  EXPECT_NE(script.find("rm -rf \"$target\""), std::string::npos);
  EXPECT_NE(script.find("rm -rf \"$staging\""), std::string::npos);
  EXPECT_EQ(script.find("rm -rf /usr"), std::string::npos);
  EXPECT_EQ(script.find("rm -rf /opt"), std::string::npos);
}

TEST(LinuxNativeInstall, RollbackRestoresOnlyVerifiedBundle) {
  TemporaryDirectory temporary;
  const fs::path install_root = temporary.path() / "app";
  const fs::path staging_root = temporary.path() / "staging";
  const fs::path executable = install_root / "bin/example";
  const fs::path outside = temporary.path() / "outside.txt";
  WriteFile(executable, "old executable", 0755);
  WriteFile(install_root / "old.txt", "old data");
  WriteFile(staging_root / "new.txt", "new data");
  WriteFile(outside, "outside data");
  InstallRequest request = RequestFor(install_root, staging_root);
  const fs::path diagnostics = temporary.path() / "failure.jsonl";
  request.diagnostics_log_path = diagnostics.string();
  std::string script;
  const auto build = internal::BuildInstallScriptForTesting(
      request, executable.string(), 2147483647, &script);
  ASSERT_TRUE(build.ok) << build.error;
  const fs::path script_path = temporary.path() / "update.sh";
  WriteFile(script_path, script, 0755);

  ASSERT_EQ(unsetenv("DESKTOP_UPDATER_SMOKE_SKIP_RELAUNCH"), 0);
  const int exit_code =
      std::system(("/bin/bash " + script_path.string()).c_str());

  EXPECT_NE(exit_code, 0);
  EXPECT_TRUE(fs::exists(install_root / "old.txt"));
  EXPECT_FALSE(fs::exists(install_root / "new.txt"));
  EXPECT_EQ(ReadFile(outside), "outside data");
  const std::string events = ReadFile(diagnostics);
  EXPECT_NE(events.find("\"event\":\"backup success\""), std::string::npos);
  EXPECT_NE(events.find("\"event\":\"move success\""), std::string::npos);
  EXPECT_NE(events.find("\"event\":\"rollback start\""), std::string::npos);
  EXPECT_NE(events.find("\"event\":\"rollback success\""), std::string::npos);
}

TEST(LinuxNativeInstall, SuccessfulInstallRecordsMoveAndCleanupEvents) {
  TemporaryDirectory temporary;
  const fs::path install_root = temporary.path() / "app";
  const fs::path staging_root = temporary.path() / "staging";
  const fs::path executable = install_root / "bin/example";
  WriteFile(executable, "old", 0755);
  WriteFile(staging_root / "bin/example", "new", 0755);
  InstallRequest request = RequestFor(install_root, staging_root);
  const fs::path diagnostics = temporary.path() / "success.jsonl";
  request.diagnostics_log_path = diagnostics.string();
  std::string script;
  const auto build = internal::BuildInstallScriptForTesting(
      request, executable.string(), 2147483647, &script);
  ASSERT_TRUE(build.ok) << build.error;
  const fs::path script_path = temporary.path() / "success.sh";
  WriteFile(script_path, script, 0755);

  ASSERT_EQ(setenv("DESKTOP_UPDATER_SMOKE_SKIP_RELAUNCH", "1", 1), 0);
  const int exit_code =
      std::system(("/bin/bash " + script_path.string()).c_str());
  ASSERT_EQ(unsetenv("DESKTOP_UPDATER_SMOKE_SKIP_RELAUNCH"), 0);

  EXPECT_EQ(exit_code, 0);
  EXPECT_EQ(ReadFile(executable), "new");
  EXPECT_FALSE(fs::exists(staging_root));
  const std::string events = ReadFile(diagnostics);
  EXPECT_NE(events.find("\"event\":\"backup success\""), std::string::npos);
  EXPECT_NE(events.find("\"event\":\"move success\""), std::string::npos);
  EXPECT_NE(events.find("\"event\":\"cleanup start\""), std::string::npos);
  EXPECT_NE(events.find("\"event\":\"cleanup success\""), std::string::npos);
  EXPECT_EQ(events.find("\"event\":\"rollback start\""), std::string::npos);
}

TEST(LinuxNativeInstall, StagingCleanupCannotDeleteInstallRoot) {
  TemporaryDirectory temporary;
  const fs::path install_root = temporary.path() / "app";
  const fs::path executable = install_root / "bin/example";
  WriteFile(executable, "old", 0755);
  InstallRequest request = RequestFor(install_root, install_root);
  std::string script;

  const InstallResult result = internal::BuildInstallScriptForTesting(
      request, executable.string(), 2147483647, &script);

  EXPECT_FALSE(result.ok);
  EXPECT_NE(result.error.find("overlap"), std::string::npos);
  EXPECT_TRUE(fs::exists(executable));
  EXPECT_TRUE(script.empty());
}

}  // namespace
}  // namespace test
}  // namespace native
}  // namespace desktop_updater
