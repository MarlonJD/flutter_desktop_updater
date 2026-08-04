#include <gtest/gtest.h>

#include <windows.h>

#include <filesystem>
#include <fstream>
#include <string>

#include "windows_reservation.h"

namespace desktop_updater::helper {
namespace {

class TemporaryReservationTree {
 public:
  TemporaryReservationTree() {
    const auto base = std::filesystem::temp_directory_path();
    root = base / (L"desktop-updater-reservation-" +
                   std::to_wstring(GetCurrentProcessId()));
    std::filesystem::remove_all(root);
    std::filesystem::create_directories(root / L"Target.app");
    std::filesystem::create_directories(root / L"Stage.app");
  }

  ~TemporaryReservationTree() { std::filesystem::remove_all(root); }

  WindowsReservationRequest Request(
      std::string transaction_id,
      char nonce_fill = 'A',
      std::wstring target_leaf = L"Target.app") const {
    return WindowsReservationRequest{
        std::move(transaction_id),
        root,
        std::move(target_leaf),
        root / L"Stage.app",
        GetCurrentProcessId(),
        std::string(43, nonce_fill),
        4'000'000'000'000LL,
    };
  }

  std::filesystem::path root;
};

TEST(WindowsHelperReservation, RetainsAuthorityBeforeReturningReadyToken) {
  TemporaryReservationTree tree;
  WindowsReservationStore store;

  auto reservation = store.Prepare(
      tree.Request("00000000-0000-4000-8000-000000000007"));

  EXPECT_TRUE(reservation->journal_durable_before_ready_token());
  EXPECT_TRUE(reservation->has_caller_process_handle());
  EXPECT_TRUE(reservation->has_target_parent_handle());
  EXPECT_TRUE(reservation->has_stage_handle());
  EXPECT_TRUE(reservation->has_target_lock_handle());
  EXPECT_TRUE(reservation->has_journal_handle());
  EXPECT_EQ(43u, reservation->ready_token().size());
}

TEST(WindowsHelperReservation, RejectsTargetRaceNonceReuseAndDuplicateCommit) {
  TemporaryReservationTree tree;
  WindowsReservationStore store;
  auto first = store.Prepare(
      tree.Request("00000000-0000-4000-8000-000000000007"));

  EXPECT_THROW(store.Prepare(
                   tree.Request("00000000-0000-4000-8000-000000000008", 'B')),
               WindowsReservationError);
  EXPECT_THROW(store.Prepare(
                   tree.Request("00000000-0000-4000-8000-000000000007", 'C')),
               WindowsReservationError);
  std::filesystem::create_directories(tree.root / L"Other.app");
  EXPECT_THROW(store.Prepare(tree.Request(
                   "00000000-0000-4000-8000-000000000009", 'A',
                   L"Other.app")),
               WindowsReservationError);

  store.Commit(first->transaction_id(), first->ready_token(), 100);
  EXPECT_THROW(
      store.Commit(first->transaction_id(), first->ready_token(), 100),
      WindowsReservationError);
  EXPECT_THROW(
      store.Cancel(first->transaction_id(), first->ready_token()),
      WindowsReservationError);
}

TEST(WindowsHelperReservation, CancellationOwnsOnlyDerivedPreparedState) {
  TemporaryReservationTree tree;
  WindowsReservationStore store;
  auto reservation = store.Prepare(
      tree.Request("00000000-0000-4000-8000-000000000007"));
  const auto unrelated = tree.root / L"unrelated.txt";
  std::ofstream(unrelated) << "preserve";

  store.Cancel(reservation->transaction_id(), reservation->ready_token());

  EXPECT_TRUE(std::filesystem::exists(unrelated));
  EXPECT_EQ(WindowsReservationState::kCancelled, reservation->state());
}

TEST(WindowsHelperReservation, TimeoutAndCallerExitFailClosed) {
  TemporaryReservationTree tree;
  WindowsReservationStore store;
  auto expired = store.Prepare(
      tree.Request("00000000-0000-4000-8000-000000000007"));
  EXPECT_THROW(
      store.Commit(expired->transaction_id(), expired->ready_token(),
                   4'000'000'000'001LL),
      WindowsReservationError);
  EXPECT_EQ(WindowsReservationState::kExpired, expired->state());

  auto second = store.Prepare(
      tree.Request("00000000-0000-4000-8000-000000000008", 'B'));
  store.CallerExited(second->transaction_id());
  EXPECT_EQ(WindowsReservationState::kCancelled, second->state());
}

}  // namespace
}  // namespace desktop_updater::helper
