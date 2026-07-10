#include <gtest/gtest.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cstdlib>
#include <cstdio>
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
  explicit TemporaryDirectory(bool system_temp = false) {
    char* created = nullptr;
    if (system_temp) {
#if defined(__APPLE__)
      char path[] = "/private/tmp/desktop_updater_native_test_XXXXXX";
#else
      char path[] = "/tmp/desktop_updater_native_test_XXXXXX";
#endif
      created = mkdtemp(path);
    } else {
      char path[] = "desktop_updater_native_test_XXXXXX";
      created = mkdtemp(path);
    }
    if (created == nullptr) {
      throw std::runtime_error("Unable to create native test directory");
    }
    path_ = fs::canonical(created);
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

int RunHelperScript(const fs::path& script_path,
                    const fs::path& fixture_root,
                    bool fail_permission_restore = false) {
  const fs::path tools = fixture_root / "tools";
  bool needs_tools = fail_permission_restore;
  if (fail_permission_restore) {
    WriteFile(tools / "chmod", "#!/bin/sh\nexit 1\n", 0755);
  }
#if defined(__APPLE__)
  needs_tools = true;
  WriteFile(
      tools / "stat",
      "#!/bin/sh\n"
      "if [ \"$1\" = '-c' ] && [ \"$2\" = '%s' ]; then\n"
      "  shift 2\n"
      "  exec /usr/bin/stat -f %z \"$@\"\n"
      "fi\n"
      "exec /usr/bin/stat \"$@\"\n",
      0755);
  WriteFile(
      tools / "find",
      "#!/bin/bash\n"
      "if [ \"$#\" -eq 8 ] && [ \"$7\" = '-printf' ]; then\n"
      "  exec /usr/bin/find \"$1\" \"$2\" \"$3\" \"$4\" \"$5\" \"$6\" -exec /usr/bin/printf \"$8\" \\;\n"
      "fi\n"
      "exec /usr/bin/find \"$@\"\n",
      0755);
#endif
  const char* previous_path = std::getenv("PATH");
  const std::string saved_path = previous_path == nullptr ? "" : previous_path;
  if (needs_tools &&
      setenv("PATH", (tools.string() + ":" + saved_path).c_str(), 1) != 0) {
    return -1;
  }
  const int result =
      std::system(("/bin/bash " + script_path.string()).c_str());
  if (needs_tools) {
    if (previous_path == nullptr) {
      unsetenv("PATH");
    } else {
      setenv("PATH", saved_path.c_str(), 1);
    }
  }
  return result;
}

std::string ReadFile(const fs::path& path) {
  std::ifstream file(path);
  return std::string(std::istreambuf_iterator<char>(file),
                     std::istreambuf_iterator<char>());
}

std::string Sha256File(const fs::path& path) {
  const std::string command = "sha256sum -- " + path.string();
  FILE* process = popen(command.c_str(), "r");
  if (process == nullptr) throw std::runtime_error("Unable to hash fixture.");
  char digest[65] = {};
  const bool ok = fscanf(process, "%64s", digest) == 1;
  const int status = pclose(process);
  if (!ok || status != 0) throw std::runtime_error("Unable to hash fixture.");
  return digest;
}

std::string JsonQuote(const std::string& value) {
  std::string quoted = "\"";
  for (const char byte : value) {
    if (byte == '\\' || byte == '"') {
      quoted += '\\';
    }
    quoted += byte;
  }
  quoted += '"';
  return quoted;
}

std::string CanonicalMarker(
    const std::vector<InstallProvenanceEntry>& entries) {
  std::string encoded_entries = "[";
  for (std::size_t index = 0; index < entries.size(); ++index) {
    const InstallProvenanceEntry& entry = entries[index];
    if (index != 0) encoded_entries += ',';
    encoded_entries += "{\"kind\":" + JsonQuote(entry.kind) +
        ",\"length\":" + std::to_string(entry.length) +
        ",\"path\":" + JsonQuote(entry.path);
    if (entry.kind == "file") {
      encoded_entries += ",\"sha256\":" + JsonQuote(entry.sha256);
    } else if (entry.kind == "symlink") {
      encoded_entries += ",\"target\":" + JsonQuote(entry.target);
    }
    encoded_entries += '}';
  }
  encoded_entries += ']';
  return "{\"artifactSha256\":\"" + std::string(64, 'a') +
      "\",\"descriptorSha256\":\"" + std::string(64, 'b') +
      "\",\"entries\":" + encoded_entries +
      ",\"nonce\":\"123e4567-e89b-42d3-a456-426614174000\""
      ",\"packageId\":\"com.example.app\",\"schemaVersion\":1}";
}

InstallRequest RequestFor(const fs::path& install_root,
                          const fs::path& staging_root,
                          bool write_installed_identity = true) {
  if (write_installed_identity) {
    WriteFile(
        install_root / ".desktop_updater_install_identity.json",
        "{\"packageId\":\"com.example.app\",\"schemaVersion\":1}");
  }
  InstallRequest request;
  request.operation = LinuxInstallOperation::kInstall;
  request.staging_path = staging_root.string();
  request.install_root = install_root.string();
  request.executable_relative_path = "bin/example";
  request.package_id = "com.example.app";
  request.provenance_nonce = "123e4567-e89b-42d3-a456-426614174000";
  for (const fs::directory_entry& entry :
       fs::recursive_directory_iterator(staging_root)) {
    const std::string relative = fs::relative(entry.path(), staging_root).string();
    if (relative == ".desktop_updater_stage_provenance.json") continue;
    if (entry.is_directory()) {
      request.provenance_entries.push_back({relative, "directory", 0, "", ""});
    } else if (entry.is_regular_file()) {
      request.provenance_entries.push_back(
          {relative, "file", static_cast<std::int64_t>(entry.file_size()),
           Sha256File(entry.path()), ""});
    }
  }
  std::sort(request.provenance_entries.begin(),
            request.provenance_entries.end(),
            [](const InstallProvenanceEntry& left,
               const InstallProvenanceEntry& right) {
              return left.path < right.path;
            });
  const fs::path marker =
      staging_root / ".desktop_updater_stage_provenance.json";
  WriteFile(marker, CanonicalMarker(request.provenance_entries));
  request.expected_provenance_sha256 = Sha256File(marker);
  return request;
}

TEST(LinuxNativeInstall, RejectsProtectedSharedRoots) {
  for (const char* root : {"/", "/bin", "/sbin", "/usr", "/usr/bin",
                           "/usr/sbin", "/usr/local", "/usr/local/bin",
                           "/opt", "/etc", "/var", "/home"}) {
    InstallRequest request;
    request.operation = LinuxInstallOperation::kInstall;
    request.staging_path = "/tmp/staging";
    request.install_root = root;
    request.executable_relative_path = "bin/example";
    request.package_id = "com.example.app";
    EXPECT_FALSE(ValidateInstallRequest(request).ok) << root;
  }
}

TEST(LinuxNativeInstall, LegacyFallbackAcceptsSelfContainedFlutterBundle) {
  char workspace_template[] = "desktop_updater_native_test_XXXXXX";
  char* workspace = mkdtemp(workspace_template);
  ASSERT_NE(workspace, nullptr);
  const fs::path fixture_root = fs::canonical(workspace);
  const fs::path install_root = fixture_root / "Example";
  const fs::path staging_root = fixture_root /
      "desktop_updater_stage_123e4567-e89b-42d3-a456-426614174000";
  const fs::path executable = install_root / "example";
  WriteFile(executable, "old", 0755);
  WriteFile(install_root / "data/flutter_assets/AssetManifest.bin", "assets");
  WriteFile(install_root / "lib/libflutter_linux_gtk.so", "flutter");
  WriteFile(staging_root / "example", "new", 0755);
  InstallRequest request = RequestFor(install_root, staging_root, false);
  request.install_root.clear();
  request.executable_relative_path.clear();
  std::string script;

  const InstallResult result = internal::BuildInstallScriptForTesting(
      request, executable.string(), 2147483647, &script);

  std::error_code cleanup_error;
  fs::remove_all(fixture_root, cleanup_error);
  ASSERT_TRUE(result.ok) << result.error;
  EXPECT_FALSE(script.empty());
}

TEST(LinuxNativeInstall, LegacyFallbackRejectsTemporaryRootWithoutScript) {
  TemporaryDirectory temporary(true);
  const fs::path install_root = temporary.path() / "Example";
  const fs::path staging_root = temporary.path() /
      "desktop_updater_stage_123e4567-e89b-42d3-a456-426614174000";
  const fs::path executable = install_root / "example";
  WriteFile(executable, "old", 0755);
  WriteFile(install_root / "data/flutter_assets/AssetManifest.bin", "assets");
  WriteFile(install_root / "lib/libflutter_linux_gtk.so", "flutter");
  WriteFile(staging_root / "example", "new", 0755);
  InstallRequest request = RequestFor(install_root, staging_root);
  request.install_root.clear();
  request.executable_relative_path.clear();
  std::string script;

  const InstallResult result = internal::BuildInstallScriptForTesting(
      request, executable.string(), 2147483647, &script);

  EXPECT_FALSE(result.ok);
  EXPECT_NE(result.error.find("self-contained Flutter bundle"),
            std::string::npos);
  EXPECT_TRUE(script.empty());
}

TEST(LinuxNativeInstall, ExplicitContextRejectsTemporaryRootWithoutScript) {
  TemporaryDirectory temporary(true);
  const fs::path install_root = temporary.path() / "Example";
  const fs::path staging_root = temporary.path() /
      "desktop_updater_stage_123e4567-e89b-42d3-a456-426614174000";
  const fs::path executable = install_root / "bin/example";
  WriteFile(executable, "old", 0755);
  WriteFile(staging_root / "bin/example", "new", 0755);
  InstallRequest request = RequestFor(install_root, staging_root);
  std::string script;

  const InstallResult result = internal::BuildInstallScriptForTesting(
      request, executable.string(), 2147483647, &script);

  EXPECT_FALSE(result.ok);
  EXPECT_NE(result.error.find("temporary"), std::string::npos);
  EXPECT_TRUE(script.empty());
}

TEST(LinuxNativeInstall, ExplicitContextRejectsBroadAncestorWithoutScript) {
  TemporaryDirectory temporary;
  const fs::path install_root = temporary.path() / "apps";
  const fs::path staging_root = temporary.path() /
      "desktop_updater_stage_123e4567-e89b-42d3-a456-426614174000";
  const fs::path executable = install_root / "Example/bin/example";
  WriteFile(executable, "old", 0755);
  WriteFile(staging_root / "Example/bin/example", "new", 0755);
  InstallRequest request = RequestFor(install_root, staging_root, false);
  request.executable_relative_path = "Example/bin/example";
  std::string script;

  const InstallResult result = internal::BuildInstallScriptForTesting(
      request, executable.string(), 2147483647, &script);

  EXPECT_FALSE(result.ok);
  EXPECT_NE(result.error.find("installed identity"), std::string::npos);
  EXPECT_TRUE(script.empty());
}

TEST(LinuxNativeInstall, LegacyFallbackRejectsSharedLocalBinWithoutScript) {
  TemporaryDirectory temporary;
  const char* previous_home = std::getenv("HOME");
  const std::string saved_home = previous_home == nullptr ? "" : previous_home;
  ASSERT_EQ(setenv("HOME", temporary.path().c_str(), 1), 0);
  const fs::path install_root = temporary.path() / ".local/bin";
  const fs::path staging_root = temporary.path() /
      "desktop_updater_stage_123e4567-e89b-42d3-a456-426614174000";
  const fs::path executable = install_root / "example";
  WriteFile(executable, "old", 0755);
  WriteFile(staging_root / "example", "new", 0755);
  InstallRequest request = RequestFor(install_root, staging_root);
  request.install_root.clear();
  request.executable_relative_path.clear();
  std::string script;

  const InstallResult result = internal::BuildInstallScriptForTesting(
      request, executable.string(), 2147483647, &script);

  if (previous_home == nullptr) {
    unsetenv("HOME");
  } else {
    setenv("HOME", saved_home.c_str(), 1);
  }
  EXPECT_FALSE(result.ok);
  EXPECT_NE(result.error.find("self-contained Flutter bundle"),
            std::string::npos);
  EXPECT_TRUE(script.empty());
}

TEST(LinuxNativeInstall, RejectsNonCanonicalAndSymlinkEscapes) {
  TemporaryDirectory temporary;
  const fs::path install_root = temporary.path() / "app";
  const fs::path staging_root = temporary.path() /
      "desktop_updater_stage_123e4567-e89b-42d3-a456-426614174000";
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
  const fs::path staging_root = temporary.path() /
      "desktop_updater_stage_123e4567-e89b-42d3-a456-426614174000";
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

TEST(LinuxNativeInstall, DerivesHelperInventoryAndNonceFromMarker) {
  TemporaryDirectory temporary;
  const fs::path install_root = temporary.path() / "app";
  const fs::path staging_root = temporary.path() /
      "desktop_updater_stage_123e4567-e89b-42d3-a456-426614174000";
  const fs::path executable = install_root / "bin/example";
  WriteFile(executable, "old", 0755);
  WriteFile(staging_root / "bin/example", "new", 0755);
  InstallRequest request = RequestFor(install_root, staging_root);
  const std::string marker_file_sha256 =
      request.provenance_entries.back().sha256;
  const std::string caller_file_sha256(64, '0');
  request.provenance_nonce = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  request.provenance_entries = {
      {"bin/example", "file", 3, caller_file_sha256, ""}};
  std::string script;

  const InstallResult result = internal::BuildInstallScriptForTesting(
      request, executable.string(), 2147483647, &script);

  ASSERT_TRUE(result.ok) << result.error;
  EXPECT_NE(script.find(marker_file_sha256), std::string::npos);
  EXPECT_EQ(script.find(caller_file_sha256), std::string::npos);
  EXPECT_NE(script.find("123e4567-e89b-42d3-a456-426614174000"),
            std::string::npos);
  EXPECT_EQ(script.find("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
            std::string::npos);
  EXPECT_NE(script.find("bound_provenance_marker="), std::string::npos);
  EXPECT_NE(script.find("bound_marker_sha256="), std::string::npos);
  EXPECT_NE(script.find(
                "[ \"$bound_marker_sha256\" = "
                "\"$expected_provenance_sha256\" ]"),
            std::string::npos);
}

TEST(LinuxNativeInstall, RollbackRestoresOnlyVerifiedBundle) {
  TemporaryDirectory temporary;
  const fs::path install_root = temporary.path() / "app";
  const fs::path staging_root = temporary.path() /
      "desktop_updater_stage_123e4567-e89b-42d3-a456-426614174000";
  const fs::path executable = install_root / "bin/example";
  const fs::path outside = temporary.path() / "outside.txt";
  WriteFile(executable, "old executable", 0755);
  WriteFile(install_root / "old.txt", "old data");
  WriteFile(staging_root / "bin/example", "new executable");
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
      RunHelperScript(script_path, temporary.path(), true);

  EXPECT_NE(exit_code, 0);
  EXPECT_TRUE(fs::exists(install_root / "old.txt"));
  EXPECT_FALSE(fs::exists(install_root / "new.txt"));
  EXPECT_EQ(ReadFile(executable), "old executable");
  struct stat restored_executable = {};
  ASSERT_EQ(stat(executable.c_str(), &restored_executable), 0);
  EXPECT_NE(restored_executable.st_mode & S_IXUSR, 0);
  EXPECT_EQ(ReadFile(outside), "outside data");
  const std::string events = ReadFile(diagnostics);
  EXPECT_NE(events.find("\"event\":\"backup success\""), std::string::npos);
  EXPECT_NE(events.find("\"event\":\"move success\""), std::string::npos);
  EXPECT_NE(events.find("\"event\":\"rollback start\""), std::string::npos);
  EXPECT_NE(events.find("\"event\":\"rollback success\""),
            std::string::npos);
}

TEST(LinuxNativeInstall, SuccessfulInstallRecordsMoveAndCleanupEvents) {
  TemporaryDirectory temporary;
  const fs::path install_root = temporary.path() / "app";
  const fs::path staging_root = temporary.path() /
      "desktop_updater_stage_123e4567-e89b-42d3-a456-426614174000";
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
  const int exit_code = RunHelperScript(script_path, temporary.path());
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
