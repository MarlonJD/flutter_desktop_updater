#include <gtest/gtest.h>

#include <sys/types.h>
#include <unistd.h>

#include <filesystem>
#include <fstream>
#include <string>

#include "linux_reservation.h"

namespace desktop_updater::helper {
namespace {

class Fixture {
 public:
  Fixture() {
    root = std::filesystem::temp_directory_path() /
           ("desktop-updater-linux-reservation-" + std::to_string(getpid()));
    std::filesystem::remove_all(root);
    std::filesystem::create_directories(root / "Target.AppImage");
    std::filesystem::create_directories(root / "Stage.AppImage");
  }
  ~Fixture() { std::filesystem::remove_all(root); }

  LinuxReservationRequest Request(
      std::string transaction_id =
          "00000000-0000-4000-8000-000000000009",
      char nonce_fill = 'A') const {
    return {std::move(transaction_id), root, "Target.AppImage",
            root / "Stage.AppImage", getpid(), std::string(43, nonce_fill),
            4'000'000'000'000LL, false};
  }

  std::filesystem::path root;
};

TEST(LinuxHelperReservation, PinsAuthorityBeforeReadyToken) {
  Fixture fixture;
  LinuxReservationStore store;
  auto reservation = store.Prepare(fixture.Request());

  EXPECT_TRUE(reservation->ready_token_after_durable_journal());
  EXPECT_TRUE(reservation->has_target_parent_fd());
  EXPECT_TRUE(reservation->has_stage_fd());
  EXPECT_TRUE(reservation->has_lock_fd());
  EXPECT_TRUE(reservation->has_journal_fd());
  EXPECT_TRUE(reservation->has_pidfd_or_start_identity());
  EXPECT_EQ(43u, reservation->ready_token().size());
}

TEST(LinuxHelperReservation, RejectsTargetRaceNonceReplayAndRootAppImage) {
  Fixture fixture;
  LinuxReservationStore store;
  auto first = store.Prepare(fixture.Request());
  EXPECT_THROW(store.Prepare(fixture.Request(
                   "00000000-0000-4000-8000-000000000010", 'B')),
               LinuxReservationError);
  std::filesystem::create_directories(fixture.root / "Other.AppImage");
  auto replay = fixture.Request("00000000-0000-4000-8000-000000000011");
  replay.target_leaf = "Other.AppImage";
  EXPECT_THROW(store.Prepare(replay), LinuxReservationError);
  auto root_owned = fixture.Request(
      "00000000-0000-4000-8000-000000000012", 'C');
  root_owned.root_owned_target = true;
  EXPECT_THROW(store.Prepare(root_owned), LinuxReservationError);
}

TEST(LinuxHelperReservation, CancellationDeletesOnlyDerivedState) {
  Fixture fixture;
  LinuxReservationStore store;
  auto reservation = store.Prepare(fixture.Request());
  const auto unrelated = fixture.root / "unrelated.txt";
  std::ofstream(unrelated) << "preserve";

  store.Cancel(reservation->transaction_id(), reservation->ready_token());

  EXPECT_TRUE(std::filesystem::exists(unrelated));
  EXPECT_EQ(LinuxReservationState::kCancelled, reservation->state());
}

TEST(LinuxHelperReservation, ExpiryAndCallerDeathFailClosed) {
  Fixture fixture;
  LinuxReservationStore store;
  auto expired = store.Prepare(fixture.Request());
  EXPECT_THROW(store.Commit(expired->transaction_id(), expired->ready_token(),
                            4'000'000'000'001LL),
               LinuxReservationError);
  EXPECT_EQ(LinuxReservationState::kExpired, expired->state());

  auto second = store.Prepare(fixture.Request(
      "00000000-0000-4000-8000-000000000010", 'B'));
  store.CallerExited(second->transaction_id());
  EXPECT_EQ(LinuxReservationState::kCancelled, second->state());
}

}  // namespace
}  // namespace desktop_updater::helper
