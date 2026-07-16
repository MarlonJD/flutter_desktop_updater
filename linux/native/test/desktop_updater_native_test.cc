#include <gtest/gtest.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>

#define MINIZ_NO_ZLIB_APIS
#include "miniz.h"

#include "desktop_updater_native.h"
#include "json_value.h"
#include "linux_native_install_request_builder.h"
#include "monocypher-ed25519.h"
#include "native_install_request.h"
#include "release_contract.h"
#include "stage_provenance.h"
#include "helper/unix_socket_transport.h"

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
      throw std::runtime_error(
          "Unable to create native test directory (errno " +
          std::to_string(errno) + ")");
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

void AppendByte(const fs::path& path, char byte) {
  std::ofstream file(path, std::ios::binary | std::ios::app);
  file.put(byte);
  file.close();
  ASSERT_TRUE(file.good());
}

std::string ReadFile(const fs::path& path);

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
    const std::vector<InstallProvenanceEntry>& entries,
    const std::string& descriptor_sha256 = std::string(64, 'b'),
    const std::string& artifact_sha256 = std::string(64, 'a')) {
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
  return "{\"artifactSha256\":\"" + artifact_sha256 +
      "\",\"descriptorSha256\":\"" + descriptor_sha256 +
      "\",\"entries\":" + encoded_entries +
      ",\"nonce\":\"123e4567-e89b-42d3-a456-426614174000\""
      ",\"packageId\":\"com.example.app\",\"schemaVersion\":1}";
}

InstallRequest RequestFor(const fs::path& install_root,
                          const fs::path& staging_root,
                          bool write_installed_identity = true,
                          const std::string& descriptor_sha256 =
                              std::string(64, 'b'),
                          const std::string& artifact_sha256 =
                              std::string(64, 'a')) {
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
  WriteFile(marker,
            CanonicalMarker(request.provenance_entries, descriptor_sha256,
                            artifact_sha256));
  request.expected_provenance_sha256 = Sha256File(marker);
  return request;
}

std::string Base64(const unsigned char* bytes, std::size_t length) {
  static constexpr char alphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string result;
  result.reserve(((length + 2) / 3) * 4);
  for (std::size_t offset = 0; offset < length; offset += 3) {
    const std::uint32_t first = bytes[offset];
    const std::uint32_t second =
        offset + 1 < length ? bytes[offset + 1] : 0;
    const std::uint32_t third =
        offset + 2 < length ? bytes[offset + 2] : 0;
    const std::uint32_t value = (first << 16) | (second << 8) | third;
    result.push_back(alphabet[(value >> 18) & 0x3f]);
    result.push_back(alphabet[(value >> 12) & 0x3f]);
    result.push_back(offset + 1 < length ? alphabet[(value >> 6) & 0x3f]
                                         : '=');
    result.push_back(offset + 2 < length ? alphabet[value & 0x3f] : '=');
  }
  return result;
}

struct SignedLinuxManifest {
  std::string canonical_json;
  std::string public_key_base64;
};

SignedLinuxManifest CanonicalSignedLinuxManifest(
    const std::string& artifact_sha256 = std::string(64, 'a'),
    std::int64_t artifact_length = 42) {
  using runtime::internal::EncodeCanonicalJson;
  using runtime::internal::JsonValue;
  JsonValue::Object artifact;
  artifact.emplace("kind", JsonValue(std::string("zip")));
  artifact.emplace("length", JsonValue(artifact_length));
  artifact.emplace("sha256", JsonValue(artifact_sha256));
  artifact.emplace("url", JsonValue(std::string("https://example.test/app.zip")));
  JsonValue::Object install;
  install.emplace("strategy", JsonValue(std::string("wholeDirectoryReplace")));
  JsonValue::Object signature;
  signature.emplace("algorithm", JsonValue(std::string("ed25519")));
  signature.emplace("publicKeyId", JsonValue(std::string("stable-2026")));
  signature.emplace("value", JsonValue(std::string(86, 'A') + "=="));
  JsonValue::Object minimum_os;
  minimum_os.emplace("linux", JsonValue(std::string("glibc-2.35")));
  JsonValue::Object manifest;
  manifest.emplace("appName", JsonValue(std::string("Example")));
  manifest.emplace("artifact", JsonValue(std::move(artifact)));
  manifest.emplace("buildNumber", JsonValue(std::int64_t{2}));
  manifest.emplace("channel", JsonValue(std::string("stable")));
  manifest.emplace("generatedAt",
                   JsonValue(std::string("2026-07-15T00:00:00.000Z")));
  manifest.emplace("install", JsonValue(std::move(install)));
  manifest.emplace("minimumOS", JsonValue(std::move(minimum_os)));
  manifest.emplace("minimumUpdaterVersion", JsonValue(std::string("2.0.0")));
  manifest.emplace("packageId", JsonValue(std::string("com.example.app")));
  manifest.emplace("platform", JsonValue(std::string("linux")));
  manifest.emplace("schemaVersion", JsonValue(std::int64_t{3}));
  manifest.emplace("signature", JsonValue(std::move(signature)));
  manifest.emplace("version", JsonValue(std::string("2.0.0")));
  JsonValue value(std::move(manifest));
  const std::string unsigned_json = EncodeCanonicalJson(value);
  const auto descriptor =
      runtime::internal::ParseReleaseDescriptor(unsigned_json);
  const std::string message =
      runtime::internal::CanonicalSignatureBytes(descriptor);
  std::array<std::uint8_t, 32> seed{};
  for (std::size_t index = 0; index < seed.size(); ++index) {
    seed[index] = static_cast<std::uint8_t>(index + 1);
  }
  std::array<std::uint8_t, 64> secret{};
  std::array<std::uint8_t, 32> public_key{};
  std::array<std::uint8_t, 64> signed_bytes{};
  crypto_ed25519_key_pair(secret.data(), public_key.data(), seed.data());
  crypto_ed25519_sign(
      signed_bytes.data(), secret.data(),
      reinterpret_cast<const std::uint8_t*>(message.data()), message.size());
  value.object()
      .at("signature")
      .object()
      .at("value") = JsonValue(Base64(signed_bytes.data(), signed_bytes.size()));
  return {EncodeCanonicalJson(value),
          Base64(public_key.data(), public_key.size())};
}

struct LinuxZipEntry {
  std::string path;
  std::string bytes;
  std::uint32_t mode = 0100644;
};

void WriteLinuxZip(const fs::path& archive_path,
                   const std::vector<LinuxZipEntry>& entries) {
  mz_zip_archive archive{};
  if (!mz_zip_writer_init_file(&archive, archive_path.c_str(), 0)) {
    throw std::runtime_error("unable to create Linux ZIP fixture");
  }
  for (const auto& entry : entries) {
    if (!mz_zip_writer_add_mem_ex(
            &archive, entry.path.c_str(), entry.bytes.data(),
            entry.bytes.size(), nullptr, 0, MZ_BEST_COMPRESSION, 0, 0)) {
      mz_zip_writer_end(&archive);
      throw std::runtime_error("unable to add Linux ZIP fixture entry");
    }
  }
  const bool finalized = mz_zip_writer_finalize_archive(&archive) != 0;
  const bool ended = mz_zip_writer_end(&archive) != 0;
  if (!finalized || !ended) {
    throw std::runtime_error("unable to finalize Linux ZIP fixture");
  }
  std::fstream file(archive_path,
                    std::ios::in | std::ios::out | std::ios::binary);
  std::vector<unsigned char> bytes{
      std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
  std::size_t entry_index = 0;
  for (std::size_t index = 0;
       index + 42 <= bytes.size() && entry_index < entries.size(); ++index) {
    if (bytes[index] != 0x50 || bytes[index + 1] != 0x4b ||
        bytes[index + 2] != 0x01 || bytes[index + 3] != 0x02) {
      continue;
    }
    bytes[index + 5] = 3;
    const std::uint32_t attributes = entries[entry_index++].mode << 16;
    for (int byte = 0; byte < 4; ++byte) {
      bytes[index + 38 + byte] = static_cast<unsigned char>(
          (attributes >> (byte * 8)) & 0xffU);
    }
  }
  if (entry_index != entries.size()) {
    throw std::runtime_error("Linux ZIP central directory is incomplete");
  }
  file.clear();
  file.seekp(0);
  file.write(reinterpret_cast<const char*>(bytes.data()), bytes.size());
  file.close();
  if (!file) throw std::runtime_error("unable to patch Linux ZIP modes");
  chmod(archive_path.c_str(), 0600);
}

std::vector<LinuxZipEntry> LinuxPayloadEntries(const fs::path& root) {
  std::vector<LinuxZipEntry> entries;
  for (const auto& entry : fs::recursive_directory_iterator(root)) {
    const fs::path relative = fs::relative(entry.path(), root);
    const std::string path = relative.generic_string();
    if (relative.begin() != relative.end()) {
      const std::string top = relative.begin()->string();
      if (top == ".desktop_updater_artifact.zip" ||
          top == ".desktop_updater_release_manifest.json" ||
          top == ".desktop_updater_stage_provenance.json" ||
          top == ".desktop_updater_payload_seal.json") {
        continue;
      }
    }
    struct stat status {};
    if (lstat(entry.path().c_str(), &status) != 0 || S_ISLNK(status.st_mode)) {
      throw std::runtime_error("unsafe Linux ZIP fixture entry");
    }
    if (S_ISREG(status.st_mode)) {
      entries.push_back(
          {path, ReadFile(entry.path()),
           static_cast<std::uint32_t>(status.st_mode)});
    }
  }
  std::sort(entries.begin(), entries.end(),
            [](const LinuxZipEntry& first, const LinuxZipEntry& second) {
              return first.path < second.path;
            });
  return entries;
}

SignedLinuxManifest WriteSignedLinuxStageControl(const fs::path& stage) {
  const fs::path archive = stage / ".desktop_updater_artifact.zip";
  WriteLinuxZip(archive, LinuxPayloadEntries(stage));
  const std::string artifact_sha256 = Sha256File(archive);
  const auto signed_manifest = CanonicalSignedLinuxManifest(
      artifact_sha256, static_cast<std::int64_t>(fs::file_size(archive)));
  WriteFile(stage / ".desktop_updater_release_manifest.json",
            signed_manifest.canonical_json);
  return signed_manifest;
}

std::string CanonicalPortablePolicy(const std::string& caller_sha256,
                                    const std::string& helper_sha256,
                                    const std::string& release_key_base64) {
  using runtime::internal::EncodeCanonicalJson;
  using runtime::internal::JsonValue;
  JsonValue::Object caller;
  caller.emplace("kind", JsonValue(std::string("sha256")));
  caller.emplace("value", JsonValue(caller_sha256));
  JsonValue::Object helper;
  helper.emplace("kind", JsonValue(std::string("sha256")));
  helper.emplace("value", JsonValue(helper_sha256));
  JsonValue::Object root_key;
  root_key.emplace("algorithm", JsonValue(std::string("ed25519")));
  root_key.emplace("keyId", JsonValue(std::string("stable-2026")));
  root_key.emplace("publicKeyBase64", JsonValue(release_key_base64));
  JsonValue::Object strategy;
  strategy.emplace("provider", JsonValue(std::string("platformDirectory")));
  strategy.emplace("strategy", JsonValue(std::string("directoryReplace")));
  JsonValue::Object policy;
  policy.emplace("allowedApplicationSigner", JsonValue(std::move(caller)));
  policy.emplace("allowedHelperSigner", JsonValue(std::move(helper)));
  policy.emplace("allowedInstallRoots", JsonValue(JsonValue::Array{}));
  policy.emplace(
      "allowedStrategies",
      JsonValue(JsonValue::Array{JsonValue(std::move(strategy))}));
  policy.emplace(
      "allowedTargetClasses",
      JsonValue(JsonValue::Array{JsonValue(std::string("sameUserWritable"))}));
  policy.emplace("applicationPackageId",
                 JsonValue(std::string("com.example.app")));
  policy.emplace("helperServiceId",
                 JsonValue(std::string("com.example.desktop-updater.helper")));
  policy.emplace("minimumHelperProtocolVersion", JsonValue(std::int64_t{1}));
  policy.emplace("policyId", JsonValue(
      std::string("com.example.desktop-updater.portable")));
  policy.emplace("policyVersion", JsonValue(std::int64_t{1}));
  policy.emplace(
      "releaseRootPublicKeys",
      JsonValue(JsonValue::Array{JsonValue(std::move(root_key))}));
  return EncodeCanonicalJson(JsonValue(std::move(policy)));
}

std::string ReadFile(const fs::path& path) {
  std::ifstream input(path, std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

std::string TransactionIdFromResult(const fs::path& path) {
  const std::string bytes = ReadFile(path);
  const std::string label = "transaction\n";
  const std::size_t start = bytes.find(label);
  if (start == std::string::npos) return {};
  const std::size_t value_start = start + label.size();
  const std::size_t value_end = bytes.find('\n', value_start);
  return value_end == std::string::npos
             ? std::string()
             : bytes.substr(value_start, value_end - value_start);
}

std::string OnlyRegisteredTransactionId(const fs::path& state_home) {
  const fs::path transactions =
      state_home / "desktop-updater" / "transactions";
  std::vector<std::string> transaction_ids;
  for (const fs::directory_entry& entry :
       fs::directory_iterator(transactions)) {
    if (!entry.is_regular_file() || entry.path().extension() != ".json") {
      continue;
    }
    const auto encoded = runtime::internal::ParseJson(ReadFile(entry.path()));
    const std::string transaction_id = encoded.at("transactionId").string();
    if (entry.path().filename() != transaction_id + ".json") {
      throw std::runtime_error("transaction registry filename changed");
    }
    transaction_ids.push_back(transaction_id);
  }
  if (transaction_ids.size() != 1) {
    throw std::runtime_error("expected exactly one transaction registry record");
  }
  return transaction_ids.front();
}

class ScopedEnvironmentVariable {
 public:
  explicit ScopedEnvironmentVariable(std::string name)
      : name_(std::move(name)) {
    const char* current = std::getenv(name_.c_str());
    if (current != nullptr) {
      had_value_ = true;
      saved_value_ = current;
    }
  }

  ~ScopedEnvironmentVariable() {
    if (had_value_) {
      (void)setenv(name_.c_str(), saved_value_.c_str(), 1);
    } else {
      (void)unsetenv(name_.c_str());
    }
  }

  void Set(const char* value) {
    if (setenv(name_.c_str(), value, 1) != 0) {
      throw std::runtime_error("unable to set test environment variable");
    }
  }

  void Unset() {
    if (unsetenv(name_.c_str()) != 0) {
      throw std::runtime_error("unable to unset test environment variable");
    }
  }

 private:
  std::string name_;
  std::string saved_value_;
  bool had_value_ = false;
};

int RunControlFixture(const fs::path& executable,
                      const char* operation,
                      const std::string& transaction_id,
                      const fs::path& result_path) {
  const pid_t child = fork();
  if (child < 0) return -1;
  if (child == 0) {
    execl(executable.c_str(), executable.filename().c_str(), operation,
          transaction_id.c_str(), result_path.c_str(), nullptr);
    _exit(127);
  }
  int status = 0;
  if (waitpid(child, &status, 0) != child || !WIFEXITED(status)) return -1;
  return WEXITSTATUS(status);
}

TEST(LinuxNativeInstall,
     RestartCurrentApplicationWaitsForCallerExitWithoutInstallHelper) {
  TemporaryDirectory temporary(true);
  const fs::path proof = temporary.path() / "restart-proof.txt";
  const fs::path exit_proof = temporary.path() / "exit-proof.txt";
  const fs::path fixture = DESKTOP_UPDATER_RESTART_CALLER_FIXTURE;
  ASSERT_TRUE(fs::exists(fixture));

  const pid_t caller = fork();
  ASSERT_GE(caller, 0);
  if (caller == 0) {
    setenv("DESKTOP_UPDATER_TEST_RESTART_PROOF", proof.c_str(), 1);
    setenv("DESKTOP_UPDATER_TEST_RESTART_EXIT_PROOF", exit_proof.c_str(), 1);
    execl(fixture.c_str(), fixture.filename().c_str(), "--restart", nullptr);
    _exit(127);
  }

  int caller_status = 0;
  ASSERT_EQ(caller, waitpid(caller, &caller_status, 0));
  ASSERT_TRUE(WIFEXITED(caller_status));
  ASSERT_EQ(0, WEXITSTATUS(caller_status));

  for (int attempt = 0; attempt != 200 && !fs::exists(proof); ++attempt) {
    usleep(10'000);
  }
  ASSERT_TRUE(fs::exists(proof));
  EXPECT_EQ("restarted-after-exit\n", ReadFile(proof));
}

TEST(LinuxNativeInstall, BuildsCanonicalProtocolV1RequestForHelperParser) {
  using runtime::internal::EncodeCanonicalJson;
  using runtime::internal::EncodeCanonicalNativeInstallTransactionRequestV1;
  using runtime::internal::JsonValue;
  using runtime::internal::LinuxNativeInstallEvidenceV1;
  using runtime::internal::ParseNativeInstallTransactionRequestV1;
  using runtime::internal::StageProvenanceBinding;
  using runtime::internal::StageProvenanceMarker;

  JsonValue::Object artifact;
  artifact.emplace("kind", JsonValue(std::string("zip")));
  artifact.emplace("length", JsonValue(std::int64_t{42}));
  artifact.emplace("sha256", JsonValue(std::string(64, 'a')));
  artifact.emplace("url", JsonValue(std::string("https://example.test/app.zip")));
  JsonValue::Object install;
  install.emplace("strategy", JsonValue(std::string("wholeDirectoryReplace")));
  JsonValue::Object signature;
  signature.emplace("algorithm", JsonValue(std::string("ed25519")));
  signature.emplace("publicKeyId", JsonValue(std::string("stable-2026")));
  signature.emplace("value", JsonValue(std::string(86, 'A') + "=="));
  JsonValue::Object manifest;
  manifest.emplace("appName", JsonValue(std::string("Example")));
  manifest.emplace("artifact", JsonValue(std::move(artifact)));
  manifest.emplace("buildNumber", JsonValue(std::int64_t{2}));
  manifest.emplace("channel", JsonValue(std::string("stable")));
  manifest.emplace("generatedAt",
                   JsonValue(std::string("2026-07-15T00:00:00.000Z")));
  manifest.emplace("install", JsonValue(std::move(install)));
  JsonValue::Object minimum_os;
  minimum_os.emplace("linux", JsonValue(std::string("glibc-2.35")));
  manifest.emplace("minimumOS", JsonValue(std::move(minimum_os)));
  manifest.emplace("minimumUpdaterVersion", JsonValue(std::string("2.0.0")));
  manifest.emplace("packageId", JsonValue(std::string("com.example.app")));
  manifest.emplace("platform", JsonValue(std::string("linux")));
  manifest.emplace("schemaVersion", JsonValue(std::int64_t{3}));
  manifest.emplace("signature", JsonValue(std::move(signature)));
  manifest.emplace("version", JsonValue(std::string("2.0.0")));
  const std::string canonical_manifest =
      EncodeCanonicalJson(JsonValue(std::move(manifest)));

  StageProvenanceMarker marker;
  marker.nonce = "123e4567-e89b-42d3-a456-426614174000";
  marker.package_id = "com.example.app";
  marker.descriptor_sha256 = std::string(64, 'b');
  marker.artifact_sha256 = std::string(64, 'a');
  const StageProvenanceBinding stage_binding{
      marker, CanonicalMarker({}, marker.descriptor_sha256,
                              marker.artifact_sha256)};
  LinuxNativeInstallEvidenceV1 evidence;
  evidence.transaction_id = "00000000-0000-4000-8000-000000000009";
  evidence.policy_id = "com.example.desktop-updater.portable";
  evidence.package_id = "com.example.app";
  evidence.target_path_hint = "/opt/Example";
  evidence.target_name_hint = "Example";
  evidence.executable_relative_path = "bin/example";
  evidence.target_identity_proof_sha256 = std::string(64, 'c');
  evidence.current_version = "1.0.0";
  evidence.current_build_number = 1;
  evidence.current_package_identity_sha256 = std::string(64, 'c');
  evidence.stage_path_hint = "/opt/desktop_updater_stage";
  evidence.expected_provenance_sha256 = std::string(64, 'd');
  evidence.expected_artifact_sha256 = std::string(64, 'a');
  evidence.caller_process_id = 4242;
  evidence.caller_process_start_identity = "linux:123";
  evidence.caller_executable_sha256 = std::string(64, 'e');
  evidence.caller_signer_identity = std::string(64, 'e');
  evidence.request_nonce = std::string(43, 'F');

  const auto request = runtime::internal::
      BuildLinuxNativeInstallTransactionRequestV1(
          canonical_manifest, stage_binding, evidence,
          [&](const std::string& bytes) {
            if (bytes == marker.nonce) return std::string(64, 'f');
            if (bytes == stage_binding.canonical_json) {
              return evidence.expected_provenance_sha256;
            }
            return std::string(64, 'b');
          });
  const std::string canonical_request =
      EncodeCanonicalNativeInstallTransactionRequestV1(request);
  const auto parsed =
      ParseNativeInstallTransactionRequestV1(canonical_request);

  EXPECT_EQ(1, parsed.protocol_version);
  EXPECT_EQ(evidence.transaction_id, parsed.transaction_id);
  EXPECT_EQ(evidence.policy_id, parsed.policy_id);
  EXPECT_EQ("directoryReplace", parsed.strategy);
  EXPECT_EQ("platformDirectory", parsed.provider);
  EXPECT_EQ("sameUserWritable", parsed.target.target_class);
  EXPECT_EQ(evidence.request_nonce, parsed.request_nonce);
  EXPECT_EQ(marker.artifact_sha256, parsed.stage.artifact_sha256);

  auto drifted_evidence = evidence;
  drifted_evidence.expected_provenance_sha256 = std::string(64, '9');
  EXPECT_THROW(
      runtime::internal::BuildLinuxNativeInstallTransactionRequestV1(
          canonical_manifest, stage_binding, drifted_evidence,
          [&](const std::string& bytes) {
            if (bytes == marker.nonce) return std::string(64, 'f');
            if (bytes == stage_binding.canonical_json) {
              return evidence.expected_provenance_sha256;
            }
            return std::string(64, 'b');
          }),
      runtime::internal::LinuxNativeInstallRequestBuilderError);
}

TEST(LinuxNativeInstall,
     PrepareRejectsCopiedLauncherAtWrongTargetBeforeHelperLaunch) {
  TemporaryDirectory temporary;
  const fs::path install_root = temporary.path() / "CopiedTarget.AppDir";
  const std::string nonce = "123e4567-e89b-42d3-a456-426614174000";
  const fs::path staging_root =
      temporary.path() / ("desktop_updater_stage_" + nonce);
  const fs::path copied_launcher = install_root / "copied-launcher";
  fs::create_directories(install_root);
  fs::create_directories(staging_root);
  ASSERT_TRUE(fs::copy_file("/proc/self/exe", copied_launcher));
  ASSERT_EQ(0, chmod(copied_launcher.c_str(), 0755));
  WriteFile(staging_root / copied_launcher.filename(), "new", 0755);
  (void)WriteSignedLinuxStageControl(staging_root);
  const fs::path manifest_path =
      staging_root / ".desktop_updater_release_manifest.json";
  InstallRequest request = RequestFor(
      install_root, staging_root, true, Sha256File(manifest_path),
      Sha256File(staging_root / ".desktop_updater_artifact.zip"));
  request.executable_relative_path = copied_launcher.filename().string();

  InstallReservation reservation;
  const InstallResult prepared = PrepareInstall(request, &reservation);
  EXPECT_FALSE(prepared.ok);
  EXPECT_NE(std::string::npos,
            prepared.error.find(
                "Linux install target does not match the running app"));
  EXPECT_TRUE(reservation.transaction_id.empty());
}

TEST(LinuxNativeInstall, PublicClientPreparesAndCancelsOverRealUnixSocket) {
  if (geteuid() == 0) {
    GTEST_SKIP() << "portable helper handoff requires a non-root test user";
  }
  const fs::path executable = fs::canonical("/proc/self/exe");
  const fs::path install_root = executable.parent_path();
  const fs::path helper = install_root / "desktop-updater-helper";
  if (!fs::exists(helper)) {
    GTEST_SKIP() << "desktop-updater-helper target is unavailable";
  }
  const std::string nonce = "123e4567-e89b-42d3-a456-426614174000";
  const fs::path staging_root =
      install_root.parent_path() / ("desktop_updater_stage_" + nonce);
  const fs::path installed_identity =
      install_root / ".desktop_updater_install_identity.json";
  TemporaryDirectory runtime_directory(true);
  TemporaryDirectory state_directory(true);
  ASSERT_EQ(chmod(runtime_directory.path().c_str(), 0700), 0);
  ASSERT_EQ(chmod(state_directory.path().c_str(), 0700), 0);
  const char* old_runtime = std::getenv("XDG_RUNTIME_DIR");
  const std::string saved_runtime = old_runtime == nullptr ? "" : old_runtime;
  const char* old_state = std::getenv("XDG_STATE_HOME");
  const std::string saved_state = old_state == nullptr ? "" : old_state;
  ASSERT_EQ(setenv("XDG_RUNTIME_DIR", runtime_directory.path().c_str(), 1), 0);
  ASSERT_EQ(setenv("XDG_STATE_HOME", state_directory.path().c_str(), 1), 0);

  std::error_code cleanup_error;
  fs::remove_all(staging_root, cleanup_error);
  WriteFile(staging_root / executable.filename(), "new", 0755);
  const SignedLinuxManifest signed_manifest =
      WriteSignedLinuxStageControl(staging_root);
  const fs::path manifest_path =
      staging_root / ".desktop_updater_release_manifest.json";
  const std::string descriptor_sha256 = Sha256File(manifest_path);
  const std::string artifact_sha256 =
      Sha256File(staging_root / ".desktop_updater_artifact.zip");
  InstallRequest request = RequestFor(install_root, staging_root, true,
                                      descriptor_sha256, artifact_sha256);
  request.executable_relative_path = executable.filename().string();
  WriteFile(helper.parent_path() / "desktop-updater-helper.policy.json",
            CanonicalPortablePolicy(Sha256File(executable),
                                    Sha256File(helper),
                                    signed_manifest.public_key_base64),
            0600);

  InstallReservation reservation;
  const InstallResult prepared = PrepareInstall(request, &reservation);
  EXPECT_TRUE(prepared.ok) << prepared.error;
  EXPECT_FALSE(reservation.transaction_id.empty());
  EXPECT_EQ(43u, reservation.ready_token.size());
  if (prepared.ok) {
    const fs::path helper_stage =
        install_root.parent_path() /
        ("desktop_updater_stage_" + reservation.transaction_id);
    const fs::path helper_control = install_root.parent_path() /
        ("." + install_root.filename().string() + ".desktop-updater-" +
         reservation.transaction_id + ".control");
    EXPECT_TRUE(fs::exists(helper_stage / executable.filename()));
    EXPECT_TRUE(fs::exists(helper_control));
    const InstallTransactionStatus cancelled = CancelReservation(reservation);
    EXPECT_EQ(InstallTransactionState::kCancelled, cancelled.state)
        << cancelled.detail;
    EXPECT_EQ(InstallTransactionResultCode::kSucceeded,
              cancelled.result_code);
    EXPECT_FALSE(fs::exists(helper_stage));
    EXPECT_FALSE(fs::exists(helper_control));
    EXPECT_TRUE(fs::exists(staging_root));
  }

  fs::remove(installed_identity, cleanup_error);
  fs::remove_all(staging_root, cleanup_error);
  if (old_runtime == nullptr) {
    unsetenv("XDG_RUNTIME_DIR");
  } else {
    setenv("XDG_RUNTIME_DIR", saved_runtime.c_str(), 1);
  }
  if (old_state == nullptr) {
    unsetenv("XDG_STATE_HOME");
  } else {
    setenv("XDG_STATE_HOME", saved_state.c_str(), 1);
  }
}

TEST(LinuxNativeInstall,
     PublicRecoveryRollsBackWhenHelperDiesAfterPreparingRegistry) {
  if (geteuid() == 0) {
    GTEST_SKIP() << "portable helper handoff requires a non-root test user";
  }
  const fs::path executable = fs::canonical("/proc/self/exe");
  const fs::path install_root = executable.parent_path();
  const fs::path helper = install_root / "desktop-updater-helper";
  if (!fs::exists(helper)) {
    GTEST_SKIP() << "desktop-updater-helper target is unavailable";
  }
  const std::string nonce = "123e4567-e89b-42d3-a456-426614174000";
  const fs::path staging_root =
      install_root.parent_path() / ("desktop_updater_stage_" + nonce);
  const fs::path installed_identity =
      install_root / ".desktop_updater_install_identity.json";
  TemporaryDirectory runtime_directory(true);
  TemporaryDirectory state_directory(true);
  ASSERT_EQ(0, chmod(runtime_directory.path().c_str(), 0700));
  ASSERT_EQ(0, chmod(state_directory.path().c_str(), 0700));
  ScopedEnvironmentVariable runtime_environment("XDG_RUNTIME_DIR");
  ScopedEnvironmentVariable state_environment("XDG_STATE_HOME");
  ScopedEnvironmentVariable preparing_exit(
      "DESKTOP_UPDATER_TEST_EXIT_AFTER_PREPARING_REGISTRY");
  runtime_environment.Set(runtime_directory.path().c_str());
  state_environment.Set(state_directory.path().c_str());

  std::error_code cleanup_error;
  fs::remove_all(staging_root, cleanup_error);
  WriteFile(staging_root / executable.filename(), "new", 0755);
  const SignedLinuxManifest signed_manifest =
      WriteSignedLinuxStageControl(staging_root);
  const fs::path manifest_path =
      staging_root / ".desktop_updater_release_manifest.json";
  InstallRequest request = RequestFor(
      install_root, staging_root, true, Sha256File(manifest_path),
      Sha256File(staging_root / ".desktop_updater_artifact.zip"));
  request.executable_relative_path = executable.filename().string();
  WriteFile(helper.parent_path() / "desktop-updater-helper.policy.json",
            CanonicalPortablePolicy(Sha256File(executable),
                                    Sha256File(helper),
                                    signed_manifest.public_key_base64),
            0600);

  preparing_exit.Set("1");
  InstallReservation reservation;
  const InstallResult prepared = PrepareInstall(request, &reservation);
  preparing_exit.Unset();
  EXPECT_FALSE(prepared.ok) << prepared.error;
  EXPECT_TRUE(reservation.transaction_id.empty());

  const std::string transaction_id =
      OnlyRegisteredTransactionId(state_directory.path());
  const fs::path transaction_record =
      state_directory.path() / "desktop-updater" / "transactions" /
      (transaction_id + ".json");
  const auto registered =
      runtime::internal::ParseJson(ReadFile(transaction_record));
  EXPECT_EQ("preparing", registered.at("state").string());
  EXPECT_EQ(std::string(64, '0'),
            registered.at("journalSha256").string());

  const std::string prefix = "." + install_root.filename().string() +
                             ".desktop-updater-" + transaction_id;
  const fs::path helper_stage = install_root.parent_path() /
      ("desktop_updater_stage_" + transaction_id);
  const fs::path helper_control =
      install_root.parent_path() / (prefix + ".control");
  const fs::path restage_record = install_root.parent_path() /
      (".desktop-updater-restage-" + transaction_id + ".json");
  const fs::path journal =
      install_root.parent_path() / (prefix + ".journal.json");
  EXPECT_TRUE(fs::exists(helper_stage));
  EXPECT_TRUE(fs::exists(helper_control));
  EXPECT_TRUE(fs::exists(restage_record));
  EXPECT_FALSE(fs::exists(journal));

  const InstallTransactionStatus recovered =
      RecoverPendingInstall(transaction_id);
  EXPECT_EQ(InstallTransactionState::kRolledBack, recovered.state)
      << recovered.detail;
  EXPECT_EQ(InstallTransactionResultCode::kSucceeded,
            recovered.result_code);
  EXPECT_FALSE(fs::exists(helper_stage));
  EXPECT_FALSE(fs::exists(helper_control));
  EXPECT_FALSE(fs::exists(restage_record));
  EXPECT_TRUE(fs::exists(staging_root));
  EXPECT_EQ("new", ReadFile(staging_root / executable.filename()));
  EXPECT_EQ("{\"packageId\":\"com.example.app\",\"schemaVersion\":1}",
            ReadFile(installed_identity));
  EXPECT_TRUE(fs::exists(executable));

  fs::remove(installed_identity, cleanup_error);
  fs::remove_all(staging_root, cleanup_error);
}

TEST(LinuxNativeInstall,
     PublicRecoveryCleansTerminalRollbackAfterCancelHelperDies) {
  if (geteuid() == 0) {
    GTEST_SKIP() << "portable helper handoff requires a non-root test user";
  }
  const fs::path executable = fs::canonical("/proc/self/exe");
  const fs::path install_root = executable.parent_path();
  const fs::path helper = install_root / "desktop-updater-helper";
  if (!fs::exists(helper)) {
    GTEST_SKIP() << "desktop-updater-helper target is unavailable";
  }
  const std::string nonce = "123e4567-e89b-42d3-a456-426614174000";
  const fs::path staging_root =
      install_root.parent_path() / ("desktop_updater_stage_" + nonce);
  const fs::path installed_identity =
      install_root / ".desktop_updater_install_identity.json";
  TemporaryDirectory runtime_directory(true);
  TemporaryDirectory state_directory(true);
  ASSERT_EQ(0, chmod(runtime_directory.path().c_str(), 0700));
  ASSERT_EQ(0, chmod(state_directory.path().c_str(), 0700));
  ScopedEnvironmentVariable runtime_environment("XDG_RUNTIME_DIR");
  ScopedEnvironmentVariable state_environment("XDG_STATE_HOME");
  ScopedEnvironmentVariable rollback_exit(
      "DESKTOP_UPDATER_TEST_EXIT_AFTER_ROLLBACK_REGISTRY");
  runtime_environment.Set(runtime_directory.path().c_str());
  state_environment.Set(state_directory.path().c_str());

  std::error_code cleanup_error;
  fs::remove_all(staging_root, cleanup_error);
  WriteFile(staging_root / executable.filename(), "new", 0755);
  const SignedLinuxManifest signed_manifest =
      WriteSignedLinuxStageControl(staging_root);
  const fs::path manifest_path =
      staging_root / ".desktop_updater_release_manifest.json";
  InstallRequest request = RequestFor(
      install_root, staging_root, true, Sha256File(manifest_path),
      Sha256File(staging_root / ".desktop_updater_artifact.zip"));
  request.executable_relative_path = executable.filename().string();
  WriteFile(helper.parent_path() / "desktop-updater-helper.policy.json",
            CanonicalPortablePolicy(Sha256File(executable),
                                    Sha256File(helper),
                                    signed_manifest.public_key_base64),
            0600);

  rollback_exit.Set("1");
  InstallReservation reservation;
  const InstallResult prepared = PrepareInstall(request, &reservation);
  ASSERT_TRUE(prepared.ok) << prepared.error;
  ASSERT_FALSE(reservation.transaction_id.empty());
  const std::string transaction_id = reservation.transaction_id;
  const std::string prefix = "." + install_root.filename().string() +
                             ".desktop-updater-" + transaction_id;
  const fs::path helper_stage = install_root.parent_path() /
      ("desktop_updater_stage_" + transaction_id);
  const fs::path helper_control =
      install_root.parent_path() / (prefix + ".control");
  const fs::path restage_record = install_root.parent_path() /
      (".desktop-updater-restage-" + transaction_id + ".json");
  ASSERT_TRUE(fs::exists(helper_stage));
  ASSERT_TRUE(fs::exists(helper_control));
  ASSERT_FALSE(fs::exists(restage_record));

  const InstallTransactionStatus cancelled = CancelReservation(reservation);
  rollback_exit.Unset();
  EXPECT_EQ(InstallTransactionState::kUnknown, cancelled.state)
      << cancelled.detail;
  EXPECT_EQ(InstallTransactionResultCode::kEndpointUnavailable,
            cancelled.result_code);
  EXPECT_TRUE(fs::exists(helper_stage));
  EXPECT_TRUE(fs::exists(helper_control));
  EXPECT_FALSE(fs::exists(restage_record));

  const auto registered = runtime::internal::ParseJson(ReadFile(
      state_directory.path() / "desktop-updater" / "transactions" /
      (transaction_id + ".json")));
  EXPECT_EQ("rolledBack", registered.at("state").string());
  const InstallTransactionStatus recovered =
      RecoverPendingInstall(transaction_id);
  EXPECT_EQ(InstallTransactionState::kRolledBack, recovered.state)
      << recovered.detail;
  EXPECT_EQ(InstallTransactionResultCode::kSucceeded,
            recovered.result_code);
  EXPECT_FALSE(fs::exists(helper_stage));
  EXPECT_FALSE(fs::exists(helper_control));
  EXPECT_FALSE(fs::exists(restage_record));
  EXPECT_TRUE(fs::exists(staging_root));
  EXPECT_EQ("new", ReadFile(staging_root / executable.filename()));
  EXPECT_EQ("{\"packageId\":\"com.example.app\",\"schemaVersion\":1}",
            ReadFile(installed_identity));
  EXPECT_TRUE(fs::exists(executable));

  fs::remove(installed_identity, cleanup_error);
  fs::remove_all(staging_root, cleanup_error);
}

TEST(LinuxNativeInstall,
     PublicHelperIgnoresCallerInventedFileAndUsesSignedZip) {
  if (geteuid() == 0) {
    GTEST_SKIP() << "portable helper handoff requires a non-root test user";
  }
  const fs::path executable = fs::canonical("/proc/self/exe");
  const fs::path install_root = executable.parent_path();
  const fs::path helper = install_root / "desktop-updater-helper";
  if (!fs::exists(helper)) {
    GTEST_SKIP() << "desktop-updater-helper target is unavailable";
  }
  const std::string nonce = "123e4567-e89b-42d3-a456-426614174000";
  const fs::path staging_root =
      install_root.parent_path() / ("desktop_updater_stage_" + nonce);
  const fs::path installed_identity =
      install_root / ".desktop_updater_install_identity.json";
  TemporaryDirectory runtime_directory(true);
  TemporaryDirectory state_directory(true);
  ASSERT_EQ(chmod(runtime_directory.path().c_str(), 0700), 0);
  ASSERT_EQ(chmod(state_directory.path().c_str(), 0700), 0);
  const char* old_runtime = std::getenv("XDG_RUNTIME_DIR");
  const std::string saved_runtime = old_runtime == nullptr ? "" : old_runtime;
  const char* old_state = std::getenv("XDG_STATE_HOME");
  const std::string saved_state = old_state == nullptr ? "" : old_state;
  ASSERT_EQ(setenv("XDG_RUNTIME_DIR", runtime_directory.path().c_str(), 1), 0);
  ASSERT_EQ(setenv("XDG_STATE_HOME", state_directory.path().c_str(), 1), 0);

  std::error_code cleanup_error;
  fs::remove_all(staging_root, cleanup_error);
  WriteFile(staging_root / executable.filename(), "new", 0755);
  const SignedLinuxManifest signed_manifest =
      WriteSignedLinuxStageControl(staging_root);
  WriteFile(staging_root / "libcaller_injected.so", "injected", 0755);
  const fs::path manifest_path =
      staging_root / ".desktop_updater_release_manifest.json";
  const std::string descriptor_sha256 = Sha256File(manifest_path);
  const std::string artifact_sha256 =
      Sha256File(staging_root / ".desktop_updater_artifact.zip");
  InstallRequest request = RequestFor(install_root, staging_root, true,
                                      descriptor_sha256, artifact_sha256);
  request.executable_relative_path = executable.filename().string();
  WriteFile(helper.parent_path() / "desktop-updater-helper.policy.json",
            CanonicalPortablePolicy(Sha256File(executable),
                                    Sha256File(helper),
                                    signed_manifest.public_key_base64),
            0600);

  InstallReservation reservation;
  const InstallResult prepared = PrepareInstall(request, &reservation);
  EXPECT_TRUE(prepared.ok) << prepared.error;
  if (prepared.ok) {
    const fs::path helper_stage =
        install_root.parent_path() /
        ("desktop_updater_stage_" + reservation.transaction_id);
    const fs::path helper_control = install_root.parent_path() /
        ("." + install_root.filename().string() + ".desktop-updater-" +
         reservation.transaction_id + ".control");
    EXPECT_TRUE(fs::exists(helper_stage / executable.filename()));
    EXPECT_FALSE(fs::exists(helper_stage / "libcaller_injected.so"));
    for (const char* control_name : {
             ".desktop_updater_artifact.zip",
             ".desktop_updater_release_manifest.json",
             ".desktop_updater_stage_provenance.json",
             ".desktop_updater_payload_seal.json"}) {
      EXPECT_FALSE(fs::exists(helper_stage / control_name)) << control_name;
    }
    EXPECT_TRUE(fs::exists(helper_control));
    const InstallTransactionStatus cancelled = CancelReservation(reservation);
    EXPECT_EQ(InstallTransactionState::kCancelled, cancelled.state)
        << cancelled.detail;
    EXPECT_FALSE(fs::exists(helper_stage));
    EXPECT_FALSE(fs::exists(helper_control));
    EXPECT_TRUE(fs::exists(staging_root / "libcaller_injected.so"));
  }

  fs::remove(installed_identity, cleanup_error);
  fs::remove_all(staging_root, cleanup_error);
  if (old_runtime == nullptr) {
    unsetenv("XDG_RUNTIME_DIR");
  } else {
    setenv("XDG_RUNTIME_DIR", saved_runtime.c_str(), 1);
  }
  if (old_state == nullptr) {
    unsetenv("XDG_STATE_HOME");
  } else {
    setenv("XDG_STATE_HOME", saved_state.c_str(), 1);
  }
}

TEST(LinuxNativeInstall,
     PublicCommitMutatesAfterCallerExitAndQueriesDurableState) {
  if (geteuid() == 0) {
    GTEST_SKIP() << "portable helper handoff requires a non-root test user";
  }
  const fs::path fixture_source =
      fs::canonical(DESKTOP_UPDATER_COMMIT_CALLER_FIXTURE);
  const fs::path helper = fs::canonical(
      fs::path("/proc/self/exe")).parent_path() / "desktop-updater-helper";
  ASSERT_TRUE(fs::exists(helper));
  TemporaryDirectory temporary;
  TemporaryDirectory runtime_directory(true);
  TemporaryDirectory state_directory(true);
  ASSERT_EQ(chmod(runtime_directory.path().c_str(), 0700), 0);
  ASSERT_EQ(chmod(state_directory.path().c_str(), 0700), 0);
  const char* old_runtime = std::getenv("XDG_RUNTIME_DIR");
  const std::string saved_runtime = old_runtime == nullptr ? "" : old_runtime;
  const char* old_state = std::getenv("XDG_STATE_HOME");
  const std::string saved_state = old_state == nullptr ? "" : old_state;
  ASSERT_EQ(setenv("XDG_RUNTIME_DIR", runtime_directory.path().c_str(), 1), 0);
  ASSERT_EQ(setenv("XDG_STATE_HOME", state_directory.path().c_str(), 1), 0);
  const fs::path install_root = temporary.path() / "Example.AppDir";
  const std::string nonce = "123e4567-e89b-42d3-a456-426614174000";
  const fs::path staging_root =
      temporary.path() / ("desktop_updater_stage_" + nonce);
  const fs::path result_path = temporary.path() / "commit-result.txt";
  const fs::path query_result_path = temporary.path() / "query-result.txt";
  const fs::path relaunch_proof = temporary.path() / "relaunch-proof.txt";
  fs::create_directories(install_root);
  fs::create_directories(staging_root);
  ASSERT_TRUE(fs::copy_file(
      fixture_source, install_root / "linux_commit_caller_fixture"));
  ASSERT_TRUE(fs::copy_file(
      fixture_source, staging_root / "linux_commit_caller_fixture"));
  ASSERT_TRUE(fs::copy_file(helper,
                            install_root / "desktop-updater-helper"));
  ASSERT_TRUE(fs::copy_file(helper,
                            staging_root / "desktop-updater-helper"));
  ASSERT_EQ(0, chmod((install_root / "linux_commit_caller_fixture").c_str(),
                     0755));
  ASSERT_EQ(0, chmod((staging_root / "linux_commit_caller_fixture").c_str(),
                     0755));
  ASSERT_EQ(0, chmod((install_root / "desktop-updater-helper").c_str(),
                     0755));
  ASSERT_EQ(0, chmod((staging_root / "desktop-updater-helper").c_str(),
                     0755));
  WriteFile(install_root / "version.txt", "old");
  WriteFile(staging_root / "version.txt", "new");
  WriteFile(staging_root / ".desktop_updater_install_identity.json",
            "{\"packageId\":\"com.example.app\",\"schemaVersion\":1}");
  const SignedLinuxManifest signing_material = CanonicalSignedLinuxManifest();
  const std::string portable_policy = CanonicalPortablePolicy(
      Sha256File(install_root / "linux_commit_caller_fixture"),
      Sha256File(helper), signing_material.public_key_base64);
  WriteFile(install_root / "desktop-updater-helper.policy.json",
            portable_policy, 0600);
  WriteFile(staging_root / "desktop-updater-helper.policy.json",
            portable_policy, 0600);
  const SignedLinuxManifest signed_manifest =
      WriteSignedLinuxStageControl(staging_root);
  const fs::path manifest_path =
      staging_root / ".desktop_updater_release_manifest.json";
  const InstallRequest staged_request = RequestFor(
      install_root, staging_root, true, Sha256File(manifest_path),
      Sha256File(staging_root / ".desktop_updater_artifact.zip"));
  WriteFile(helper.parent_path() / "desktop-updater-helper.policy.json",
            portable_policy, 0600);

  const pid_t caller = fork();
  ASSERT_GE(caller, 0);
  if (caller == 0) {
    setenv("DESKTOP_UPDATER_TEST_PROVENANCE_SHA256",
           staged_request.expected_provenance_sha256.c_str(), 1);
    setenv("DESKTOP_UPDATER_TEST_RELAUNCH_PROOF",
           relaunch_proof.c_str(), 1);
    setenv("DESKTOP_UPDATER_ROOT_SECRET", "must-not-cross-exec", 1);
    execl((install_root / "linux_commit_caller_fixture").c_str(),
          "linux_commit_caller_fixture", install_root.c_str(),
          staging_root.c_str(), helper.c_str(), result_path.c_str(), nullptr);
    _exit(127);
  }
  int caller_status = 0;
  ASSERT_EQ(caller, waitpid(caller, &caller_status, 0));
  ASSERT_TRUE(WIFEXITED(caller_status));
  if (WEXITSTATUS(caller_status) != 0) {
    std::ifstream failure(result_path);
    FAIL() << "caller exit=" << WEXITSTATUS(caller_status) << "\n"
           << std::string(std::istreambuf_iterator<char>(failure),
                          std::istreambuf_iterator<char>());
  }

  bool activated = false;
  for (int attempt = 0; attempt < 200; ++attempt) {
    std::ifstream version(install_root / "version.txt", std::ios::binary);
    const std::string observed((std::istreambuf_iterator<char>(version)),
                               std::istreambuf_iterator<char>());
    if (observed == "new") {
      activated = true;
      break;
    }
    usleep(25'000);
  }
  EXPECT_TRUE(activated);
  EXPECT_TRUE(fs::exists(staging_root));
  const std::string transaction_id = TransactionIdFromResult(result_path);
  ASSERT_FALSE(transaction_id.empty()) << ReadFile(result_path);
  const fs::path control = temporary.path() /
      ("." + install_root.filename().string() + ".desktop-updater-" +
       transaction_id + ".control");
  for (const char* control_name : {
           ".desktop_updater_artifact.zip",
           ".desktop_updater_release_manifest.json",
           ".desktop_updater_stage_provenance.json",
           ".desktop_updater_payload_seal.json"}) {
    EXPECT_FALSE(fs::exists(install_root / control_name)) << control_name;
  }
  bool queried_completed = false;
  std::string last_query;
  for (int attempt = 0; attempt < 40 && !queried_completed; ++attempt) {
    std::error_code ignored;
    fs::remove(query_result_path, ignored);
    const int query_status = RunControlFixture(
        install_root / "linux_commit_caller_fixture", "--query",
        transaction_id, query_result_path);
    last_query = ReadFile(query_result_path);
    queried_completed =
        query_status == 0 &&
        last_query.find("code\n" +
                        std::to_string(static_cast<unsigned int>(
                            InstallTransactionResultCode::kSucceeded)) +
                        "\n") != std::string::npos;
    if (!queried_completed) usleep(25'000);
  }
  EXPECT_TRUE(queried_completed) << last_query;
  bool relaunched = false;
  for (int attempt = 0; attempt < 200; ++attempt) {
    if (fs::exists(relaunch_proof)) {
      relaunched = true;
      break;
    }
    usleep(25'000);
  }
  ASSERT_TRUE(relaunched);
  const std::string proof = ReadFile(relaunch_proof);
  EXPECT_NE(std::string::npos,
            proof.find("uid=" + std::to_string(geteuid()) + "\n"));
  EXPECT_NE(std::string::npos,
            proof.find("euid=" + std::to_string(geteuid()) + "\n"));
  EXPECT_NE(std::string::npos,
            proof.find("gid=" + std::to_string(getegid()) + "\n"));
  EXPECT_NE(std::string::npos, proof.find("secret=absent\n"));
  struct stat activated_root {};
  ASSERT_EQ(0, stat(install_root.c_str(), &activated_root));
  EXPECT_EQ(0755, activated_root.st_mode & 0777);
  EXPECT_FALSE(fs::exists(control));
  const std::string events = ReadFile(
      state_directory.path() / "desktop-updater" / "transactions" /
      "events.jsonl");
  for (const char* event : {"helper authenticated", "target lock acquired",
                            "transaction journal persisted",
                            "caller exit observed", "activation verified",
                            "transaction completed"}) {
    EXPECT_NE(std::string::npos, events.find(event)) << event << "\n" << events;
  }
  EXPECT_EQ(std::string::npos, events.find(nonce));
  EXPECT_EQ(std::string::npos, events.find(install_root.string()));
  EXPECT_EQ(std::string::npos, events.find("readyToken"));
  if (old_runtime == nullptr) {
    unsetenv("XDG_RUNTIME_DIR");
  } else {
    setenv("XDG_RUNTIME_DIR", saved_runtime.c_str(), 1);
  }
  if (old_state == nullptr) {
    unsetenv("XDG_STATE_HOME");
  } else {
    setenv("XDG_STATE_HOME", saved_state.c_str(), 1);
  }
}

TEST(LinuxNativeInstall,
     PublicRecoveryNeverRetriesClaimedRelaunchAttempt) {
  if (geteuid() == 0) {
    GTEST_SKIP() << "portable helper handoff requires a non-root test user";
  }
  const fs::path fixture_source =
      fs::canonical(DESKTOP_UPDATER_COMMIT_CALLER_FIXTURE);
  const fs::path helper = fs::canonical(
      fs::path("/proc/self/exe")).parent_path() / "desktop-updater-helper";
  ASSERT_TRUE(fs::exists(helper));
  TemporaryDirectory temporary;
  TemporaryDirectory runtime_directory(true);
  TemporaryDirectory state_directory(true);
  ASSERT_EQ(0, chmod(runtime_directory.path().c_str(), 0700));
  ASSERT_EQ(0, chmod(state_directory.path().c_str(), 0700));
  ScopedEnvironmentVariable runtime_environment("XDG_RUNTIME_DIR");
  ScopedEnvironmentVariable state_environment("XDG_STATE_HOME");
  runtime_environment.Set(runtime_directory.path().c_str());
  state_environment.Set(state_directory.path().c_str());

  const fs::path install_root = temporary.path() / "Example.AttemptDir";
  const std::string nonce = "123e4567-e89b-42d3-a456-426614174000";
  const fs::path staging_root =
      temporary.path() / ("desktop_updater_stage_" + nonce);
  const fs::path commit_result = temporary.path() / "attempt-commit.txt";
  const fs::path query_result = temporary.path() / "attempt-query.txt";
  const fs::path recovery_result = temporary.path() / "attempt-recovery.txt";
  const fs::path relaunch_proof = temporary.path() / "attempt-relaunch.txt";
  fs::create_directories(install_root);
  fs::create_directories(staging_root);
  for (const fs::path& root : {install_root, staging_root}) {
    ASSERT_TRUE(fs::copy_file(
        fixture_source, root / "linux_commit_caller_fixture"));
    ASSERT_TRUE(fs::copy_file(helper, root / "desktop-updater-helper"));
    ASSERT_EQ(0, chmod((root / "linux_commit_caller_fixture").c_str(), 0755));
    ASSERT_EQ(0, chmod((root / "desktop-updater-helper").c_str(), 0755));
  }
  WriteFile(install_root / "version.txt", "old");
  WriteFile(staging_root / "version.txt", "new");
  WriteFile(staging_root / ".desktop_updater_install_identity.json",
            "{\"packageId\":\"com.example.app\",\"schemaVersion\":1}");
  const SignedLinuxManifest signing_material = CanonicalSignedLinuxManifest();
  const std::string portable_policy = CanonicalPortablePolicy(
      Sha256File(install_root / "linux_commit_caller_fixture"),
      Sha256File(helper), signing_material.public_key_base64);
  WriteFile(install_root / "desktop-updater-helper.policy.json",
            portable_policy, 0600);
  WriteFile(staging_root / "desktop-updater-helper.policy.json",
            portable_policy, 0600);
  WriteFile(helper.parent_path() / "desktop-updater-helper.policy.json",
            portable_policy, 0600);
  (void)WriteSignedLinuxStageControl(staging_root);
  const fs::path manifest_path =
      staging_root / ".desktop_updater_release_manifest.json";
  const InstallRequest staged_request = RequestFor(
      install_root, staging_root, true, Sha256File(manifest_path),
      Sha256File(staging_root / ".desktop_updater_artifact.zip"));

  const pid_t caller = fork();
  ASSERT_GE(caller, 0);
  if (caller == 0) {
    setenv("DESKTOP_UPDATER_TEST_PROVENANCE_SHA256",
           staged_request.expected_provenance_sha256.c_str(), 1);
    setenv("DESKTOP_UPDATER_TEST_RELAUNCH_PROOF",
           relaunch_proof.c_str(), 1);
    setenv("DESKTOP_UPDATER_TEST_EXIT_AFTER_RELAUNCH_ATTEMPTING", "1", 1);
    execl((install_root / "linux_commit_caller_fixture").c_str(),
          "linux_commit_caller_fixture", install_root.c_str(),
          staging_root.c_str(), helper.c_str(), commit_result.c_str(), nullptr);
    _exit(127);
  }
  int caller_status = 0;
  ASSERT_EQ(caller, waitpid(caller, &caller_status, 0));
  ASSERT_TRUE(WIFEXITED(caller_status));
  ASSERT_EQ(0, WEXITSTATUS(caller_status)) << ReadFile(commit_result);
  const std::string transaction_id = TransactionIdFromResult(commit_result);
  ASSERT_FALSE(transaction_id.empty()) << ReadFile(commit_result);

  bool durable_failure = false;
  std::string last_query;
  for (int attempt = 0; attempt < 200 && !durable_failure; ++attempt) {
    std::error_code ignored;
    fs::remove(query_result, ignored);
    (void)RunControlFixture(
        install_root / "linux_commit_caller_fixture", "--query",
        transaction_id, query_result);
    last_query = ReadFile(query_result);
    durable_failure =
        last_query.find("state\n" +
                        std::to_string(static_cast<unsigned int>(
                            InstallTransactionState::kCompleted)) +
                        "\n") != std::string::npos &&
        last_query.find("code\n" +
                        std::to_string(static_cast<unsigned int>(
                            InstallTransactionResultCode::kRelaunchFailure)) +
                        "\n") != std::string::npos;
    if (!durable_failure) usleep(10'000);
  }
  ASSERT_TRUE(durable_failure) << last_query;
  EXPECT_EQ("new", ReadFile(install_root / "version.txt"));
  EXPECT_FALSE(fs::exists(relaunch_proof));

  for (int recovery_attempt = 0; recovery_attempt != 2;
       ++recovery_attempt) {
    EXPECT_EQ(0, RunControlFixture(
                     install_root / "linux_commit_caller_fixture", "--recover",
                     transaction_id, recovery_result))
        << ReadFile(recovery_result);
    const std::string recovered = ReadFile(recovery_result);
    EXPECT_NE(std::string::npos,
              recovered.find("state\n" +
                             std::to_string(static_cast<unsigned int>(
                                 InstallTransactionState::kCompleted)) +
                             "\n"));
    EXPECT_NE(std::string::npos,
              recovered.find("code\n" +
                             std::to_string(static_cast<unsigned int>(
                                 InstallTransactionResultCode::
                                     kRelaunchFailure)) +
                             "\n"));
    EXPECT_FALSE(fs::exists(relaunch_proof));
  }
}

TEST(LinuxNativeInstall,
     VersionTwoUsesTransactionScopedVersionOneAuthorityForRecovery) {
  if (geteuid() == 0) {
    GTEST_SKIP() << "portable helper handoff requires a non-root test user";
  }
  const fs::path caller_v1 =
      fs::canonical(DESKTOP_UPDATER_COMMIT_CALLER_FIXTURE);
  const fs::path helper_v1 =
      fs::canonical(fs::path("/proc/self/exe")).parent_path() /
      "desktop-updater-helper";
  ASSERT_TRUE(fs::exists(helper_v1));

  TemporaryDirectory temporary;
  TemporaryDirectory runtime_directory(true);
  TemporaryDirectory state_directory(true);
  ASSERT_EQ(0, chmod(runtime_directory.path().c_str(), 0700));
  ASSERT_EQ(0, chmod(state_directory.path().c_str(), 0700));
  ScopedEnvironmentVariable runtime_environment("XDG_RUNTIME_DIR");
  ScopedEnvironmentVariable state_environment("XDG_STATE_HOME");
  runtime_environment.Set(runtime_directory.path().c_str());
  state_environment.Set(state_directory.path().c_str());

  const fs::path install_root = temporary.path() / "Example.GenerationDir";
  const std::string nonce = "123e4567-e89b-42d3-a456-426614174000";
  const fs::path staging_root =
      temporary.path() / ("desktop_updater_stage_" + nonce);
  const fs::path commit_result = temporary.path() / "generation-commit.txt";
  const fs::path query_result = temporary.path() / "generation-query.txt";
  const fs::path recovery_result =
      temporary.path() / "generation-recovery.txt";
  fs::create_directories(install_root);
  fs::create_directories(staging_root);
  ASSERT_TRUE(fs::copy_file(caller_v1,
                            install_root / "linux_commit_caller_fixture"));
  ASSERT_TRUE(fs::copy_file(helper_v1,
                            install_root / "desktop-updater-helper"));
  ASSERT_TRUE(fs::copy_file(caller_v1,
                            staging_root / "linux_commit_caller_fixture"));
  ASSERT_TRUE(fs::copy_file(helper_v1,
                            staging_root / "desktop-updater-helper"));
  AppendByte(staging_root / "linux_commit_caller_fixture", '\0');
  AppendByte(staging_root / "desktop-updater-helper", '\0');
  for (const fs::path& root : {install_root, staging_root}) {
    ASSERT_EQ(0, chmod((root / "linux_commit_caller_fixture").c_str(), 0755));
    ASSERT_EQ(0, chmod((root / "desktop-updater-helper").c_str(), 0755));
  }
  WriteFile(install_root / "version.txt", "v1");
  WriteFile(staging_root / "version.txt", "v2");
  const std::string installed_identity =
      "{\"packageId\":\"com.example.app\",\"schemaVersion\":1}";
  WriteFile(install_root / ".desktop_updater_install_identity.json",
            installed_identity);
  WriteFile(staging_root / ".desktop_updater_install_identity.json",
            installed_identity);

  const SignedLinuxManifest signing_material = CanonicalSignedLinuxManifest();
  const std::string policy_v1 = CanonicalPortablePolicy(
      Sha256File(install_root / "linux_commit_caller_fixture"),
      Sha256File(install_root / "desktop-updater-helper"),
      signing_material.public_key_base64);
  const std::string policy_v2 = CanonicalPortablePolicy(
      Sha256File(staging_root / "linux_commit_caller_fixture"),
      Sha256File(staging_root / "desktop-updater-helper"),
      signing_material.public_key_base64);
  ASSERT_NE(policy_v1, policy_v2);
  WriteFile(install_root / "desktop-updater-helper.policy.json", policy_v1,
            0600);
  WriteFile(staging_root / "desktop-updater-helper.policy.json", policy_v2,
            0600);
  (void)WriteSignedLinuxStageControl(staging_root);
  const InstallRequest staged_request = RequestFor(
      install_root, staging_root, true,
      Sha256File(staging_root / ".desktop_updater_release_manifest.json"),
      Sha256File(staging_root / ".desktop_updater_artifact.zip"));

  const pid_t caller = fork();
  ASSERT_GE(caller, 0);
  if (caller == 0) {
    setenv("DESKTOP_UPDATER_TEST_PROVENANCE_SHA256",
           staged_request.expected_provenance_sha256.c_str(), 1);
    setenv("DESKTOP_UPDATER_TEST_EXIT_AFTER_RELAUNCH_PENDING", "1", 1);
    execl((install_root / "linux_commit_caller_fixture").c_str(),
          "linux_commit_caller_fixture", install_root.c_str(),
          staging_root.c_str(), helper_v1.c_str(), commit_result.c_str(),
          nullptr);
    _exit(127);
  }
  int caller_status = 0;
  ASSERT_EQ(caller, waitpid(caller, &caller_status, 0));
  ASSERT_TRUE(WIFEXITED(caller_status));
  ASSERT_EQ(0, WEXITSTATUS(caller_status)) << ReadFile(commit_result);
  const std::string transaction_id = TransactionIdFromResult(commit_result);
  ASSERT_FALSE(transaction_id.empty()) << ReadFile(commit_result);

  bool activated_v2 = false;
  for (int attempt = 0; attempt < 400; ++attempt) {
    if (fs::exists(install_root / "version.txt") &&
        ReadFile(install_root / "version.txt") == "v2") {
      activated_v2 = true;
      break;
    }
    usleep(10'000);
  }
  ASSERT_TRUE(activated_v2);
  ASSERT_NE(Sha256File(install_root / "desktop-updater-helper"),
            Sha256File(helper_v1));

  EXPECT_NE(0, RunControlFixture(
                   install_root / "linux_commit_caller_fixture", "--query",
                   transaction_id, query_result));
  EXPECT_NE(std::string::npos, ReadFile(query_result).find("state\n1\n"))
      << ReadFile(query_result);

  EXPECT_EQ(0, RunControlFixture(
                   install_root / "linux_commit_caller_fixture", "--recover",
                   transaction_id, recovery_result))
      << ReadFile(recovery_result);
  EXPECT_NE(std::string::npos,
            ReadFile(recovery_result).find(
                "state\n" +
                std::to_string(static_cast<unsigned int>(
                    InstallTransactionState::kCompleted)) +
                "\n"))
      << ReadFile(recovery_result);
  EXPECT_NE(std::string::npos,
            ReadFile(recovery_result).find(
                "code\n" +
                std::to_string(static_cast<unsigned int>(
                    InstallTransactionResultCode::kRelaunchFailure)) +
                "\n"))
      << ReadFile(recovery_result);

  const fs::path authority =
      state_directory.path() / "desktop-updater" / "transactions" /
      (transaction_id + ".authority");
  EXPECT_EQ(Sha256File(helper_v1),
            Sha256File(authority / "desktop-updater-helper"));
  EXPECT_EQ(policy_v1,
            ReadFile(authority / "desktop-updater-helper.policy.json"));
}

TEST(LinuxNativeInstall, PublicRecoverConvergesAfterKilledCommitHelper) {
  if (geteuid() == 0) {
    GTEST_SKIP() << "portable helper handoff requires a non-root test user";
  }
  const fs::path fixture_source =
      fs::canonical(DESKTOP_UPDATER_COMMIT_CALLER_FIXTURE);
  const fs::path helper = fs::canonical(fs::path("/proc/self/exe"))
                              .parent_path() /
                          "desktop-updater-helper";
  ASSERT_TRUE(fs::exists(helper));
  TemporaryDirectory temporary;
  TemporaryDirectory runtime_directory(true);
  TemporaryDirectory state_directory(true);
  ASSERT_EQ(0, chmod(runtime_directory.path().c_str(), 0700));
  ASSERT_EQ(0, chmod(state_directory.path().c_str(), 0700));
  const char* old_runtime = std::getenv("XDG_RUNTIME_DIR");
  const char* old_state = std::getenv("XDG_STATE_HOME");
  const std::string saved_runtime = old_runtime == nullptr ? "" : old_runtime;
  const std::string saved_state = old_state == nullptr ? "" : old_state;
  ASSERT_EQ(0, setenv("XDG_RUNTIME_DIR", runtime_directory.path().c_str(), 1));
  ASSERT_EQ(0, setenv("XDG_STATE_HOME", state_directory.path().c_str(), 1));

  const fs::path install_root = temporary.path() / "Example.RecoveryDir";
  const std::string nonce = "123e4567-e89b-42d3-a456-426614174000";
  const fs::path staging_root =
      temporary.path() / ("desktop_updater_stage_" + nonce);
  const fs::path commit_result = temporary.path() / "crash-commit.txt";
  const fs::path query_result = temporary.path() / "crash-query.txt";
  const fs::path recovery_result = temporary.path() / "crash-recovery.txt";
  fs::create_directories(install_root);
  fs::create_directories(staging_root);
  for (const fs::path& root : {install_root, staging_root}) {
    ASSERT_TRUE(fs::copy_file(
        fixture_source, root / "linux_commit_caller_fixture"));
    ASSERT_TRUE(fs::copy_file(helper, root / "desktop-updater-helper"));
    ASSERT_EQ(0, chmod((root / "linux_commit_caller_fixture").c_str(), 0755));
    ASSERT_EQ(0, chmod((root / "desktop-updater-helper").c_str(), 0755));
  }
  WriteFile(install_root / "version.txt", "old");
  WriteFile(staging_root / "version.txt", "new");
  WriteFile(staging_root / ".desktop_updater_install_identity.json",
            "{\"packageId\":\"com.example.app\",\"schemaVersion\":1}");
  {
    std::ofstream large(staging_root / "large-payload.bin",
                        std::ios::binary | std::ios::trunc);
    large.seekp(32 * 1024 * 1024 - 1);
    large.put('\0');
    ASSERT_TRUE(large.good());
  }
  const SignedLinuxManifest signing_material = CanonicalSignedLinuxManifest();
  const std::string portable_policy = CanonicalPortablePolicy(
      Sha256File(install_root / "linux_commit_caller_fixture"),
      Sha256File(helper), signing_material.public_key_base64);
  WriteFile(install_root / "desktop-updater-helper.policy.json",
            portable_policy, 0600);
  WriteFile(staging_root / "desktop-updater-helper.policy.json",
            portable_policy, 0600);
  WriteFile(helper.parent_path() / "desktop-updater-helper.policy.json",
            portable_policy, 0600);
  const SignedLinuxManifest signed_manifest =
      WriteSignedLinuxStageControl(staging_root);
  const fs::path manifest_path =
      staging_root / ".desktop_updater_release_manifest.json";
  const InstallRequest staged_request = RequestFor(
      install_root, staging_root, true, Sha256File(manifest_path),
      Sha256File(staging_root / ".desktop_updater_artifact.zip"));

  ScopedEnvironmentVariable stop_after_backup(
      "DESKTOP_UPDATER_TEST_STOP_AFTER_BACKUP_RENAME");
  stop_after_backup.Set("1");
  const pid_t caller = fork();
  ASSERT_GE(caller, 0);
  if (caller == 0) {
    setenv("DESKTOP_UPDATER_TEST_PROVENANCE_SHA256",
           staged_request.expected_provenance_sha256.c_str(), 1);
    execl((install_root / "linux_commit_caller_fixture").c_str(),
          "linux_commit_caller_fixture", install_root.c_str(),
          staging_root.c_str(), helper.c_str(), commit_result.c_str(), nullptr);
    _exit(127);
  }
  int caller_status = 0;
  ASSERT_EQ(caller, waitpid(caller, &caller_status, 0));
  ASSERT_TRUE(WIFEXITED(caller_status));
  ASSERT_EQ(0, WEXITSTATUS(caller_status)) << ReadFile(commit_result);
  const std::string transaction_id =
      TransactionIdFromResult(commit_result);
  ASSERT_FALSE(transaction_id.empty()) << ReadFile(commit_result);
  const std::string prefix = "." + install_root.filename().string() +
                             ".desktop-updater-" + transaction_id;
  const fs::path prepared = temporary.path() / (prefix + ".prepared");
  const fs::path journal = temporary.path() / (prefix + ".journal.json");

  pid_t helper_pid = -1;
  std::uint64_t helper_start = 0;
  for (int attempt = 0; attempt < 10'000; ++attempt) {
    if (fs::exists(prepared) && fs::exists(journal)) {
      const auto encoded = runtime::internal::ParseJson(ReadFile(journal));
      helper_pid = static_cast<pid_t>(
          encoded.at("ownerProcessId").integer());
      helper_start = static_cast<std::uint64_t>(
          encoded.at("ownerProcessStartIdentity").integer());
      break;
    }
    usleep(1'000);
  }
  ASSERT_GT(helper_pid, 0) << "prepared transaction was not observable";
  stop_after_backup.Unset();
  ASSERT_EQ(helper_start,
            helper::LinuxProcessStartIdentity(helper_pid));
  ASSERT_EQ(Sha256File(helper),
            Sha256File(fs::path("/proc") / std::to_string(helper_pid) /
                       "exe"));
  ASSERT_EQ(0, kill(helper_pid, SIGKILL));
  int killed_helper_status = 0;
  const pid_t reaped_helper =
      waitpid(helper_pid, &killed_helper_status, 0);
  if (reaped_helper == helper_pid) {
    ASSERT_TRUE(WIFSIGNALED(killed_helper_status));
    ASSERT_EQ(SIGKILL, WTERMSIG(killed_helper_status));
  } else {
    ASSERT_EQ(ECHILD, errno);
    // The helper is a child of the short-lived caller fixture, so Docker PID 1
    // may retain it briefly as a zombie. pidfd liveness in production treats
    // that exited process as dead; this test process cannot reap a grandchild.
  }

  const int query_exit = RunControlFixture(
      install_root / "linux_commit_caller_fixture", "--query",
      transaction_id, query_result);
  EXPECT_NE(0, query_exit);
  EXPECT_NE(std::string::npos, ReadFile(query_result).find("state\n1\n"))
      << ReadFile(query_result);

  const fs::path control = temporary.path() / (prefix + ".control");
  const fs::path restage_record = temporary.path() /
      (".desktop-updater-restage-" + transaction_id + ".json");
  ScopedEnvironmentVariable terminal_recovery_exit(
      "DESKTOP_UPDATER_TEST_EXIT_AFTER_RECOVERY_TERMINAL_REGISTRY");
  terminal_recovery_exit.Set("1");
  const int interrupted_recovery = RunControlFixture(
      install_root / "linux_commit_caller_fixture", "--recover",
      transaction_id, recovery_result);
  terminal_recovery_exit.Unset();
  EXPECT_NE(0, interrupted_recovery) << ReadFile(recovery_result);
  EXPECT_NE(std::string::npos,
            ReadFile(recovery_result).find("state\n0\n"))
      << ReadFile(recovery_result);
  EXPECT_EQ("new", ReadFile(install_root / "version.txt"));
  EXPECT_FALSE(fs::exists(prepared));
  EXPECT_FALSE(fs::exists(journal));
  EXPECT_TRUE(fs::exists(control));
  EXPECT_FALSE(fs::exists(restage_record));

  EXPECT_EQ(0, RunControlFixture(
                   install_root / "linux_commit_caller_fixture", "--recover",
                   transaction_id, recovery_result))
      << ReadFile(recovery_result);
  EXPECT_FALSE(fs::exists(control));
  EXPECT_FALSE(fs::exists(restage_record));
  for (const char* control_name : {
           ".desktop_updater_artifact.zip",
           ".desktop_updater_release_manifest.json",
           ".desktop_updater_stage_provenance.json",
           ".desktop_updater_payload_seal.json"}) {
    EXPECT_FALSE(fs::exists(install_root / control_name)) << control_name;
  }
  struct stat recovered_root {};
  ASSERT_EQ(0, stat(install_root.c_str(), &recovered_root));
  EXPECT_EQ(0755, recovered_root.st_mode & 0777);
  EXPECT_EQ(0, RunControlFixture(
                   install_root / "linux_commit_caller_fixture", "--query",
                   transaction_id, query_result))
      << ReadFile(query_result);

  if (old_runtime == nullptr) {
    unsetenv("XDG_RUNTIME_DIR");
  } else {
    setenv("XDG_RUNTIME_DIR", saved_runtime.c_str(), 1);
  }
  if (old_state == nullptr) {
    unsetenv("XDG_STATE_HOME");
  } else {
    setenv("XDG_STATE_HOME", saved_state.c_str(), 1);
  }
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
