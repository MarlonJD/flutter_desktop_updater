#include <gtest/gtest.h>

#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>

#include "json_value.h"
#include "native_install_request.h"

#ifndef DESKTOP_UPDATER_VALID_REQUEST_FIXTURE_PATH
#error "DESKTOP_UPDATER_VALID_REQUEST_FIXTURE_PATH must name valid-requests.json"
#endif

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

std::string ReadFixture(const char* path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) {
    throw std::runtime_error("Unable to read native install request fixture.");
  }
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

TEST(native_install_request, AcceptsEveryCanonicalV1Fixture) {
  const JsonValue fixture =
      ParseJson(ReadFixture(DESKTOP_UPDATER_VALID_REQUEST_FIXTURE_PATH));
  std::size_t count = 0;
  for (const JsonValue& entry : fixture.at("cases").array()) {
    const std::string canonical = EncodeCanonicalJson(entry.at("request"));
    const NativeInstallTransactionRequestV1 request =
        ParseNativeInstallTransactionRequestV1(canonical);
    EXPECT_EQ(1, request.schema_version) << entry.at("name").string();
    EXPECT_EQ(1, request.protocol_version) << entry.at("name").string();
    EXPECT_EQ(entry.at("strategy").string(), request.strategy)
        << entry.at("name").string();
    EXPECT_EQ(request.package_id, request.caller.package_id)
        << entry.at("name").string();
    ++count;
  }
  EXPECT_EQ(5u, count);
}

TEST(native_install_request, CanonicalEncoderRoundTripsEveryV1Fixture) {
  const JsonValue fixture =
      ParseJson(ReadFixture(DESKTOP_UPDATER_VALID_REQUEST_FIXTURE_PATH));
  for (const JsonValue& entry : fixture.at("cases").array()) {
    const std::string canonical = EncodeCanonicalJson(entry.at("request"));
    const NativeInstallTransactionRequestV1 request =
        ParseNativeInstallTransactionRequestV1(canonical);
    EXPECT_EQ(canonical,
              EncodeCanonicalNativeInstallTransactionRequestV1(request))
        << entry.at("name").string();
  }
}

TEST(native_install_request, RejectsAuthorityAndBindingDrift) {
  const JsonValue fixture =
      ParseJson(ReadFixture(DESKTOP_UPDATER_VALID_REQUEST_FIXTURE_PATH));
  const JsonValue baseline = fixture.at("cases").array().front().at("request");

  JsonValue unknown_request_field = baseline;
  unknown_request_field.object().emplace(
      "allowedInstallRoots", JsonValue(JsonValue::Array{}));
  EXPECT_THROW(ParseNativeInstallTransactionRequestV1(
                   EncodeCanonicalJson(unknown_request_field)),
               NativeInstallProtocolError);

  JsonValue unknown_target_field = baseline;
  unknown_target_field.object().at("target").object().emplace(
      "parentPath", JsonValue(std::string("/attacker")));
  EXPECT_THROW(ParseNativeInstallTransactionRequestV1(
                   EncodeCanonicalJson(unknown_target_field)),
               NativeInstallProtocolError);

  JsonValue caller_package_mismatch = baseline;
  caller_package_mismatch.object()
      .at("caller")
      .object()
      .at("packageId") = JsonValue(std::string("com.attacker.app"));
  EXPECT_THROW(ParseNativeInstallTransactionRequestV1(
                   EncodeCanonicalJson(caller_package_mismatch)),
               NativeInstallProtocolError);

  JsonValue provider_mismatch = baseline;
  provider_mismatch.object().at("provider") =
      JsonValue(std::string("windowsInno"));
  EXPECT_THROW(ParseNativeInstallTransactionRequestV1(
                   EncodeCanonicalJson(provider_mismatch)),
               NativeInstallProtocolError);

  JsonValue invalid_diagnostics = baseline;
  invalid_diagnostics.object().at("diagnosticsDestination").object().emplace(
      "stream", JsonValue(std::string("stdout")));
  EXPECT_THROW(ParseNativeInstallTransactionRequestV1(
                   EncodeCanonicalJson(invalid_diagnostics)),
               NativeInstallProtocolError);
}

TEST(native_install_request, RequiresCanonicalBytesAndExactNestedKeys) {
  const JsonValue fixture =
      ParseJson(ReadFixture(DESKTOP_UPDATER_VALID_REQUEST_FIXTURE_PATH));
  const std::string canonical =
      EncodeCanonicalJson(fixture.at("cases").array().front().at("request"));
  EXPECT_THROW(ParseNativeInstallTransactionRequestV1(canonical + "\n"),
               NativeInstallProtocolError);

  JsonValue request = fixture.at("cases").array().front().at("request");
  request.object().at("target").object().emplace(
      "callerChosenAuthority", JsonValue(std::string("rejected")));
  EXPECT_THROW(ParseNativeInstallTransactionRequestV1(
                   EncodeCanonicalJson(request)),
               NativeInstallProtocolError);
}

}  // namespace
}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
