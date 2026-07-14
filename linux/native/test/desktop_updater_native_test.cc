#include <gtest/gtest.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>

#include "desktop_updater_native.h"

namespace desktop_updater {
namespace native {
namespace test {
namespace {

namespace fs = std::filesystem;

class TemporaryDirectory {
 public:
  explicit TemporaryDirectory(bool system_temp = false) {
    std::string template_path;
    if (system_temp) {
#if defined(__APPLE__)
      template_path = "/private/tmp/desktop_updater_native_test_XXXXXX";
#else
      template_path = "/tmp/desktop_updater_native_test_XXXXXX";
#endif
    } else {
      template_path = "desktop_updater_native_test_XXXXXX";
    }
    std::vector<char> path(template_path.begin(), template_path.end());
    path.push_back('\0');
    char* created = mkdtemp(path.data());
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
  request.executable_relative_path = "example";
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

}  // namespace
}  // namespace test
}  // namespace native
}  // namespace desktop_updater
