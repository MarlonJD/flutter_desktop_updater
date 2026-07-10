#include "transport_fixture_tests.h"

#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iterator>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace desktop_updater {
namespace runtime {
namespace internal {
namespace {

void Expect(bool condition, const std::string& message) {
  if (!condition) throw std::runtime_error(message);
}

std::string Hex(const std::vector<std::uint8_t>& bytes) {
  std::ostringstream output;
  output << std::hex << std::setfill('0');
  for (std::uint8_t byte : bytes) {
    output << std::setw(2) << static_cast<int>(byte);
  }
  return output.str();
}

std::string ReadFile(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

}  // namespace

void RunTransportFixtureTests(UpdateTransport* transport,
                              const std::string& base_url,
                              const std::string& temporary_directory,
                              const Sha256Function& sha256) {
  Expect(transport != nullptr, "Transport is required.");
  const std::vector<std::uint8_t> metadata =
      transport->DownloadMetadata(base_url + "/redirect");
  Expect(std::string(metadata.begin(), metadata.end()) == "metadata",
         "Redirected metadata response differs.");
  const std::vector<std::uint8_t> retried =
      transport->DownloadMetadata(base_url + "/retry");
  Expect(std::string(retried.begin(), retried.end()) == "metadata",
         "Retry metadata response differs.");
  bool oversized = false;
  try {
    transport->DownloadMetadata(base_url + "/oversize");
  } catch (const std::exception&) {
    oversized = true;
  }
  Expect(oversized, "Oversized metadata was accepted.");

  const std::string artifact = "native transport artifact\n";
  const std::filesystem::path destination =
      std::filesystem::u8path(temporary_directory) /
      "desktop-updater-transport-artifact.bin";
  std::filesystem::path partial = destination;
  partial += ".part";
  std::filesystem::remove(destination);
  std::filesystem::remove(partial);
  {
    std::ofstream output(partial, std::ios::binary);
    output.write(artifact.data(), 7);
  }
  std::int64_t final_progress = 0;
  ArtifactDownloadRequest request;
  request.url = base_url + "/artifact";
  request.destination_path = destination.u8string();
  request.destination_filesystem_path = destination;
  request.expected_length = static_cast<std::int64_t>(artifact.size());
  request.expected_sha256 = Hex(sha256(artifact));
  request.progress = [&final_progress](std::int64_t received, std::int64_t) {
    final_progress = received;
  };
  transport->DownloadArtifact(request);
  Expect(ReadFile(destination) == artifact, "Resumed artifact differs.");
  Expect(final_progress == static_cast<std::int64_t>(artifact.size()),
         "Artifact progress total differs.");
  Expect(ReadFile(partial).empty(), ".part file remains after success.");

  request.destination_path = destination.u8string() + ".bad";
  request.destination_filesystem_path =
      std::filesystem::u8path(request.destination_path);
  request.expected_sha256 = std::string(64, '0');
  bool integrity_failed = false;
  try {
    transport->DownloadArtifact(request);
  } catch (const std::exception&) {
    integrity_failed = true;
  }
  Expect(integrity_failed, "Bad artifact SHA-256 was accepted.");
  Expect(ReadFile(request.destination_path + ".part").empty(),
         ".part file remains after terminal failure.");
  std::filesystem::remove(destination);
  std::filesystem::remove(std::filesystem::u8path(request.destination_path));
}

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater
