#include <sys/stat.h>
#include <unistd.h>

#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>

#include "install_strategy.h"
#include "linux_transaction_journal.h"
#include "linux_transaction_registry.h"

namespace desktop_updater::helper {
namespace {

constexpr char kTransactionId[] =
    "00000000-0000-4000-8000-000000000071";

LinuxFileIdentity Identity(std::uint64_t inode, std::int64_t change_time) {
  LinuxFileIdentity identity;
  identity.device = 7;
  identity.inode = inode;
  identity.mount_id = 17;
  identity.mode = S_IFDIR | 0755;
  identity.uid = 1000;
  identity.gid = 1000;
  identity.link_count = 1;
  identity.change_time_seconds = change_time;
  identity.change_time_nanoseconds = change_time + 100;
  identity.directory = true;
  return identity;
}

LinuxVerifiedPayloadIdentity PayloadIdentity() {
  return {"com.example.app", "stable-2026", std::string(64, '2'),
          std::string(64, '3'), std::string(64, '4'), "bin/example",
          std::string(64, '5'), S_IFREG | 0755, 1000, 1000};
}

LinuxTransactionJournal TransactionJournal() {
  const LinuxTransactionPaths paths =
      LinuxTransactionPaths::Create("Example.AppDir", kTransactionId);
  LinuxTransactionJournal journal;
  journal.transaction_id = kTransactionId;
  journal.owner_process_id = 42;
  journal.owner_process_start_identity = 43;
  journal.target_name = paths.target_name;
  journal.original_stage_name = "Stage.AppDir";
  journal.prepared_name = paths.prepared_name;
  journal.backup_name = paths.backup_name;
  journal.lock_name = paths.lock_name;
  journal.parent_identity = Identity(11, 21);
  journal.target_identity = Identity(12, 22);
  journal.stage_identity = Identity(13, 23);
  journal.expected_payload_identity = PayloadIdentity();
  journal.state = LinuxTransactionState::kPrepared;
  return journal;
}

LinuxTransactionRegistryRecord RegistryRecord() {
  LinuxTransactionRegistryRecord record;
  record.transaction_id = kTransactionId;
  record.package_id = "com.example.app";
  record.policy_id = "com.example.policy";
  record.helper_endpoint_identity_sha256 = std::string(64, '1');
  record.recovery_authority_kind = "retainedPortable";
  record.recovery_policy_identity_sha256 = std::string(64, '7');
  record.recovery_authority_generation_sha256 =
      LinuxRecoveryAuthorityGenerationSha256(
          record.transaction_id, record.recovery_authority_kind,
          record.helper_endpoint_identity_sha256,
          record.recovery_policy_identity_sha256);
  record.target_path = "/opt/desktop-updater-fixture/Example.AppDir";
  record.canonical_request = "{}";
  record.state = "prepared";
  record.result_code = "recoveryRequired";
  record.journal_sha256 = std::string(64, '0');
  record.expected_payload_identity = PayloadIdentity();
  return record;
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
    throw std::runtime_error("could not open emitted provider journal: " +
                             path.string());
  }
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

void EmitProviderJournal(const std::filesystem::path& output_directory) {
  const std::filesystem::path working_directory =
      output_directory / ".provider-writer";
  std::filesystem::remove_all(working_directory);
  std::filesystem::create_directories(working_directory);
  if (chmod(working_directory.c_str(), 0700) != 0) {
    throw std::runtime_error("could not protect provider writer directory");
  }
  LinuxProviderJournalRecord record;
  record.transaction_id =
      "00000000-0000-4000-8000-000000000044";
  record.transaction = {"apt", "example-app", "apt-history-42",
                        LinuxProviderTransactionState::kManagerStarted};
  record.expected_version_or_revision = "2.0.0";
  record.command_sha256 = std::string(64, 'a');
  {
    LinuxProviderJournal writer(working_directory, geteuid(), getegid());
    writer.Persist(record);
  }
  const std::filesystem::path emitted =
      working_directory / (record.transaction_id + ".provider.json");
  WriteExact(output_directory / "provider-journal-schema1.json",
             ReadExact(emitted));
  std::filesystem::remove_all(working_directory);
}

}  // namespace
}  // namespace desktop_updater::helper

int main(int argc, char** argv) {
  using namespace desktop_updater::helper;
  try {
    if (argc != 2) {
      std::cerr << "usage: native_durable_state_fixture_emitter OUTPUT_DIR\n";
      return 64;
    }
    const std::filesystem::path output_directory(argv[1]);
    std::filesystem::create_directories(output_directory);
    WriteExact(output_directory / "transaction-journal-schema2.json",
               TransactionJournal().EncodeCanonical());
    WriteExact(output_directory / "transaction-registry-schema2.json",
               RegistryRecord().EncodeCanonical());
    EmitProviderJournal(output_directory);
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
