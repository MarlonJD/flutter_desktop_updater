#include <gtest/gtest.h>

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <array>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <utility>
#include <vector>

#include "miniz.h"

#include "linux_archive_restage.h"
#include "linux_transaction_journal.h"
#include "stage_provenance.h"
#include "unix_socket_transport.h"

namespace desktop_updater::helper {
namespace {

namespace fs = std::filesystem;
using runtime::internal::FilesystemOwnedStage;
using runtime::internal::StageProvenanceMarker;
using runtime::internal::StageProvenanceState;
using runtime::internal::WriteStageProvenance;

std::vector<std::uint8_t> Sha256Vector(const std::string& bytes) {
  const std::string hex = Sha256LinuxBytes(bytes);
  std::vector<std::uint8_t> result;
  result.reserve(32);
  for (std::size_t index = 0; index < hex.size(); index += 2) {
    result.push_back(static_cast<std::uint8_t>(
        std::stoul(hex.substr(index, 2), nullptr, 16)));
  }
  return result;
}

std::string ReadFile(const fs::path& path) {
  std::ifstream input(path, std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

void WriteFile(const fs::path& path,
               const std::string& bytes,
               mode_t mode = 0600) {
  fs::create_directories(path.parent_path());
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  output << bytes;
  output.close();
  ASSERT_TRUE(output.good());
  ASSERT_EQ(0, chmod(path.c_str(), mode));
}

struct ZipEntry {
  std::string path;
  std::string bytes;
  std::uint32_t mode = 0100644;
};

void WriteZip(const fs::path& path, const std::vector<ZipEntry>& entries) {
  mz_zip_archive archive{};
  ASSERT_TRUE(mz_zip_writer_init_file(&archive, path.c_str(), 0));
  std::vector<std::string> stored_names;
  for (const auto& entry : entries) {
    const std::string stored_name =
        !entry.path.empty() && entry.path.front() == '/'
            ? "x" + entry.path.substr(1)
            : entry.path;
    stored_names.push_back(stored_name);
    ASSERT_TRUE(mz_zip_writer_add_mem_ex(
        &archive, stored_name.c_str(), entry.bytes.data(), entry.bytes.size(),
        nullptr, 0, MZ_BEST_COMPRESSION, 0, 0));
  }
  ASSERT_TRUE(mz_zip_writer_finalize_archive(&archive));
  ASSERT_TRUE(mz_zip_writer_end(&archive));
  std::fstream file(path, std::ios::in | std::ios::out | std::ios::binary);
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
  ASSERT_EQ(entries.size(), entry_index);
  for (std::size_t entry = 0; entry < entries.size(); ++entry) {
    if (stored_names[entry] == entries[entry].path) continue;
    const std::string& from = stored_names[entry];
    const std::string& to = entries[entry].path;
    ASSERT_EQ(from.size(), to.size());
    for (std::size_t offset = 0; offset + from.size() <= bytes.size();
         ++offset) {
      if (std::equal(from.begin(), from.end(), bytes.begin() + offset)) {
        std::copy(to.begin(), to.end(), bytes.begin() + offset);
      }
    }
  }
  file.clear();
  file.seekp(0);
  file.write(reinterpret_cast<const char*>(bytes.data()), bytes.size());
  file.close();
  ASSERT_TRUE(file.good());
  ASSERT_EQ(0, chmod(path.c_str(), 0600));
}

class Fixture {
 public:
  Fixture() {
    root = fs::temp_directory_path() /
           ("desktop-updater-archive-restage-" + std::to_string(getpid()) +
            "-" + std::to_string(counter_++));
    source = root / "desktop_updater_stage_123e4567-e89b-42d3-a456-426614174000";
    target_parent = root / "target-parent";
    fs::create_directories(source);
    fs::create_directories(target_parent / "Example.AppDir");
    chmod(root.c_str(), 0700);
    chmod(source.c_str(), 0700);
    chmod(target_parent.c_str(), 0700);
  }

  ~Fixture() {
    std::error_code ignored;
    fs::remove_all(root, ignored);
  }

  LinuxArchiveRestageRequest Request(
      const std::vector<ZipEntry>& entries,
      bool include_caller_injected_file = false) {
    const fs::path archive = source / kLinuxRetainedArtifactName;
    WriteZip(archive, entries);
    for (const auto& entry : entries) {
      if (entry.path == kLinuxRetainedArtifactName ||
          entry.path == kLinuxReleaseManifestName ||
          entry.path == kLinuxStageProvenanceName ||
          entry.path == kLinuxPayloadSealName) {
        continue;
      }
      if ((entry.mode & 0170000) == 0040000) {
        fs::create_directories(source / entry.path);
      } else if (entry.path.find("..") == std::string::npos &&
                 !entry.path.empty() && entry.path.front() != '/') {
        WriteFile(source / entry.path, entry.bytes,
                  static_cast<mode_t>(entry.mode & 0777));
      }
    }
    if (include_caller_injected_file) {
      WriteFile(source / "libcaller_injected.so", "injected", 0755);
    }
    WriteFile(source / kLinuxReleaseManifestName, manifest);
    const StageProvenanceState caller = WriteStageProvenance(
        FilesystemOwnedStage{source, root,
                             "123e4567-e89b-42d3-a456-426614174000"},
        "com.example.app", Sha256LinuxBytes(manifest),
        Sha256LinuxFile(archive), Sha256Vector);
    source_fd = OpenLinuxDirectory(source.string());
    parent_fd = OpenLinuxDirectory(target_parent.string());
    LinuxArchiveRestageRequest request;
    request.source_stage_fd = source_fd.get();
    request.target_parent_fd = parent_fd.get();
    request.target_parent_path = target_parent;
    request.target_name = "Example.AppDir";
    request.transaction_id = "00000000-0000-4000-8000-000000000041";
    request.package_id = "com.example.app";
    request.canonical_release_manifest = manifest;
    request.descriptor_sha256 = Sha256LinuxBytes(manifest);
    request.artifact_sha256 = Sha256LinuxFile(archive);
    request.artifact_length =
        static_cast<std::int64_t>(fs::file_size(archive));
    request.executable_relative_path = "bin/example";
    request.caller_marker = caller.marker;
    request.source_uid = geteuid();
    request.source_gid = getegid();
    request.payload_uid = geteuid();
    request.payload_gid = getegid();
    request.broker_mode = false;
    return request;
  }

  inline static unsigned int counter_ = 0;
  fs::path root;
  fs::path source;
  fs::path target_parent;
  UniqueLinuxFd source_fd;
  UniqueLinuxFd parent_fd;
  const std::string manifest =
      "{\"artifact\":{\"kind\":\"zip\"},\"schemaVersion\":3}";
};

class ExitAtRestageFault final : public LinuxArchiveRestageFaultInjector {
 public:
  explicit ExitAtRestageFault(LinuxArchiveRestageFaultPoint selected)
      : selected_(selected) {}

  void OnLinuxArchiveRestageFault(
      LinuxArchiveRestageFaultPoint point) override {
    if (point == selected_) _exit(91);
  }

 private:
  LinuxArchiveRestageFaultPoint selected_;
};

class ExitAtRestageFaultOccurrence final
    : public LinuxArchiveRestageFaultInjector {
 public:
  ExitAtRestageFaultOccurrence(LinuxArchiveRestageFaultPoint selected,
                               int occurrence)
      : selected_(selected), occurrence_(occurrence) {}

  void OnLinuxArchiveRestageFault(
      LinuxArchiveRestageFaultPoint point) override {
    if (point == selected_ && ++observed_ == occurrence_) _exit(94);
  }

 private:
  LinuxArchiveRestageFaultPoint selected_;
  int occurrence_;
  int observed_ = 0;
};

class InjectExtraPayloadFault final : public LinuxArchiveRestageFaultInjector {
 public:
  explicit InjectExtraPayloadFault(fs::path payload) : payload_(std::move(payload)) {}

  void OnLinuxArchiveRestageFault(
      LinuxArchiveRestageFaultPoint point) override {
    if (injected_ || point !=
                         LinuxArchiveRestageFaultPoint::kAfterFirstExtractedEntry) {
      return;
    }
    injected_ = true;
    std::ofstream output(payload_ / "caller-race.txt",
                         std::ios::binary | std::ios::trunc);
    output << "not from archive";
    output.close();
    if (!output || chmod((payload_ / "caller-race.txt").c_str(), 0600) != 0) {
      throw std::runtime_error("unable to inject payload race fixture");
    }
  }

 private:
  fs::path payload_;
  bool injected_ = false;
};

class InjectDeepPayloadFault final : public LinuxArchiveRestageFaultInjector {
 public:
  explicit InjectDeepPayloadFault(fs::path payload)
      : payload_(std::move(payload)) {}

  void OnLinuxArchiveRestageFault(
      LinuxArchiveRestageFaultPoint point) override {
    if (injected_ || point !=
                         LinuxArchiveRestageFaultPoint::kAfterFirstExtractedEntry) {
      return;
    }
    injected_ = true;
    fs::path current = payload_ / "concurrent-deep-tree";
    if (!fs::create_directory(current)) {
      throw std::runtime_error("unable to inject deep payload fixture");
    }
    for (int depth = 0; depth < 140; ++depth) {
      current /= "d";
      if (!fs::create_directory(current)) {
        throw std::runtime_error("unable to inject deep payload fixture");
      }
    }
  }

 private:
  fs::path payload_;
  bool injected_ = false;
};

TEST(LinuxArchiveRestage,
     ExtractsOnlyVerifiedArchiveAndRecreatesHelperOwnedBindings) {
  Fixture fixture;
  auto payload = RestageLinuxSignedZip(fixture.Request(
      {{"bin/example", "signed executable", 0100755},
       {"share/data.txt", "signed data", 0100644}}));

  ASSERT_NE(nullptr, payload);
  EXPECT_EQ("signed executable", ReadFile(payload->path() / "bin/example"));
  EXPECT_EQ("signed data", ReadFile(payload->path() / "share/data.txt"));
  for (const char* control_name : {
           kLinuxRetainedArtifactName, kLinuxReleaseManifestName,
           kLinuxStageProvenanceName, kLinuxPayloadSealName}) {
    EXPECT_FALSE(fs::exists(payload->path() / control_name)) << control_name;
  }
  EXPECT_TRUE(fs::exists(payload->control_path() /
                         kLinuxRetainedArtifactName));
  EXPECT_EQ(fixture.manifest,
            ReadFile(payload->control_path() / kLinuxReleaseManifestName));
  EXPECT_EQ(64u, payload->payload_seal_sha256().size());
  EXPECT_TRUE(fs::exists(payload->control_path() / kLinuxPayloadSealName));
  EXPECT_EQ(payload->artifact_sha256(),
            Sha256LinuxFile(payload->control_path() /
                            kLinuxRetainedArtifactName));
  const LinuxFileIdentity identity =
      ReadLinuxRelativeIdentity(fixture.parent_fd.get(),
                                payload->path().filename().string());
  EXPECT_EQ(geteuid(), static_cast<uid_t>(identity.uid));
  EXPECT_EQ(getegid(), static_cast<gid_t>(identity.gid));
  EXPECT_EQ(0u, identity.mode & (S_ISUID | S_ISGID | S_ISVTX));
}

TEST(LinuxArchiveRestage, IgnoresCallerFilesNotProducedBySignedArchive) {
  Fixture fixture;
  const auto request = fixture.Request(
      {{"bin/example", "signed executable", 0100755}}, true);

  auto payload = RestageLinuxSignedZip(request);
  ASSERT_NE(nullptr, payload);
  EXPECT_EQ("signed executable", ReadFile(payload->path() / "bin/example"));
  EXPECT_FALSE(fs::exists(payload->path() / "libcaller_injected.so"));
  EXPECT_TRUE(fs::exists(fixture.source / "libcaller_injected.so"));
}

TEST(LinuxArchiveRestage, RejectsArtifactDigestAndLengthDrift) {
  {
    Fixture fixture;
    auto request = fixture.Request(
        {{"bin/example", "signed executable", 0100755}});
    request.artifact_sha256 = std::string(64, 'a');
    EXPECT_THROW(RestageLinuxSignedZip(request), LinuxArchiveRestageError);
  }
  {
    Fixture fixture;
    auto request = fixture.Request(
        {{"bin/example", "signed executable", 0100755}});
    ++request.artifact_length;
    EXPECT_THROW(RestageLinuxSignedZip(request), LinuxArchiveRestageError);
  }
}

class UnsafeArchiveTest : public ::testing::TestWithParam<std::string> {};

TEST_P(UnsafeArchiveTest, RejectsUnsafeEntryBeforePayloadActivation) {
  Fixture fixture;
  const std::string entry = GetParam();
  const auto request = fixture.Request(
      {{entry, "unsafe", 0100644},
       {"bin/example", "signed executable", 0100755}});

  EXPECT_THROW(RestageLinuxSignedZip(request), LinuxArchiveRestageError);
}

INSTANTIATE_TEST_SUITE_P(
    PathPolicy,
    UnsafeArchiveTest,
    ::testing::Values("../escape", "/absolute", "foo//bar", "foo/./bar",
                      ".desktop_updater_artifact.zip",
                      ".desktop_updater_release_manifest.json",
                      ".desktop_updater_stage_provenance.json"));

TEST(LinuxArchiveRestage, PreservesLinuxColonPathComponents) {
  Fixture fixture;
  const auto request = fixture.Request(
      {{"bin/example", "signed executable", 0100755},
       {"share/name:part", "linux path", 0100644}});

  auto payload = RestageLinuxSignedZip(request);
  ASSERT_NE(nullptr, payload);
  EXPECT_EQ("linux path", ReadFile(payload->path() / "share/name:part"));
}

TEST(LinuxArchiveRestage,
     AppliesRestrictiveDirectoryModeAfterExtractingChildren) {
  Fixture fixture;
  const auto request = fixture.Request(
      {{"bin/", "", 0040500},
       {"bin/example", "signed executable", 0100755}});

  auto payload = RestageLinuxSignedZip(request);
  ASSERT_NE(nullptr, payload);
  EXPECT_EQ("signed executable", ReadFile(payload->path() / "bin/example"));
  struct stat directory {};
  ASSERT_EQ(0, stat((payload->path() / "bin").c_str(), &directory));
  EXPECT_EQ(0500, directory.st_mode & 0777);
}

TEST(LinuxArchiveRestage, PreservesDistinctLinuxCaseSensitiveEntries) {
  Fixture fixture;
  const auto request = fixture.Request(
      {{"Lib/Plugin.so", "first", 0100644},
       {"lib/plugin.so", "second", 0100644},
       {"bin/example", "signed executable", 0100755}});

  auto payload = RestageLinuxSignedZip(request);
  ASSERT_NE(nullptr, payload);
  EXPECT_EQ("first", ReadFile(payload->path() / "Lib/Plugin.so"));
  EXPECT_EQ("second", ReadFile(payload->path() / "lib/plugin.so"));
}

TEST(LinuxArchiveRestage, RejectsSymlinkAndSpecialModeEntries) {
  for (const std::uint32_t mode : {std::uint32_t{0120777},
                                   std::uint32_t{0010666}}) {
    Fixture fixture;
    const auto request = fixture.Request(
        {{"unsafe", "target", mode},
         {"bin/example", "signed executable", 0100755}});
    EXPECT_THROW(RestageLinuxSignedZip(request), LinuxArchiveRestageError);
  }
}

TEST(LinuxArchiveRestage, CleansOnlyExactHelperStageOnCancellation) {
  Fixture fixture;
  fs::path stage;
  {
    auto payload = RestageLinuxSignedZip(fixture.Request(
        {{"bin/example", "signed executable", 0100755}}));
    stage = payload->path();
    ASSERT_TRUE(fs::exists(stage));
  }
  EXPECT_FALSE(fs::exists(stage));
  EXPECT_TRUE(fs::exists(fixture.source));
  EXPECT_TRUE(fs::exists(fixture.target_parent / "Example.AppDir"));
  EXPECT_FALSE(fs::exists(
      fixture.target_parent /
      LinuxArchiveRestageRecordLeaf(
          "00000000-0000-4000-8000-000000000041")));
}

TEST(LinuxArchiveRestage,
     PreJournalProcessDeathIsCleanedByExactBoundRetry) {
  for (const LinuxArchiveRestageFaultPoint point : {
           LinuxArchiveRestageFaultPoint::kAfterRecoveryRecord,
           LinuxArchiveRestageFaultPoint::
               kAfterPayloadDirectoryMkdirBeforeCookie,
           LinuxArchiveRestageFaultPoint::kAfterPayloadDirectoryCreate,
           LinuxArchiveRestageFaultPoint::
               kAfterControlDirectoryMkdirBeforeCookie,
           LinuxArchiveRestageFaultPoint::kAfterControlDirectoryCreate,
           LinuxArchiveRestageFaultPoint::kAfterProtectedCopy,
           LinuxArchiveRestageFaultPoint::kAfterArchivePreflight,
           LinuxArchiveRestageFaultPoint::kAfterFirstExtractedEntry,
           LinuxArchiveRestageFaultPoint::kAfterPayloadSeal}) {
    Fixture fixture;
    auto request = fixture.Request(
        {{"bin/example", "signed executable", 0100755},
         {"share/data.txt", "signed data", 0100644}});
    const pid_t child = fork();
    ASSERT_GE(child, 0);
    if (child == 0) {
      ExitAtRestageFault fault(point);
      request.fault_injector = &fault;
      try {
        (void)RestageLinuxSignedZip(request);
      } catch (...) {
        _exit(92);
      }
      _exit(93);
    }
    int status = 0;
    ASSERT_EQ(child, waitpid(child, &status, 0));
    ASSERT_TRUE(WIFEXITED(status));
    ASSERT_EQ(91, WEXITSTATUS(status));

    request.fault_injector = nullptr;
    auto recovered = RestageLinuxSignedZip(request);
    ASSERT_NE(nullptr, recovered);
    EXPECT_EQ("signed executable",
              ReadFile(recovered->path() / "bin/example"));
    EXPECT_EQ("signed data",
              ReadFile(recovered->path() / "share/data.txt"));
    EXPECT_TRUE(fs::exists(
        fixture.target_parent /
        LinuxArchiveRestageRecordLeaf(request.transaction_id)));
    recovered->CleanupCancelled();
    EXPECT_FALSE(fs::exists(
        fixture.target_parent /
        LinuxArchiveRestageRecordLeaf(request.transaction_id)));
  }
}

TEST(LinuxArchiveRestage,
     NamedRecoveryRecordNextIsBoundedAndRetrySafeAfterProcessDeath) {
  for (int occurrence = 1; occurrence <= 3; ++occurrence) {
    Fixture fixture;
    auto request = fixture.Request(
        {{"bin/example", "signed executable", 0100755},
         {"share/data.txt", "signed data", 0100644}});
    request.disable_recovery_record_o_tmpfile_for_testing = true;
    const pid_t child = fork();
    ASSERT_GE(child, 0);
    if (child == 0) {
      ExitAtRestageFaultOccurrence fault(
          LinuxArchiveRestageFaultPoint::
              kAfterRecoveryRecordNextSyncBeforeRename,
          occurrence);
      request.fault_injector = &fault;
      try {
        (void)RestageLinuxSignedZip(request);
      } catch (...) {
        _exit(92);
      }
      _exit(93);
    }
    int status = 0;
    ASSERT_EQ(child, waitpid(child, &status, 0));
    ASSERT_TRUE(WIFEXITED(status));
    ASSERT_EQ(94, WEXITSTATUS(status));

    const fs::path next = fixture.target_parent /
        (LinuxArchiveRestageRecordLeaf(request.transaction_id) + ".next");
    EXPECT_TRUE(fs::exists(next));
    request.fault_injector = nullptr;
    auto recovered = RestageLinuxSignedZip(request);
    ASSERT_NE(nullptr, recovered);
    EXPECT_FALSE(fs::exists(next));
    recovered->CleanupCancelled();
  }
}

TEST(LinuxArchiveRestage,
     PortableRetryDoesNotDeleteReplacementPayloadIdentity) {
  Fixture fixture;
  auto request = fixture.Request(
      {{"bin/example", "signed executable", 0100755}});
  const pid_t child = fork();
  ASSERT_GE(child, 0);
  if (child == 0) {
    ExitAtRestageFault fault(
        LinuxArchiveRestageFaultPoint::kAfterProtectedCopy);
    request.fault_injector = &fault;
    try {
      (void)RestageLinuxSignedZip(request);
    } catch (...) {
      _exit(92);
    }
    _exit(93);
  }
  int status = 0;
  ASSERT_EQ(child, waitpid(child, &status, 0));
  ASSERT_TRUE(WIFEXITED(status));
  ASSERT_EQ(91, WEXITSTATUS(status));

  const fs::path payload = fixture.target_parent /
      ("desktop_updater_stage_" + request.transaction_id);
  std::error_code ignored;
  fs::remove_all(payload, ignored);
  fs::create_directories(payload);
  ASSERT_EQ(0, chmod(payload.c_str(), 0700));
  WriteFile(payload / "replacement.txt", "do not delete", 0600);

  request.fault_injector = nullptr;
  EXPECT_THROW(RestageLinuxSignedZip(request), LinuxArchiveRestageError);
  EXPECT_EQ("do not delete", ReadFile(payload / "replacement.txt"));
}

TEST(LinuxArchiveRestage,
     CleanupFailurePreservesRecoveryRecordAndReplacementIdentity) {
  Fixture fixture;
  const auto request = fixture.Request(
      {{"bin/example", "signed executable", 0100755}});
  auto payload = RestageLinuxSignedZip(request);
  const fs::path payload_path = payload->path();
  const fs::path recovery_record = fixture.target_parent /
      LinuxArchiveRestageRecordLeaf(request.transaction_id);
  std::error_code ignored;
  fs::remove_all(payload_path, ignored);
  fs::create_directories(payload_path);
  ASSERT_EQ(0, chmod(payload_path.c_str(), 0700));
  WriteFile(payload_path / "replacement.txt", "preserve", 0600);

  EXPECT_THROW(payload->CleanupCancelled(), LinuxArchiveRestageError);
  EXPECT_EQ("preserve", ReadFile(payload_path / "replacement.txt"));
  EXPECT_TRUE(fs::exists(recovery_record));
}

TEST(LinuxArchiveRestage,
     JournalOwnershipTransferPreservesArtifactsWhenRecordCleanupFails) {
  Fixture fixture;
  const auto request = fixture.Request(
      {{"bin/example", "signed executable", 0100755}});
  auto payload = RestageLinuxSignedZip(request);
  const fs::path payload_path = payload->path();
  const fs::path control_path = payload->control_path();
  const fs::path recovery_record = fixture.target_parent /
      LinuxArchiveRestageRecordLeaf(request.transaction_id);
  const auto paths =
      LinuxTransactionPaths::Create(request.target_name, request.transaction_id);
  WriteFile(fixture.target_parent / paths.journal_name, "durable journal", 0600);
  ASSERT_TRUE(fs::remove(recovery_record));
  WriteFile(recovery_record, "replacement", 0600);

  EXPECT_THROW(payload->ArmForRecovery(), LinuxArchiveRestageError);
  payload.reset();

  EXPECT_TRUE(fs::exists(fixture.target_parent / paths.journal_name));
  EXPECT_TRUE(fs::exists(payload_path));
  EXPECT_TRUE(fs::exists(control_path));
  EXPECT_EQ("replacement", ReadFile(recovery_record));
}

TEST(LinuxArchiveRestage, RejectsSealBeyondConfiguredDurableBound) {
  Fixture fixture;
  auto request = fixture.Request(
      {{"bin/example", "signed executable", 0100755},
       {"share/data.txt", "signed data", 0100644}});
  request.maximum_payload_seal_bytes = 128;

  EXPECT_THROW(RestageLinuxSignedZip(request), LinuxArchiveRestageError);
  EXPECT_FALSE(fs::exists(
      fixture.target_parent /
      LinuxArchiveRestageRecordLeaf(request.transaction_id)));
}

TEST(LinuxArchiveRestage,
     RejectsConcurrentExtraEntryInsteadOfHelperSealingIt) {
  Fixture fixture;
  auto request = fixture.Request(
      {{"bin/example", "signed executable", 0100755},
       {"share/data.txt", "signed data", 0100644}});
  const fs::path payload_path = fixture.target_parent /
      ("desktop_updater_stage_" + request.transaction_id);
  InjectExtraPayloadFault fault(payload_path);
  request.fault_injector = &fault;

  EXPECT_THROW(RestageLinuxSignedZip(request), LinuxArchiveRestageError);
  EXPECT_FALSE(fs::exists(payload_path));
}

TEST(LinuxArchiveRestage,
     RejectsConcurrentDeepTreeWithinBoundedInventoryWalk) {
  Fixture fixture;
  auto request = fixture.Request(
      {{"bin/example", "signed executable", 0100755},
       {"share/data.txt", "signed data", 0100644}});
  const fs::path payload_path = fixture.target_parent /
      ("desktop_updater_stage_" + request.transaction_id);
  InjectDeepPayloadFault fault(payload_path);
  const fs::path recovery_record = fixture.target_parent /
      LinuxArchiveRestageRecordLeaf(request.transaction_id);
  const pid_t child = fork();
  ASSERT_GE(child, 0);
  if (child == 0) {
    request.fault_injector = &fault;
    try {
      (void)RestageLinuxSignedZip(request);
      _exit(96);
    } catch (const LinuxArchiveManualCleanupRequiredError& error) {
      if (error.payload_leaf() != payload_path.filename().string() ||
          error.recovery_record_leaf() !=
              LinuxArchiveRestageRecordLeaf(request.transaction_id)) {
        _exit(97);
      }
      _exit(95);
    } catch (...) {
      _exit(98);
    }
  }
  int status = 0;
  ASSERT_EQ(child, waitpid(child, &status, 0));
  ASSERT_TRUE(WIFEXITED(status));
  ASSERT_EQ(95, WEXITSTATUS(status));
  EXPECT_TRUE(fs::exists(payload_path / "bin/example"));
  fs::path deepest = payload_path / "concurrent-deep-tree";
  for (int depth = 0; depth < 140; ++depth) deepest /= "d";
  EXPECT_TRUE(fs::exists(deepest));
  EXPECT_TRUE(fs::exists(recovery_record));

  request.fault_injector = nullptr;
  EXPECT_THROW(RestageLinuxSignedZip(request),
               LinuxArchiveManualCleanupRequiredError);
  EXPECT_TRUE(fs::exists(deepest));
  EXPECT_TRUE(fs::exists(recovery_record));

  std::error_code ignored;
  fs::remove_all(payload_path, ignored);
  ASSERT_FALSE(ignored);
  auto recovered = RestageLinuxSignedZip(request);
  ASSERT_NE(nullptr, recovered);
  recovered->CleanupCancelled();
  EXPECT_FALSE(fs::exists(recovery_record));
}

TEST(LinuxArchiveRestage,
     RecoveryRecordCannotBeDiscardedWhileBoundResidueExists) {
  Fixture fixture;
  const auto request = fixture.Request(
      {{"bin/example", "signed executable", 0100755}});
  auto payload = RestageLinuxSignedZip(request);
  const fs::path recovery_record = fixture.target_parent /
      LinuxArchiveRestageRecordLeaf(request.transaction_id);

  EXPECT_THROW(
      CleanupLinuxArchiveRestageRecord(fixture.parent_fd.get(), request),
      LinuxArchiveManualCleanupRequiredError);
  EXPECT_TRUE(fs::exists(payload->path()));
  EXPECT_TRUE(fs::exists(payload->control_path()));
  EXPECT_TRUE(fs::exists(recovery_record));

  payload->CleanupCancelled();
}

TEST(LinuxArchiveRestage, RejectsLegacyCallerMarkerAsHelperPayloadSeal) {
  Fixture fixture;
  const auto request = fixture.Request(
      {{"bin/example", "signed executable", 0100755}});
  auto payload = RestageLinuxSignedZip(request);
  const std::string caller_marker_sha = Sha256LinuxFile(
      fixture.source / kLinuxStageProvenanceName);
  ASSERT_NE(caller_marker_sha, payload->payload_seal_sha256());

  EXPECT_THROW(
      VerifyLinuxArchivePayload(
          fixture.parent_fd.get(), payload->path().filename().string(),
          payload->control_path().filename().string(), request,
          caller_marker_sha),
      LinuxArchiveRestageError);
}

}  // namespace
}  // namespace desktop_updater::helper
