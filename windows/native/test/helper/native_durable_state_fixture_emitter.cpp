#include <windows.h>

#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>

#include "helper_authenticode.h"
#include "windows_persistent_recovery.h"
#include "windows_portable_transaction_index.h"
#include "windows_protected_helper_locator.h"
#include "windows_transaction_journal.h"

namespace desktop_updater::helper {
namespace {

constexpr char kTransactionId[] =
    "00000000-0000-4000-8000-000000000025";

WindowsTransactionJournal TransactionJournal() {
  const WindowsTransactionPaths paths =
      WindowsTransactionPaths::Create(L"Example.app", kTransactionId);
  WindowsFileIdentity parent;
  parent.volume_serial = 7;
  parent.file_id.fill(1);
  parent.attributes = FILE_ATTRIBUTE_DIRECTORY;
  parent.number_of_links = 1;
  parent.directory = true;
  WindowsFileIdentity target = parent;
  target.file_id.fill(2);
  WindowsFileIdentity stage_parent = parent;
  stage_parent.file_id.fill(3);
  WindowsFileIdentity stage = parent;
  stage.file_id.fill(4);

  WindowsTransactionJournal journal;
  journal.transaction_id = kTransactionId;
  journal.owner_process_id = 42;
  journal.owner_process_start_identity = 43;
  journal.target_name = paths.target_name;
  journal.original_stage_parent_path = L"C:\\ProgramData\\Example\\Stage";
  journal.original_stage_name = L"Stage.app";
  journal.prepared_name = paths.prepared_name;
  journal.backup_name = paths.backup_name;
  journal.lock_name = paths.lock_name;
  journal.parent_identity = parent;
  journal.stage_parent_identity = stage_parent;
  journal.target_identity = target;
  journal.stage_identity = stage;
  journal.expected_payload_identity = {
      "com.example.app",    "Example Software LLC", std::string(64, 'a'),
      std::string(64, 'b'), std::string(64, 'c'),   L"bin\\example.exe",
      std::string(64, 'd'), std::string(64, 'e')};
  journal.state = WindowsTransactionState::kPrepared;
  return journal;
}

WindowsPersistentTransactionRecord PersistentRecord(
    const std::string& journal_canonical) {
  return {WindowsPersistentTransactionRecord::kSchemaVersion,
          kTransactionId,
          "com.example.desktop-updater.privileged",
          "com.example.app",
          std::string(64, 'e'),
          42,
          43,
          44,
          45,
          std::string(43, 'A'),
          std::filesystem::path(L"C:\\Program Files\\Example.app"),
          "prepared",
          "none",
          "notRequested",
          journal_canonical,
          WindowsHelperSha256Hex(journal_canonical)};
}

WindowsPersistentResolverClaim ResolverClaim() {
  return {WindowsPersistentResolverClaim::kSchemaVersion,
          kTransactionId,
          101,
          201,
          44,
          45,
          std::string(43, 'B'),
          "claimed"};
}

WindowsPortableTransactionLocatorV1 PortableLocator() {
  return {WindowsPortableTransactionLocatorV1::kSchemaVersion,
          kTransactionId,
          std::string(64, 'c'),
          "com.example.desktop-updater.portable",
          "com.example.app",
          std::string(64, 'a'),
          std::string(64, 'b')};
}

ProtectedWindowsHelperEndpointV1 ProtectedEndpoint() {
  return {ProtectedWindowsHelperEndpointV1::kSchemaVersion,
          "com.example.desktop-updater.privileged",
          "com.example.app",
          "com.example.desktop-updater.helper",
          std::filesystem::path(
              L"C:\\Program Files\\Common Files\\DesktopUpdater\\Example\\1"
              L"\\desktop_updater_install_helper.exe"),
          std::filesystem::path(
              L"C:\\Program Files\\Common Files\\DesktopUpdater\\Example\\1"
              L"\\desktop_updater_helper_policy.json"),
          std::string(64, 'a'),
          std::string(64, 'b')};
}

void WriteExact(const std::filesystem::path& path,
                const std::string& bytes) {
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  if (!output) {
    throw std::runtime_error("could not open fixture output: " +
                             path.string());
  }
  output.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
  if (!output) {
    throw std::runtime_error("could not write fixture output: " +
                             path.string());
  }
}

std::string ReadExact(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) {
    throw std::runtime_error("could not open fixture input: " +
                             path.string());
  }
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

template <typename Decode>
void VerifyExact(const std::filesystem::path& path, Decode decode) {
  const std::string frozen = ReadExact(path);
  const std::string reencoded = decode(frozen);
  if (reencoded != frozen) {
    throw std::runtime_error("fixture did not decode/re-encode byte-exactly: " +
                             path.string());
  }
}

void VerifyFixtures(const std::filesystem::path& input_directory) {
  VerifyExact(input_directory / "transaction-journal-schema2.json",
              [](const std::string& value) {
                return WindowsTransactionJournal::DecodeStrict(value)
                    .EncodeCanonical();
              });
  VerifyExact(input_directory / "persistent-record-schema3.json",
              [](const std::string& value) {
                return WindowsPersistentTransactionRecord::DecodeStrict(value)
                    .EncodeCanonical();
              });
  VerifyExact(input_directory / "resolver-claim-schema1.json",
              [](const std::string& value) {
                return WindowsPersistentResolverClaim::DecodeStrict(value)
                    .EncodeCanonical();
              });
  VerifyExact(input_directory / "portable-locator-schema1.json",
              [](const std::string& value) {
                return WindowsPortableTransactionLocatorV1::DecodeStrict(value)
                    .EncodeCanonical();
              });
  VerifyExact(input_directory / "protected-helper-endpoint-schema1.json",
              [](const std::string& value) {
                return ProtectedWindowsHelperEndpointV1::DecodeStrict(value)
                    .EncodeCanonical();
              });
}

}  // namespace
}  // namespace desktop_updater::helper

int main(int argc, char** argv) {
  using namespace desktop_updater::helper;
  try {
    if (argc == 3 && std::string(argv[1]) == "--verify") {
      VerifyFixtures(std::filesystem::path(argv[2]));
      return 0;
    }
    if (argc != 2) {
      std::cerr << "usage: native_durable_state_fixture_emitter OUTPUT_DIR\n"
                   "       native_durable_state_fixture_emitter --verify "
                   "FIXTURE_DIR\n";
      return 64;
    }
    const std::filesystem::path output_directory(argv[1]);
    std::filesystem::create_directories(output_directory);
    const WindowsTransactionJournal journal = TransactionJournal();
    const std::string journal_canonical = journal.EncodeCanonical();
    WriteExact(output_directory / "transaction-journal-schema2.json",
               journal_canonical);
    WriteExact(output_directory / "persistent-record-schema3.json",
               PersistentRecord(journal_canonical).EncodeCanonical());
    WriteExact(output_directory / "resolver-claim-schema1.json",
               ResolverClaim().EncodeCanonical());
    WriteExact(output_directory / "portable-locator-schema1.json",
               PortableLocator().EncodeCanonical());
    WriteExact(output_directory / "protected-helper-endpoint-schema1.json",
               ProtectedEndpoint().EncodeCanonical());
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
