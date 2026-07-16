#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#include "miniz.h"

#include "desktop_updater_native.h"
#include "json_value.h"
#include "monocypher-ed25519.h"
#include "release_contract.h"
#include "unix_socket_transport.h"

namespace {

namespace fs = std::filesystem;
using desktop_updater::runtime::internal::EncodeCanonicalJson;
using desktop_updater::runtime::internal::JsonValue;

constexpr char kPackageId[] = "com.example.desktop-updater.polkit-e2e";
constexpr char kPolicyId[] =
    "com.example.desktop-updater.polkit-e2e.privileged";
constexpr char kReleaseKeyId[] = "polkit-e2e-test-key-1";
constexpr char kExecutableRelativePath[] = "linux_polkit_e2e_fixture";
constexpr char kStagePrefix[] = "desktop_updater_stage_";

[[noreturn]] void Fail(const std::string& detail) {
  throw std::runtime_error(detail);
}

std::string ReadFile(const fs::path& path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) Fail("unable to read " + path.string());
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

void WriteFile(const fs::path& path,
               const std::string& bytes,
               mode_t mode) {
  fs::create_directories(path.parent_path());
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  output.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
  output.close();
  if (!output || chmod(path.c_str(), mode) != 0) {
    Fail("unable to write " + path.string());
  }
}

std::string SelfExecutablePath() {
  std::string result(4096, '\0');
  const ssize_t length = readlink("/proc/self/exe", result.data(), result.size());
  if (length <= 0 || static_cast<std::size_t>(length) == result.size()) {
    Fail("caller executable path is unavailable");
  }
  result.resize(static_cast<std::size_t>(length));
  return result;
}

bool IsLowerSha256(const std::string& value) {
  return value.size() == 64 &&
         std::all_of(value.begin(), value.end(), [](unsigned char byte) {
           return (byte >= '0' && byte <= '9') ||
                  (byte >= 'a' && byte <= 'f');
         });
}

bool IsUuidV4(const std::string& value) {
  if (value.size() != 36 || value[8] != '-' || value[13] != '-' ||
      value[18] != '-' || value[23] != '-' || value[14] != '4' ||
      std::string("89ab").find(value[19]) == std::string::npos) {
    return false;
  }
  for (std::size_t index = 0; index < value.size(); ++index) {
    if (index == 8 || index == 13 || index == 18 || index == 23) continue;
    const unsigned char byte = value[index];
    if (!((byte >= '0' && byte <= '9') ||
          (byte >= 'a' && byte <= 'f'))) {
      return false;
    }
  }
  return true;
}

std::string StageNonce(const fs::path& stage) {
  const std::string leaf = stage.filename().string();
  if (leaf.rfind(kStagePrefix, 0) != 0) {
    Fail("stage leaf must use the owned updater prefix");
  }
  const std::string nonce = leaf.substr(sizeof(kStagePrefix) - 1);
  if (!IsUuidV4(nonce)) Fail("stage nonce must be a lowercase UUID v4");
  return nonce;
}

std::string Base64(const unsigned char* bytes, std::size_t length) {
  static constexpr char alphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string result;
  result.reserve(((length + 2) / 3) * 4);
  for (std::size_t offset = 0; offset < length; offset += 3) {
    const std::uint32_t first = bytes[offset];
    const std::uint32_t second = offset + 1 < length ? bytes[offset + 1] : 0;
    const std::uint32_t third = offset + 2 < length ? bytes[offset + 2] : 0;
    const std::uint32_t value = (first << 16) | (second << 8) | third;
    result.push_back(alphabet[(value >> 18) & 0x3f]);
    result.push_back(alphabet[(value >> 12) & 0x3f]);
    result.push_back(offset + 1 < length ? alphabet[(value >> 6) & 0x3f]
                                         : '=');
    result.push_back(offset + 2 < length ? alphabet[value & 0x3f] : '=');
  }
  return result;
}

struct TestReleaseKey {
  std::array<std::uint8_t, 64> secret{};
  std::array<std::uint8_t, 32> public_key{};
};

TestReleaseKey DeterministicTestReleaseKey() {
  // This key is intentionally deterministic and is compiled only into the
  // target-host test fixture. It must never be used for release artifacts.
  std::array<std::uint8_t, 32> seed{};
  for (std::size_t index = 0; index < seed.size(); ++index) {
    seed[index] = static_cast<std::uint8_t>(index + 1);
  }
  TestReleaseKey key;
  crypto_ed25519_key_pair(key.secret.data(), key.public_key.data(), seed.data());
  return key;
}

struct ZipEntry {
  std::string path;
  std::string bytes;
  std::uint32_t mode;
};

std::uint16_t ReadLittle16(const std::vector<unsigned char>& bytes,
                           std::size_t offset) {
  if (offset + 2 > bytes.size()) Fail("signed ZIP field is truncated");
  return static_cast<std::uint16_t>(bytes[offset]) |
         (static_cast<std::uint16_t>(bytes[offset + 1]) << 8);
}

std::uint32_t ReadLittle32(const std::vector<unsigned char>& bytes,
                           std::size_t offset) {
  if (offset + 4 > bytes.size()) Fail("signed ZIP field is truncated");
  return static_cast<std::uint32_t>(bytes[offset]) |
         (static_cast<std::uint32_t>(bytes[offset + 1]) << 8) |
         (static_cast<std::uint32_t>(bytes[offset + 2]) << 16) |
         (static_cast<std::uint32_t>(bytes[offset + 3]) << 24);
}

void WriteZip(const fs::path& archive_path,
              const std::vector<ZipEntry>& entries) {
  mz_zip_archive archive{};
  if (!mz_zip_writer_init_file(&archive, archive_path.c_str(), 0)) {
    Fail("unable to create signed ZIP fixture");
  }
  for (const auto& entry : entries) {
    if (!mz_zip_writer_add_mem_ex(
            &archive, entry.path.c_str(), entry.bytes.data(),
            entry.bytes.size(), nullptr, 0, MZ_BEST_COMPRESSION, 0, 0)) {
      mz_zip_writer_end(&archive);
      Fail("unable to add signed ZIP fixture entry");
    }
  }
  const bool finalized = mz_zip_writer_finalize_archive(&archive) != 0;
  const bool ended = mz_zip_writer_end(&archive) != 0;
  if (!finalized || !ended) Fail("unable to finalize signed ZIP fixture");

  std::fstream file(archive_path,
                    std::ios::in | std::ios::out | std::ios::binary);
  std::vector<unsigned char> bytes{
      std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
  if (bytes.size() < 22 ||
      ReadLittle32(bytes, bytes.size() - 22) != 0x06054b50U ||
      ReadLittle16(bytes, bytes.size() - 12) != entries.size()) {
    Fail("signed ZIP end record is invalid");
  }
  std::size_t central_offset = ReadLittle32(bytes, bytes.size() - 6);
  for (std::size_t entry_index = 0; entry_index < entries.size(); ++entry_index) {
    if (central_offset + 46 > bytes.size() ||
        ReadLittle32(bytes, central_offset) != 0x02014b50U) {
      Fail("signed ZIP central directory is incomplete");
    }
    const std::uint16_t name_length =
        ReadLittle16(bytes, central_offset + 28);
    const std::uint16_t extra_length =
        ReadLittle16(bytes, central_offset + 30);
    const std::uint16_t comment_length =
        ReadLittle16(bytes, central_offset + 32);
    if (central_offset + 46 + name_length + extra_length + comment_length >
            bytes.size() ||
        std::string(reinterpret_cast<const char*>(bytes.data() +
                                                  central_offset + 46),
                    name_length) != entries[entry_index].path) {
      Fail("signed ZIP central entry binding changed");
    }
    bytes[central_offset + 5] = 3;
    const std::uint32_t attributes = entries[entry_index].mode << 16;
    for (int byte = 0; byte < 4; ++byte) {
      bytes[central_offset + 38 + byte] = static_cast<unsigned char>(
          (attributes >> (byte * 8)) & 0xffU);
    }
    central_offset += 46 + name_length + extra_length + comment_length;
  }
  file.clear();
  file.seekp(0);
  file.write(reinterpret_cast<const char*>(bytes.data()),
             static_cast<std::streamsize>(bytes.size()));
  file.close();
  if (!file || chmod(archive_path.c_str(), 0600) != 0) {
    Fail("unable to seal signed ZIP fixture modes");
  }
}

std::string SignedManifest(const std::string& artifact_sha256,
                           std::int64_t artifact_length,
                           const std::string& version,
                           const std::string& package_id = kPackageId) {
  JsonValue::Object artifact;
  artifact.emplace("kind", JsonValue(std::string("zip")));
  artifact.emplace("length", JsonValue(artifact_length));
  artifact.emplace("sha256", JsonValue(artifact_sha256));
  artifact.emplace("url", JsonValue(std::string("https://example.invalid/e2e.zip")));
  JsonValue::Object install;
  install.emplace("strategy", JsonValue(std::string("wholeDirectoryReplace")));
  JsonValue::Object signature;
  signature.emplace("algorithm", JsonValue(std::string("ed25519")));
  signature.emplace("publicKeyId", JsonValue(std::string(kReleaseKeyId)));
  signature.emplace("value", JsonValue(std::string(86, 'A') + "=="));
  JsonValue::Object minimum_os;
  minimum_os.emplace("linux", JsonValue(std::string("glibc-2.35")));
  JsonValue::Object manifest;
  manifest.emplace("appName", JsonValue(std::string("Polkit E2E Fixture")));
  manifest.emplace("artifact", JsonValue(std::move(artifact)));
  manifest.emplace("buildNumber", JsonValue(std::int64_t{2}));
  manifest.emplace("channel", JsonValue(std::string("test")));
  manifest.emplace("generatedAt",
                   JsonValue(std::string("2026-07-16T00:00:00.000Z")));
  manifest.emplace("install", JsonValue(std::move(install)));
  manifest.emplace("minimumOS", JsonValue(std::move(minimum_os)));
  manifest.emplace("minimumUpdaterVersion", JsonValue(std::string("2.0.0")));
  manifest.emplace("packageId", JsonValue(package_id));
  manifest.emplace("platform", JsonValue(std::string("linux")));
  manifest.emplace("schemaVersion", JsonValue(std::int64_t{3}));
  manifest.emplace("signature", JsonValue(std::move(signature)));
  manifest.emplace("version", JsonValue(version));
  JsonValue encoded(std::move(manifest));
  const auto descriptor = desktop_updater::runtime::internal::
      ParseReleaseDescriptor(EncodeCanonicalJson(encoded));
  const std::string message = desktop_updater::runtime::internal::
      CanonicalSignatureBytes(descriptor);
  const TestReleaseKey key = DeterministicTestReleaseKey();
  std::array<std::uint8_t, 64> signature_bytes{};
  crypto_ed25519_sign(
      signature_bytes.data(), key.secret.data(),
      reinterpret_cast<const std::uint8_t*>(message.data()), message.size());
  encoded.object().at("signature").object().at("value") =
      JsonValue(Base64(signature_bytes.data(), signature_bytes.size()));
  return EncodeCanonicalJson(encoded);
}

JsonValue ProvenanceEntry(const fs::path& stage, const fs::path& path) {
  const fs::path relative = fs::relative(path, stage);
  struct stat status {};
  if (lstat(path.c_str(), &status) != 0 || !S_ISREG(status.st_mode) ||
      S_ISLNK(status.st_mode)) {
    Fail("stage fixture contains a non-regular entry");
  }
  JsonValue::Object entry;
  entry.emplace("kind", JsonValue(std::string("file")));
  entry.emplace("length", JsonValue(static_cast<std::int64_t>(status.st_size)));
  entry.emplace("path", JsonValue(relative.generic_string()));
  entry.emplace("sha256", JsonValue(
      desktop_updater::helper::Sha256LinuxFile(path)));
  return JsonValue(std::move(entry));
}

void PrepareStageForExecutable(const fs::path& stage,
                               const std::string& version,
                               const fs::path& payload_executable,
                               const std::string& executable_relative_path,
                               const std::string& package_id) {
  const std::string nonce = StageNonce(stage);
  if (!stage.is_absolute() || stage.lexically_normal() != stage ||
      version.empty() || package_id.empty() ||
      !payload_executable.is_absolute() ||
      fs::canonical(payload_executable) != payload_executable ||
      executable_relative_path.empty() ||
      fs::path(executable_relative_path).filename() !=
          fs::path(executable_relative_path)) {
    Fail("stage path or version is invalid");
  }
  std::error_code error;
  fs::remove_all(stage, error);
  if (error) Fail("unable to remove previous stage fixture");
  fs::create_directories(stage);
  const fs::path executable = stage / executable_relative_path;
  WriteFile(executable, ReadFile(payload_executable), 0755);
  WriteFile(stage / ".desktop_updater_install_identity.json",
            "{\"packageId\":\"" + package_id +
                "\",\"schemaVersion\":1}",
            0644);
  WriteFile(stage / "version.txt", version, 0644);

  const fs::path archive = stage / ".desktop_updater_artifact.zip";
  std::vector<ZipEntry> payload = {
      {".desktop_updater_install_identity.json",
       ReadFile(stage / ".desktop_updater_install_identity.json"), 0100644},
      {executable_relative_path, ReadFile(executable), 0100755},
      {"version.txt", ReadFile(stage / "version.txt"), 0100644},
  };
  WriteZip(archive, payload);
  const std::string artifact_sha256 =
      desktop_updater::helper::Sha256LinuxFile(archive);
  const fs::path manifest = stage / ".desktop_updater_release_manifest.json";
  WriteFile(manifest,
            SignedManifest(artifact_sha256,
                           static_cast<std::int64_t>(fs::file_size(archive)),
                           version, package_id),
            0644);
  const std::string descriptor_sha256 =
      desktop_updater::helper::Sha256LinuxFile(manifest);

  std::vector<fs::path> inventory;
  for (const auto& entry : fs::recursive_directory_iterator(stage)) {
    if (entry.is_regular_file()) inventory.push_back(entry.path());
  }
  std::sort(inventory.begin(), inventory.end(), [&](const fs::path& first,
                                                    const fs::path& second) {
    return fs::relative(first, stage).generic_string() <
           fs::relative(second, stage).generic_string();
  });
  JsonValue::Array entries;
  for (const fs::path& entry : inventory) {
    entries.emplace_back(ProvenanceEntry(stage, entry));
  }
  JsonValue::Object marker;
  marker.emplace("artifactSha256", JsonValue(artifact_sha256));
  marker.emplace("descriptorSha256", JsonValue(descriptor_sha256));
  marker.emplace("entries", JsonValue(std::move(entries)));
  marker.emplace("nonce", JsonValue(nonce));
  marker.emplace("packageId", JsonValue(package_id));
  marker.emplace("schemaVersion", JsonValue(std::int64_t{1}));
  WriteFile(stage / ".desktop_updater_stage_provenance.json",
            EncodeCanonicalJson(JsonValue(std::move(marker))), 0600);
}

void PrepareStage(const fs::path& stage, const std::string& version) {
  PrepareStageForExecutable(stage, version, fs::path(SelfExecutablePath()),
                            kExecutableRelativePath, kPackageId);
}

std::string CanonicalPolicyForTarget(
    const std::string& caller_sha256,
    const std::string& helper_sha256,
    const std::string& package_id,
    const std::string& policy_id,
    const std::string& helper_service_id,
    const std::string& target_class,
    JsonValue::Array allowed_install_roots) {
  if (!IsLowerSha256(caller_sha256) || !IsLowerSha256(helper_sha256) ||
      package_id.empty() || policy_id.empty() || helper_service_id.empty() ||
      target_class.empty()) {
    Fail("canonical policy inputs are invalid");
  }
  JsonValue::Object caller;
  caller.emplace("kind", JsonValue(std::string("sha256")));
  caller.emplace("value", JsonValue(caller_sha256));
  JsonValue::Object helper;
  helper.emplace("kind", JsonValue(std::string("sha256")));
  helper.emplace("value", JsonValue(helper_sha256));
  const TestReleaseKey key = DeterministicTestReleaseKey();
  JsonValue::Object release_key;
  release_key.emplace("algorithm", JsonValue(std::string("ed25519")));
  release_key.emplace("keyId", JsonValue(std::string(kReleaseKeyId)));
  release_key.emplace(
      "publicKeyBase64",
      JsonValue(Base64(key.public_key.data(), key.public_key.size())));
  JsonValue::Object strategy;
  strategy.emplace("provider", JsonValue(std::string("platformDirectory")));
  strategy.emplace("strategy", JsonValue(std::string("directoryReplace")));
  JsonValue::Object policy;
  policy.emplace("allowedApplicationSigner", JsonValue(std::move(caller)));
  policy.emplace("allowedHelperSigner", JsonValue(std::move(helper)));
  policy.emplace("allowedInstallRoots",
                 JsonValue(std::move(allowed_install_roots)));
  policy.emplace("allowedStrategies",
                 JsonValue(JsonValue::Array{
                     JsonValue(std::move(strategy))}));
  policy.emplace("allowedTargetClasses",
                 JsonValue(JsonValue::Array{JsonValue(target_class)}));
  policy.emplace("applicationPackageId", JsonValue(package_id));
  policy.emplace("helperServiceId", JsonValue(helper_service_id));
  policy.emplace("minimumHelperProtocolVersion", JsonValue(std::int64_t{1}));
  policy.emplace("policyId", JsonValue(policy_id));
  policy.emplace("policyVersion", JsonValue(std::int64_t{1}));
  policy.emplace("releaseRootPublicKeys",
                 JsonValue(JsonValue::Array{
                     JsonValue(std::move(release_key))}));
  return EncodeCanonicalJson(JsonValue(std::move(policy)));
}

std::string CanonicalPolicy(const std::string& caller_sha256,
                            const std::string& helper_sha256,
                            const fs::path& allowed_root) {
  if (!IsLowerSha256(caller_sha256) || !IsLowerSha256(helper_sha256) ||
      !allowed_root.is_absolute() || allowed_root == "/" ||
      allowed_root.lexically_normal() != allowed_root) {
    Fail("canonical policy inputs are invalid");
  }
  return CanonicalPolicyForTarget(
      caller_sha256, helper_sha256, kPackageId, kPolicyId,
      "com.desktopupdater.install", "protectedApplication",
      JsonValue::Array{JsonValue(allowed_root.string())});
}

std::string CanonicalPortableConsumerPolicy(
    const std::string& caller_sha256,
    const std::string& helper_sha256,
    const std::string& package_id) {
  return CanonicalPolicyForTarget(
      caller_sha256, helper_sha256, package_id,
      "com.example.desktop-updater.installed-consumer.portable",
      "com.example.desktop-updater.helper", "sameUserWritable", {});
}

void WriteStatus(const fs::path& output,
                 const desktop_updater::native::InstallTransactionStatus& status) {
  WriteFile(output,
            "transaction=" + status.transaction_id + "\nstate=" +
                std::to_string(static_cast<std::uint32_t>(status.state)) +
                "\ncode=" +
                std::to_string(static_cast<std::uint32_t>(status.result_code)) +
                "\ndetail=" + status.detail + "\n",
            0600);
}

int Install(const fs::path& target,
            const fs::path& stage,
            const fs::path& output) {
  desktop_updater::native::InstallRequest request;
  request.operation = desktop_updater::native::LinuxInstallOperation::kInstall;
  request.staging_path = stage.string();
  request.install_root = target.string();
  request.executable_relative_path = kExecutableRelativePath;
  request.package_id = kPackageId;
  request.expected_provenance_sha256 =
      desktop_updater::helper::Sha256LinuxFile(
          stage / ".desktop_updater_stage_provenance.json");
  desktop_updater::native::InstallReservation reservation;
  const auto prepared =
      desktop_updater::native::PrepareInstall(request, &reservation);
  if (!prepared.ok) {
    WriteFile(output, "prepareError=" + prepared.error + "\n", 0600);
    return 2;
  }
  const auto committed =
      desktop_updater::native::CommitAfterExit(reservation);
  WriteStatus(output, committed);
  return committed.state ==
                     desktop_updater::native::InstallTransactionState::
                         kCommitAccepted &&
                 committed.result_code ==
                     desktop_updater::native::InstallTransactionResultCode::
                         kAccepted
             ? 0
             : 3;
}

int Control(bool recover,
            const std::string& transaction_id,
            const fs::path& output) {
  const auto status = recover
                          ? desktop_updater::native::RecoverPendingInstall(
                                transaction_id)
                          : desktop_updater::native::QueryTransaction(
                                transaction_id);
  WriteStatus(output, status);
  return status.result_code ==
                 desktop_updater::native::InstallTransactionResultCode::
                     kEndpointUnavailable
             ? 5
             : 0;
}

int Run(int argc, char** argv) {
  if (argc == 4 && std::string(argv[1]) == "--prepare-stage") {
    PrepareStage(fs::path(argv[2]), argv[3]);
    return 0;
  }
  if (argc == 7 &&
      std::string(argv[1]) == "--prepare-portable-consumer-stage") {
    PrepareStageForExecutable(fs::path(argv[2]), argv[3],
                              fs::canonical(fs::path(argv[4])), argv[5],
                              argv[6]);
    return 0;
  }
  if (argc == 5 && std::string(argv[1]) == "--canonical-policy") {
    std::cout << CanonicalPolicy(argv[2], argv[3], fs::path(argv[4]));
    return std::cout.good() ? 0 : 1;
  }
  if (argc == 5 &&
      std::string(argv[1]) == "--canonical-portable-consumer-policy") {
    std::cout << CanonicalPortableConsumerPolicy(argv[2], argv[3], argv[4]);
    return std::cout.good() ? 0 : 1;
  }
  if (argc == 5 && std::string(argv[1]) == "--install") {
    return Install(fs::path(argv[2]), fs::path(argv[3]), fs::path(argv[4]));
  }
  if (argc == 4 && std::string(argv[1]) == "--query") {
    return Control(false, argv[2], fs::path(argv[3]));
  }
  if (argc == 4 && std::string(argv[1]) == "--recover") {
    return Control(true, argv[2], fs::path(argv[3]));
  }
  std::cerr << "usage: linux_polkit_e2e_fixture "
               "--prepare-stage STAGE VERSION | "
               "--prepare-portable-consumer-stage STAGE VERSION "
               "EXECUTABLE RELATIVE_PATH PACKAGE_ID | "
               "--canonical-policy CALLER_SHA HELPER_SHA ALLOWED_ROOT | "
               "--canonical-portable-consumer-policy CALLER_SHA "
               "HELPER_SHA PACKAGE_ID | "
               "--install TARGET STAGE RESULT | "
               "--query TRANSACTION RESULT | "
               "--recover TRANSACTION RESULT\n";
  return 64;
}

}  // namespace

int main(int argc, char** argv) {
  try {
    return Run(argc, argv);
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 77;
  }
}
