#include <windows.h>

#include <gtest/gtest.h>

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>

#include "windows_install_authorizer.h"

namespace desktop_updater::helper {
namespace {

constexpr char kIdentityMarkerName[] = ".desktop_updater_install_identity.json";
constexpr char kIdentityMarker[] =
    "{\"packageId\":\"com.example.app\",\"schemaVersion\":1}";
constexpr char kIdentityMarkerSha256[] =
    "7fb00c66c4dd4cc6144e1dd9653fbc8bd3e7857fed9c7a6445cf44804b5b1530";
constexpr char kTransactionId[] = "00000000-0000-4000-8000-000000000070";

class TemporaryIdentityTree {
public:
  TemporaryIdentityTree() {
    static std::atomic<std::uint64_t> sequence{0};
    const std::filesystem::path parent = std::filesystem::temp_directory_path();
    do {
      root = parent / ("desktop_updater_identity_adoption_" +
                       std::to_string(GetCurrentProcessId()) + "_" +
                       std::to_string(sequence.fetch_add(1)));
    } while (!std::filesystem::create_directory(root));
    target = root / "target";
    stage = root / "stage";
    std::filesystem::create_directory(target);
    std::filesystem::create_directory(stage);
  }

  ~TemporaryIdentityTree() {
    std::error_code error;
    std::filesystem::remove_all(root, error);
  }

  TemporaryIdentityTree(const TemporaryIdentityTree &) = delete;
  TemporaryIdentityTree &operator=(const TemporaryIdentityTree &) = delete;

  std::filesystem::path root;
  std::filesystem::path target;
  std::filesystem::path stage;
};

void WriteBytes(const std::filesystem::path &path, const std::string &bytes) {
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  if (!output)
    throw std::runtime_error("unable to create test file");
  output.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
  if (!output)
    throw std::runtime_error("unable to write test file");
}

std::string ReadBytes(const std::filesystem::path &path) {
  std::ifstream input(path, std::ios::binary);
  if (!input)
    throw std::runtime_error("unable to read test file");
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

desktop_updater::runtime::internal::StageProvenanceMarker
IdentityProvenance(const std::string &sha256 = kIdentityMarkerSha256) {
  desktop_updater::runtime::internal::StageProvenanceMarker marker;
  marker.entries.push_back(
      {kIdentityMarkerName, "file",
       static_cast<std::int64_t>(sizeof(kIdentityMarker) - 1), sha256, ""});
  return marker;
}

WindowsHelperPolicy TestPolicy() {
  return WindowsHelperPolicy::ForTesting(
      "com.example.app", "Example Software LLC", "Trusted Helper LLC",
      std::string(64, 'a'), {L"C:\\Program Files\\Example"});
}

desktop_updater::runtime::internal::NativeInstallTransactionRequestV1
Request() {
  using desktop_updater::runtime::internal::NativeInstallTransactionRequestV1;
  NativeInstallTransactionRequestV1 request;
  request.package_id = "com.example.app";
  request.target.executable_relative_path = "bin/example.exe";
  request.signed_descriptor.canonical_sha256 = std::string(64, 'b');
  request.stage.provenance_sha256 = std::string(64, 'c');
  request.stage.artifact_sha256 = std::string(64, 'd');
  return request;
}

desktop_updater::runtime::internal::StageProvenanceMarker Marker() {
  desktop_updater::runtime::internal::StageProvenanceMarker marker;
  marker.entries.push_back(
      {"bin/example.exe", "file", 42, std::string(64, 'e'), ""});
  return marker;
}

TEST(WindowsInstallAuthorizer, RetainsCompleteSealedPolicy) {
  const WindowsHelperPolicy policy = TestPolicy();
  const auto mapped = BuildWindowsNativeInstallAuthorizationPolicy(policy);
  EXPECT_EQ(policy.policy_id(), mapped.policy_id);
  EXPECT_EQ(policy.application_package_id(), mapped.application_package_id);
  EXPECT_EQ(policy.allowed_target_classes(), mapped.allowed_target_classes);
  ASSERT_EQ(1U, mapped.release_root_public_keys.size());
  EXPECT_EQ(policy.release_root_public_keys()[0].key_id,
            mapped.release_root_public_keys[0].key_id);
  ASSERT_EQ(1U, mapped.allowed_strategies.size());
  EXPECT_EQ("directoryReplace", mapped.allowed_strategies[0].strategy);
  EXPECT_EQ("platformDirectory", mapped.allowed_strategies[0].provider);
  EXPECT_EQ(1, mapped.minimum_helper_protocol_version);
}

TEST(WindowsInstallAuthorizer, RejectsExecutableInventoryDrift) {
  const auto expected = BuildWindowsExpectedPayloadIdentity(
      Request(), Marker(), std::string(64, 'f'), TestPolicy());
  EXPECT_EQ("com.example.app", expected.package_id);
  EXPECT_EQ("Example Software LLC", expected.authenticode_publisher);
  EXPECT_EQ(std::string(64, 'e'), expected.executable_sha256);
  EXPECT_EQ(std::string(64, 'c'), expected.stage_provenance_sha256);
  EXPECT_EQ(std::string(64, 'f'), expected.payload_seal_sha256);

  EXPECT_THROW(
      BuildWindowsExpectedPayloadIdentity(Request(), Marker(),
                                          "caller-controlled", TestPolicy()),
      desktop_updater::runtime::internal::NativeInstallAuthorizationError);

  auto marker = Marker();
  marker.entries[0].sha256 = "not-a-sha256";
  EXPECT_THROW(
      BuildWindowsExpectedPayloadIdentity(Request(), marker,
                                          std::string(64, 'f'), TestPolicy()),
      desktop_updater::runtime::internal::NativeInstallAuthorizationError);
  marker = Marker();
  marker.entries.clear();
  EXPECT_THROW(
      BuildWindowsExpectedPayloadIdentity(Request(), marker,
                                          std::string(64, 'f'), TestPolicy()),
      desktop_updater::runtime::internal::NativeInstallAuthorizationError);
}

TEST(WindowsInstallAuthorizer, PortableTargetMustBeExactWritableCallerRoot) {
  EXPECT_NO_THROW(ValidatePortableWindowsTargetAuthorityFacts(
      L"C:\\Users\\caller\\Example", L"C:\\Users\\caller\\Example\\Example.exe",
      true, true));
  EXPECT_THROW(
      ValidatePortableWindowsTargetAuthorityFacts(
          L"C:\\Users\\caller", L"C:\\Users\\caller\\Example\\Example.exe",
          true, true),
      desktop_updater::runtime::internal::NativeInstallAuthorizationError);
  EXPECT_THROW(
      ValidatePortableWindowsTargetAuthorityFacts(
          L"C:\\Users\\caller\\Example",
          L"C:\\Users\\caller\\Example\\Example.exe", false, true),
      desktop_updater::runtime::internal::NativeInstallAuthorizationError);
  EXPECT_THROW(
      ValidatePortableWindowsTargetAuthorityFacts(
          L"C:\\Users\\caller\\Example",
          L"C:\\Users\\caller\\Example\\Example.exe", true, false),
      desktop_updater::runtime::internal::NativeInstallAuthorizationError);
}

TEST(WindowsInstallAuthorizer,
     AdoptsMissingPortableIdentityFromAuthorizedStage) {
  TemporaryIdentityTree tree;
  WriteBytes(tree.stage / kIdentityMarkerName, kIdentityMarker);

  try {
    AdoptAuthorizedPortableWindowsInstallIdentityMarker(
        tree.target, tree.stage, "com.example.app", kIdentityMarkerSha256,
        kTransactionId, IdentityProvenance());
  } catch (const std::exception &error) {
    FAIL() << error.what() << " (Windows error " << GetLastError() << ")";
  }
  EXPECT_EQ(kIdentityMarker, ReadBytes(tree.target / kIdentityMarkerName));
  EXPECT_EQ(kIdentityMarker, ReadBytes(tree.stage / kIdentityMarkerName));
}

TEST(WindowsInstallAuthorizer, KeepsExistingMatchingPortableIdentity) {
  TemporaryIdentityTree tree;
  WriteBytes(tree.stage / kIdentityMarkerName, kIdentityMarker);
  WriteBytes(tree.target / kIdentityMarkerName, kIdentityMarker);
  const auto before =
      std::filesystem::last_write_time(tree.target / kIdentityMarkerName);

  EXPECT_NO_THROW(AdoptAuthorizedPortableWindowsInstallIdentityMarker(
      tree.target, tree.stage, "com.example.app", kIdentityMarkerSha256,
      kTransactionId, IdentityProvenance()));
  EXPECT_EQ(before, std::filesystem::last_write_time(tree.target /
                                                     kIdentityMarkerName));
}

TEST(WindowsInstallAuthorizer, DoesNotOverwriteMismatchedPortableIdentity) {
  TemporaryIdentityTree tree;
  WriteBytes(tree.stage / kIdentityMarkerName, kIdentityMarker);
  const std::string mismatch =
      "{\"packageId\":\"com.example.other\",\"schemaVersion\":1}";
  WriteBytes(tree.target / kIdentityMarkerName, mismatch);

  EXPECT_THROW(
      AdoptAuthorizedPortableWindowsInstallIdentityMarker(
          tree.target, tree.stage, "com.example.app", kIdentityMarkerSha256,
          kTransactionId, IdentityProvenance()),
      desktop_updater::runtime::internal::NativeInstallAuthorizationError);
  EXPECT_EQ(mismatch, ReadBytes(tree.target / kIdentityMarkerName));
}

TEST(WindowsInstallAuthorizer,
     RejectsUnboundStagedIdentityWithoutCreatingMarker) {
  TemporaryIdentityTree tree;
  WriteBytes(tree.stage / kIdentityMarkerName, kIdentityMarker);
  auto provenance = IdentityProvenance(std::string(64, 'a'));

  EXPECT_THROW(
      AdoptAuthorizedPortableWindowsInstallIdentityMarker(
          tree.target, tree.stage, "com.example.app", kIdentityMarkerSha256,
          kTransactionId, provenance),
      desktop_updater::runtime::internal::NativeInstallAuthorizationError);
  EXPECT_FALSE(std::filesystem::exists(tree.target / kIdentityMarkerName));
}

TEST(WindowsInstallAuthorizer,
     RejectsUnsafeExistingIdentityWithoutReplacingIt) {
  TemporaryIdentityTree tree;
  WriteBytes(tree.stage / kIdentityMarkerName, kIdentityMarker);
  std::filesystem::create_directory(tree.target / kIdentityMarkerName);

  EXPECT_THROW(AdoptAuthorizedPortableWindowsInstallIdentityMarker(
                   tree.target, tree.stage, "com.example.app",
                   kIdentityMarkerSha256, kTransactionId, IdentityProvenance()),
               std::exception);
  EXPECT_TRUE(std::filesystem::is_directory(tree.target / kIdentityMarkerName));
}

} // namespace
} // namespace desktop_updater::helper
