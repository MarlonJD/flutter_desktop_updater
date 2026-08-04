#include <gtest/gtest.h>

#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>

#include "install_helper_policy.h"
#include "json_value.h"

#ifndef DESKTOP_UPDATER_POLICY_FIXTURE_PATH
#error "DESKTOP_UPDATER_POLICY_FIXTURE_PATH must name policy-cases.json"
#endif

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

std::string ReadPolicyFixtures() {
  std::ifstream input(DESKTOP_UPDATER_POLICY_FIXTURE_PATH, std::ios::binary);
  if (!input) {
    throw std::runtime_error("Unable to read policy fixture file.");
  }
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

TEST(install_helper_policy, GeneratedCasesMatchStrictCppParser) {
  const JsonValue fixture = ParseJson(ReadPolicyFixtures());
  std::size_t valid_count = 0;
  std::size_t invalid_count = 0;
  for (const JsonValue& entry : fixture.at("cases").array()) {
    const std::string encoded = EncodeCanonicalJson(entry.at("policy"));
    const bool expected_valid = entry.at("expectedValid").boolean();
    try {
      const HelperPolicyV1 policy = ParseHelperPolicyV1(
          encoded, entry.at("expectedPackageId").string(),
          entry.at("minimumAcceptedPolicyVersion").integer());
      EXPECT_TRUE(expected_valid) << entry.at("name").string();
      EXPECT_EQ(policy.canonical_json, entry.at("canonicalJson").string());
      EXPECT_EQ(policy.canonical_sha256,
                entry.at("canonicalSha256").string());
      EXPECT_FALSE(policy.allowed_strategies.empty());
      ++valid_count;
    } catch (const HelperPolicyError& error) {
      EXPECT_FALSE(expected_valid) << entry.at("name").string();
      EXPECT_EQ(error.code(), entry.at("expectedFailure").string())
          << entry.at("name").string();
      ++invalid_count;
    }
  }
  EXPECT_GE(valid_count, 2u);
  EXPECT_GE(invalid_count, 11u);
}

TEST(install_helper_policy, ParsedValuesAreImmutableCopies) {
  const JsonValue fixture = ParseJson(ReadPolicyFixtures());
  const JsonValue& entry = fixture.at("cases").array().front();
  const HelperPolicyV1 policy = ParseHelperPolicyV1(
      EncodeCanonicalJson(entry.at("policy")),
      entry.at("expectedPackageId").string(),
      entry.at("minimumAcceptedPolicyVersion").integer());

  EXPECT_EQ(policy.policy_version, 1);
  EXPECT_EQ(policy.application_package_id, "com.example.app");
  EXPECT_FALSE(policy.allowed_target_classes.empty());
  EXPECT_FALSE(policy.release_root_public_keys.empty());
  EXPECT_EQ(policy.minimum_helper_protocol_version, 1);
}

}  // namespace
}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
