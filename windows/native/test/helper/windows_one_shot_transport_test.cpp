#include <gtest/gtest.h>

#include <string>

#include "windows_one_shot_transport.h"

namespace desktop_updater::helper {
namespace {

WindowsHelperPolicy TestPolicy() {
  return WindowsHelperPolicy::ForTesting(
      "com.example.app", "Example Software LLC", "Trusted Helper LLC",
      std::string(64, 'a'), {L"C:\\Program Files\\Example"});
}

WindowsHelperPolicy PortableTestPolicy() {
  return WindowsHelperPolicy::ForPortableTesting(
      "com.example.app", std::string(64, 'b'), std::string(64, 'a'));
}

desktop_updater::runtime::internal::NativeInstallCallerV1 Caller() {
  return {4242, WindowsProcessStartIdentityString(123),
          std::string(64, 'b'), "com.example.app",
          "Example Software LLC"};
}

ObservedWindowsCallerIdentity Observed() {
  return {4242,
          123,
          {true, L"Example Software LLC", std::string(64, 'b'),
           L"C:\\Program Files\\Example\\Example.exe", true, 7, {1, 2}}};
}

TEST(WindowsOneShotTransport, RejectsCallerIdentityDrift) {
  EXPECT_NO_THROW(
      ValidateWindowsCallerIdentity(Caller(), Observed(), TestPolicy()));

  auto caller = Caller();
  caller.executable_sha256 = std::string(64, 'c');
  EXPECT_THROW(ValidateWindowsCallerIdentity(caller, Observed(), TestPolicy()),
               WindowsOneShotTransportError);
  caller = Caller();
  caller.signer_identity = "Attacker LLC";
  EXPECT_THROW(ValidateWindowsCallerIdentity(caller, Observed(), TestPolicy()),
               WindowsOneShotTransportError);
  caller = Caller();
  caller.package_id = "com.example.attacker";
  EXPECT_THROW(ValidateWindowsCallerIdentity(caller, Observed(), TestPolicy()),
               WindowsOneShotTransportError);
  caller = Caller();
  caller.process_start_identity = WindowsProcessStartIdentityString(124);
  EXPECT_THROW(ValidateWindowsCallerIdentity(caller, Observed(), TestPolicy()),
               WindowsOneShotTransportError);
}

TEST(WindowsOneShotTransport, RejectsInvalidFrameBounds) {
  EXPECT_NO_THROW(ValidateWindowsOneShotFrameLength(1));
  EXPECT_NO_THROW(ValidateWindowsOneShotFrameLength(
      kMaximumWindowsOneShotFrameLength));
  EXPECT_THROW(ValidateWindowsOneShotFrameLength(0),
               WindowsOneShotTransportError);
  EXPECT_THROW(ValidateWindowsOneShotFrameLength(
                   kMaximumWindowsOneShotFrameLength + 1),
               WindowsOneShotTransportError);
}

TEST(WindowsOneShotTransport, PortableCallerUsesExactSignedApplicationDigest) {
  auto observed = Observed();
  observed.executable.final_path = L"C:\\Users\\caller\\Example\\Example.exe";
  observed.executable.installer_protected_location = false;
  EXPECT_NO_THROW(ValidateWindowsCallerIdentity(
      Caller(), observed, PortableTestPolicy()));

  observed.executable.signature_valid = false;
  EXPECT_THROW(ValidateWindowsCallerIdentity(
                   Caller(), observed, PortableTestPolicy()),
               WindowsOneShotTransportError);
  observed = Observed();
  observed.executable.sha256 = std::string(64, 'c');
  EXPECT_THROW(ValidateWindowsCallerIdentity(
                   Caller(), observed, PortableTestPolicy()),
               WindowsOneShotTransportError);
}

}  // namespace
}  // namespace desktop_updater::helper
