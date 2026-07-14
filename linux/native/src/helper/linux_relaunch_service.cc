#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "linux_relaunch_service.h"

#include <fcntl.h>
#include <openssl/evp.h>
#include <sys/stat.h>
#include <unistd.h>

#include <array>
#include <iomanip>
#include <memory>
#include <set>
#include <sstream>
#include <utility>
#include <vector>

#include "json_value.h"

extern char** environ;

namespace desktop_updater::helper {
namespace {

using desktop_updater::runtime::internal::EncodeCanonicalJson;
using desktop_updater::runtime::internal::JsonValue;
using desktop_updater::runtime::internal::ParseJson;

constexpr char kStageProvenance[] =
    ".desktop_updater_stage_provenance.json";
constexpr char stageProvenance[] = "stageProvenance";

void RequireKeys(const JsonValue& value,
                 const std::set<std::string>& expected) {
  const auto& object = value.object();
  if (object.size() != expected.size()) {
    throw LinuxRelaunchError("stage provenance fields rejected");
  }
  for (const auto& key : expected) {
    if (object.find(key) == object.end()) {
      throw LinuxRelaunchError("stage provenance fields rejected");
    }
  }
}

std::vector<std::string> SplitRelative(const std::string& path) {
  if (path.empty() || path.front() == '/') {
    throw LinuxRelaunchError("executable path is not relative");
  }
  std::vector<std::string> result;
  std::size_t start = 0;
  while (start <= path.size()) {
    const std::size_t separator = path.find('/', start);
    const std::string component =
        path.substr(start, separator == std::string::npos
                               ? std::string::npos
                               : separator - start);
    ValidateLinuxLeaf(component);
    result.push_back(component);
    if (separator == std::string::npos) break;
    start = separator + 1;
  }
  return result;
}

UniqueLinuxFd OpenPayloadRoot(int parent, const std::string& leaf) {
  auto result = OpenLinuxRelativeNoFollow(parent, leaf, O_PATH);
  if (!ReadLinuxFileIdentity(result.get()).directory) {
    throw LinuxRelaunchError("payload root is not a directory");
  }
  return result;
}

UniqueLinuxFd OpenExecutable(int root, const std::string& relative_path) {
  const auto components = SplitRelative(relative_path);
  UniqueLinuxFd current(dup(root));
  if (!current.valid()) throw LinuxRelaunchError("payload root duplicate failed");
  for (std::size_t index = 0; index < components.size(); ++index) {
    const bool last = index + 1 == components.size();
    current = OpenLinuxRelativeNoFollow(
        current.get(), components[index],
        last ? O_RDONLY : O_PATH | O_DIRECTORY);
  }
  const auto identity = ReadLinuxFileIdentity(current.get());
  if (identity.directory || (identity.mode & S_IFMT) != S_IFREG ||
      (identity.mode & 0111) == 0 || identity.link_count != 1) {
    throw LinuxRelaunchError("verified executable type or permissions rejected");
  }
  return current;
}

std::string ReadFd(int fd, std::size_t maximum_bytes) {
  if (lseek(fd, 0, SEEK_SET) < 0) {
    throw LinuxRelaunchError("payload read seek failed");
  }
  std::string result;
  std::array<char, 4096> buffer{};
  for (;;) {
    const ssize_t count = read(fd, buffer.data(), buffer.size());
    if (count < 0) throw LinuxRelaunchError("payload read failed");
    if (count == 0) break;
    result.append(buffer.data(), static_cast<std::size_t>(count));
    if (result.size() > maximum_bytes) {
      throw LinuxRelaunchError("payload file exceeds size limit");
    }
  }
  return result;
}

std::string Sha256Fd(int fd) {
  std::unique_ptr<EVP_MD_CTX, decltype(&EVP_MD_CTX_free)> context(
      EVP_MD_CTX_new(), EVP_MD_CTX_free);
  if (!context || EVP_DigestInit_ex(context.get(), EVP_sha256(), nullptr) != 1 ||
      lseek(fd, 0, SEEK_SET) < 0) {
    throw LinuxRelaunchError("SHA-256 setup failed");
  }
  std::array<unsigned char, 64 * 1024> buffer{};
  for (;;) {
    const ssize_t count = read(fd, buffer.data(), buffer.size());
    if (count < 0) throw LinuxRelaunchError("SHA-256 read failed");
    if (count == 0) break;
    if (EVP_DigestUpdate(context.get(), buffer.data(),
                         static_cast<std::size_t>(count)) != 1) {
      throw LinuxRelaunchError("SHA-256 update failed");
    }
  }
  std::array<unsigned char, EVP_MAX_MD_SIZE> digest{};
  unsigned int length = 0;
  if (EVP_DigestFinal_ex(context.get(), digest.data(), &length) != 1 ||
      length != 32) {
    throw LinuxRelaunchError("SHA-256 finalization failed");
  }
  std::ostringstream output;
  output << std::hex << std::setfill('0');
  for (unsigned int index = 0; index < length; ++index) {
    output << std::setw(2) << static_cast<unsigned int>(digest[index]);
  }
  return output.str();
}

}  // namespace

FdRelativeLinuxPayloadVerifier::FdRelativeLinuxPayloadVerifier(
    LinuxVerifiedPayloadIdentity expectation)
    : expectation_(std::move(expectation)) {}

LinuxVerifiedPayloadIdentity FdRelativeLinuxPayloadVerifier::Verify(
    int parent,
    const std::string& payload_leaf) {
  (void)stageProvenance;
  auto root = OpenPayloadRoot(parent, payload_leaf);
  auto provenance =
      OpenLinuxRelativeNoFollow(root.get(), kStageProvenance, O_RDONLY);
  const std::string provenance_json = ReadFd(provenance.get(), 1024 * 1024);
  const std::string provenance_sha256 = Sha256Fd(provenance.get());
  JsonValue marker;
  try {
    marker = ParseJson(provenance_json);
  } catch (const std::exception&) {
    throw LinuxRelaunchError("stage provenance JSON rejected");
  }
  if (EncodeCanonicalJson(marker) != provenance_json) {
    throw LinuxRelaunchError("stage provenance is not canonical JSON");
  }
  RequireKeys(marker, {"artifactSha256", "descriptorSha256", "entries",
                       "nonce", "packageId", "schemaVersion"});
  if (marker.at("schemaVersion").integer() != 1) {
    throw LinuxRelaunchError("stage provenance schema rejected");
  }

  auto executable =
      OpenExecutable(root.get(), expectation_.executable_relative_path);
  const LinuxFileIdentity executable_identity =
      ReadLinuxFileIdentity(executable.get());
  const std::string executable_sha256 = Sha256Fd(executable.get());
  bool executable_bound = false;
  for (const auto& entry : marker.at("entries").array()) {
    if (entry.at("path").string() == expectation_.executable_relative_path) {
      executable_bound = entry.at("kind").string() == "file" &&
                         entry.at("sha256").string() == executable_sha256;
    }
  }
  if (!executable_bound) {
    throw LinuxRelaunchError("executable is absent from stage provenance");
  }

  // Linux signer_identity is the policy-sealed identity of the signed release
  // descriptor. Its descriptor and artifact digests are re-bound below.
  LinuxVerifiedPayloadIdentity observed{
      marker.at("packageId").string(),
      expectation_.signer_identity,
      marker.at("descriptorSha256").string(),
      provenance_sha256,
      marker.at("artifactSha256").string(),
      expectation_.executable_relative_path,
      executable_sha256,
      executable_identity.mode,
      executable_identity.uid,
      executable_identity.gid,
  };
  if (observed != expectation_) {
    throw LinuxRelaunchError(
        "payload policy, provenance, artifact, executable, owner, or mode mismatch");
  }
  return observed;
}

void FexecveLinuxProcessLauncher::Launch(int executable_fd,
                                         const std::string& argv0) {
  std::vector<char> mutable_argv0(argv0.begin(), argv0.end());
  mutable_argv0.push_back('\0');
  char* argv[] = {mutable_argv0.data(), nullptr};
  if (fexecve(executable_fd, argv, environ) != 0) {
    throw LinuxRelaunchError("fexecve verified relaunch failed");
  }
}

LinuxRelaunchService::LinuxRelaunchService(
    LinuxVerifiedPayloadIdentity expected_payload_identity,
    LinuxInstallPayloadVerifier& verifier,
    LinuxProcessLauncher& launcher)
    : expected_payload_identity_(std::move(expected_payload_identity)),
      verifier_(verifier),
      launcher_(launcher) {}

void LinuxRelaunchService::Relaunch(
    const std::filesystem::path& application_path) {
  const auto application =
      std::filesystem::absolute(application_path).lexically_normal();
  auto parent = OpenLinuxDirectory(application.parent_path().string());
  const std::string leaf = application.filename().string();
  if (verifier_.Verify(parent.get(), leaf) != expected_payload_identity_) {
    throw LinuxRelaunchError("activated payload identity mismatch");
  }
  auto root = OpenPayloadRoot(parent.get(), leaf);
  auto executable =
      OpenExecutable(root.get(), expected_payload_identity_.executable_relative_path);
  const LinuxFileIdentity retained = ReadLinuxFileIdentity(executable.get());
  if (retained.mode != expected_payload_identity_.executable_mode ||
      retained.uid != expected_payload_identity_.executable_uid ||
      retained.gid != expected_payload_identity_.executable_gid ||
      Sha256Fd(executable.get()) != expected_payload_identity_.executable_sha256) {
    throw LinuxRelaunchError("verified executable proof changed before launch");
  }
  launcher_.Launch(executable.get(),
                   expected_payload_identity_.executable_relative_path);
}

}  // namespace desktop_updater::helper
