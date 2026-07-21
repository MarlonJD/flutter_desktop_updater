#include <gtest/gtest.h>

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>
#include <thread>

#include "linux_recovery_service.h"
#include "linux_relaunch_service.h"
#include "unix_socket_transport.h"

namespace desktop_updater::helper {
namespace {

LinuxVerifiedPayloadIdentity Payload(const std::string& version) {
  const char digit = version == "new" ? 'b' : version == "old" ? 'a' : 'f';
  return {"com.example.app",
          "release-key-1",
          std::string(64, digit),
          std::string(64, 'c'),
          std::string(64, 'd'),
          "bin/example",
          std::string(64, 'e'),
          static_cast<std::uint32_t>(S_IFREG | 0755),
          static_cast<std::uint32_t>(geteuid()),
          static_cast<std::uint32_t>(getegid())};
}

class FixtureVerifier final : public LinuxInstallPayloadVerifier {
 public:
  LinuxVerifiedPayloadIdentity Verify(int parent,
                                      const std::string& leaf) override {
    auto directory = OpenLinuxRelativeNoFollow(parent, leaf, O_PATH | O_DIRECTORY);
    return Payload(ReadLinuxRelativeUtf8(directory.get(), "version.txt", 32));
  }
};

class OneShotFault final : public LinuxTransactionFaultInjector {
 public:
  explicit OneShotFault(LinuxTransactionFaultPoint point) : point_(point) {}
  void Hit(LinuxTransactionFaultPoint point) override {
    if (!thrown_ && point == point_) {
      thrown_ = true;
      throw LinuxFileTransactionError("injected crash");
    }
  }

 private:
  LinuxTransactionFaultPoint point_;
  bool thrown_ = false;
};

class FixedLiveness final : public LinuxProcessLivenessChecker {
 public:
  explicit FixedLiveness(bool alive) : alive_(alive) {}
  bool IsSameProcessAlive(pid_t, std::uint64_t) override { return alive_; }

 private:
  bool alive_;
};

class Fixture {
 public:
  Fixture() {
    root = std::filesystem::temp_directory_path() /
           ("desktop-updater-recovery-" + std::to_string(getpid()) + "-" +
            std::to_string(counter_++));
    target = root / "Example.AppDir";
    stage = root / "Stage.AppDir";
    std::filesystem::create_directories(target);
    std::filesystem::create_directories(stage);
    Write(target, "old");
    Write(stage, "new");
  }
  ~Fixture() {
    std::error_code ignored;
    std::filesystem::remove_all(root, ignored);
  }
  void Write(const std::filesystem::path& directory,
             const std::string& value) {
    std::ofstream(directory / "version.txt", std::ios::binary) << value;
  }
  std::string Read(const std::filesystem::path& directory) {
    std::ifstream input(directory / "version.txt", std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(input),
                       std::istreambuf_iterator<char>());
  }
  std::unique_ptr<LinuxFileTransaction> Transaction(
      LinuxTransactionFaultInjector* fault) {
    return std::make_unique<LinuxFileTransaction>(
        target, stage, transaction_id, getpid(), Payload("new"), verifier,
        fault);
  }
  LinuxRecoveryService Recovery(LinuxProcessLivenessChecker& liveness) {
    return LinuxRecoveryService(target, transaction_id, Payload("new"),
                                verifier, liveness);
  }

  inline static unsigned int counter_ = 0;
  const std::string transaction_id =
      "00000000-0000-4000-8000-000000000010";
  std::filesystem::path root;
  std::filesystem::path target;
  std::filesystem::path stage;
  FixtureVerifier verifier;
};

TEST(LinuxCrashRecovery, RecoversEveryRenameAndJournalBoundary) {
  for (const auto point : LinuxTransactionCrashInjectionPoints()) {
    Fixture fixture;
    OneShotFault fault(point);
    auto transaction = fixture.Transaction(&fault);
    EXPECT_THROW(transaction->Execute(), std::exception);
    transaction.reset();
    FixedLiveness dead(false);
    const auto outcome = fixture.Recovery(dead).Recover();
    EXPECT_TRUE(outcome == LinuxRecoveryOutcome::kRecovered ||
                outcome == LinuxRecoveryOutcome::kNothingToRecover ||
                outcome == LinuxRecoveryOutcome::kManualActionRequired);
    if (outcome == LinuxRecoveryOutcome::kRecovered) {
      EXPECT_EQ("new", fixture.Read(fixture.target));
    }
  }
}

TEST(LinuxCrashRecovery, TornJournalIsManualWithoutCleanup) {
  const char tornJournal[] = "tornJournal";
  (void)tornJournal;
  Fixture fixture;
  const auto paths =
      LinuxTransactionPaths::Create("Example.AppDir", fixture.transaction_id);
  std::ofstream(fixture.root / paths.lock_name) << "lock";
  std::ofstream(fixture.root / paths.journal_name) << "{\"state\":\"pre";
  FixedLiveness dead(false);

  EXPECT_EQ(LinuxRecoveryOutcome::kManualActionRequired,
            fixture.Recovery(dead).Recover());
  EXPECT_EQ("old", fixture.Read(fixture.target));
  EXPECT_TRUE(std::filesystem::exists(fixture.root / paths.journal_name));
}

TEST(LinuxCrashRecovery, AmbiguousNextJournalIsManualWithoutCleanup) {
  Fixture fixture;
  const auto paths =
      LinuxTransactionPaths::Create("Example.AppDir", fixture.transaction_id);
  std::ofstream(fixture.root / paths.lock_name) << "lock";
  std::ofstream(fixture.root / paths.journal_next_name) << "partial";
  FixedLiveness dead(false);

  EXPECT_EQ(LinuxRecoveryOutcome::kManualActionRequired,
            fixture.Recovery(dead).Recover());
  EXPECT_EQ("old", fixture.Read(fixture.target));
}

TEST(LinuxCrashRecovery, DeadOwnerBeforeFirstJournalReleasesOnlyOrphanLock) {
  Fixture fixture;
  const auto paths =
      LinuxTransactionPaths::Create("Example.AppDir", fixture.transaction_id);
  const LinuxTransactionLockRecord record{
      fixture.transaction_id, getpid(), LinuxProcessStartIdentity(getpid())};
  std::ofstream(fixture.root / paths.lock_name, std::ios::binary)
      << record.EncodeCanonical();
  FixedLiveness dead(false);

  EXPECT_EQ(LinuxRecoveryOutcome::kNothingToRecover,
            fixture.Recovery(dead).Recover());
  EXPECT_EQ("old", fixture.Read(fixture.target));
  EXPECT_FALSE(std::filesystem::exists(fixture.root / paths.lock_name));
}

TEST(LinuxCrashRecovery, InvalidBackupIdentityIsManual) {
  const char invalidBackup[] = "invalidBackup";
  (void)invalidBackup;
  Fixture fixture;
  OneShotFault fault(LinuxTransactionFaultPoint::kAfterBackupRename);
  auto transaction = fixture.Transaction(&fault);
  EXPECT_THROW(transaction->Execute(), std::exception);
  const auto backup = fixture.root / transaction->paths().backup_name;
  transaction.reset();
  std::filesystem::remove_all(backup);
  std::filesystem::create_directories(backup);
  fixture.Write(backup, "attacker");
  FixedLiveness dead(false);

  EXPECT_EQ(LinuxRecoveryOutcome::kManualActionRequired,
            fixture.Recovery(dead).Recover());
  EXPECT_TRUE(std::filesystem::exists(backup));
  EXPECT_EQ("attacker", fixture.Read(backup));
}

TEST(LinuxCrashRecovery, LiveOwnerPreventsRecoveryOwnership) {
  Fixture fixture;
  OneShotFault fault(
      LinuxTransactionFaultPoint::kAfterPreparedJournalFlush);
  auto transaction = fixture.Transaction(&fault);
  EXPECT_THROW(transaction->Execute(), std::exception);
  transaction.reset();
  FixedLiveness alive(true);

  EXPECT_EQ(LinuxRecoveryOutcome::kLiveOwner,
            fixture.Recovery(alive).Recover());
  EXPECT_EQ("old", fixture.Read(fixture.target));
}

TEST(LinuxCrashRecovery, RecoveryIsIdempotent) {
  Fixture fixture;
  OneShotFault fault(LinuxTransactionFaultPoint::kAfterActivationRename);
  auto transaction = fixture.Transaction(&fault);
  EXPECT_THROW(transaction->Execute(), std::exception);
  transaction.reset();
  FixedLiveness dead(false);
  auto recovery = fixture.Recovery(dead);

  EXPECT_EQ(LinuxRecoveryOutcome::kRecovered, recovery.Recover());
  EXPECT_EQ(LinuxRecoveryOutcome::kNothingToRecover, recovery.Recover());
  EXPECT_EQ("new", fixture.Read(fixture.target));
}

class RecordingLauncher final : public LinuxProcessLauncher {
 public:
  void Launch(int executable_fd,
              const std::string&,
              const Identity& identity) override {
    launched_fd = executable_fd;
    launched_identity = identity;
  }
  int launched_fd = -1;
  Identity launched_identity;
};

TEST(LinuxCrashRecovery, RelaunchRequiresVerifiedExecutableDescriptor) {
  Fixture fixture;
  RecordingLauncher launcher;
  LinuxProcessLauncher::Identity identity;
  identity.source_process_id = getpid();
  identity.source_process_start_identity = LinuxProcessStartIdentity(getpid());
  identity.uid = geteuid();
  identity.gid = getegid();
  identity.home_directory = "/tmp";
  identity.sanitized_environment = {"HOME=/tmp", "PATH=/usr/bin:/bin"};
  LinuxRelaunchService service(Payload("new"), fixture.verifier, launcher,
                               identity);

  EXPECT_THROW(service.Relaunch(fixture.target), LinuxRelaunchError);
  EXPECT_EQ(-1, launcher.launched_fd);
}

TEST(LinuxCrashRecovery, CapturesSanitizedCurrentPeerIdentity) {
  const auto identity = CaptureLinuxRelaunchIdentity(
      getpid(), LinuxProcessStartIdentity(getpid()), geteuid(), getegid());
  EXPECT_EQ(geteuid(), identity.uid);
  EXPECT_EQ(getegid(), identity.gid);
  EXPECT_FALSE(identity.home_directory.empty());
  EXPECT_NE(identity.sanitized_environment.end(),
            std::find_if(identity.sanitized_environment.begin(),
                         identity.sanitized_environment.end(),
                         [](const std::string& value) {
                           return value.rfind("HOME=", 0) == 0;
                         }));
  EXPECT_EQ(identity.sanitized_environment.end(),
            std::find_if(identity.sanitized_environment.begin(),
                         identity.sanitized_environment.end(),
                         [](const std::string& value) {
                           return value.rfind("LD_PRELOAD=", 0) == 0;
                         }));
}

TEST(LinuxCrashRecovery, FexecveLauncherConfirmsChildExec) {
  const auto identity = CaptureLinuxRelaunchIdentity(
      getpid(), LinuxProcessStartIdentity(getpid()), geteuid(), getegid());
  auto executable = OpenLinuxRelativeNoFollow(
      OpenLinuxDirectory("/usr/bin").get(), "true", O_RDONLY);
  FexecveLinuxProcessLauncher launcher;
  EXPECT_NO_THROW(launcher.Launch(executable.get(), "true", identity));
}

TEST(LinuxCrashRecovery, RootLauncherDropsCredentialsAndSanitizesEnvironment) {
  if (geteuid() != 0) GTEST_SKIP() << "requires the privileged broker identity";

  constexpr uid_t kPeerUid = 65534;
  constexpr gid_t kPeerGid = 65534;
  const std::filesystem::path fixture =
      DESKTOP_UPDATER_COMMIT_CALLER_FIXTURE;
  const std::filesystem::path proof =
      std::filesystem::path("/tmp") /
      ("desktop-updater-root-relaunch-proof-" + std::to_string(getpid()) +
       ".txt");
  std::error_code ignored;
  std::filesystem::remove(proof, ignored);
  ASSERT_EQ(0,
            setenv("DESKTOP_UPDATER_ROOT_SECRET", "must-not-cross-exec", 1));

  LinuxProcessLauncher::Identity identity;
  identity.source_process_id = getpid();
  identity.source_process_start_identity = LinuxProcessStartIdentity(getpid());
  identity.uid = kPeerUid;
  identity.gid = kPeerGid;
  identity.supplementary_groups = {kPeerGid};
  identity.home_directory = "/tmp";
  identity.sanitized_environment = {
      "HOME=/tmp", "USER=nobody", "LOGNAME=nobody",
      "PATH=/usr/local/bin:/usr/bin:/bin",
      "DESKTOP_UPDATER_TEST_RELAUNCH_PROOF=" + proof.string()};

  auto parent = OpenLinuxDirectory(fixture.parent_path().string());
  auto executable = OpenLinuxRelativeNoFollow(
      parent.get(), fixture.filename().string(), O_RDONLY);
  FexecveLinuxProcessLauncher launcher;
  ASSERT_NO_THROW(
      launcher.Launch(executable.get(), fixture.filename().string(), identity));

  for (int attempt = 0; attempt != 100 && !std::filesystem::exists(proof);
       ++attempt) {
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  ASSERT_TRUE(std::filesystem::exists(proof));
  std::ifstream input(proof, std::ios::binary);
  const std::string observed{std::istreambuf_iterator<char>(input),
                             std::istreambuf_iterator<char>()};
  EXPECT_NE(std::string::npos,
            observed.find("uid=" + std::to_string(kPeerUid) + "\n"));
  EXPECT_NE(std::string::npos,
            observed.find("euid=" + std::to_string(kPeerUid) + "\n"));
  EXPECT_NE(std::string::npos,
            observed.find("gid=" + std::to_string(kPeerGid) + "\n"));
  EXPECT_NE(std::string::npos,
            observed.find("egid=" + std::to_string(kPeerGid) + "\n"));
  EXPECT_NE(std::string::npos,
            observed.find("groups=" + std::to_string(kPeerGid) + "\n"));
  EXPECT_NE(std::string::npos, observed.find("secret=absent\n"));

  int status = 0;
  while (waitpid(-1, &status, WNOHANG) > 0) {
  }
  unsetenv("DESKTOP_UPDATER_ROOT_SECRET");
  std::filesystem::remove(proof, ignored);
}

}  // namespace
}  // namespace desktop_updater::helper
