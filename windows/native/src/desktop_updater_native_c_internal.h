#ifndef DESKTOP_UPDATER_NATIVE_C_INTERNAL_H_
#define DESKTOP_UPDATER_NATIVE_C_INTERNAL_H_

#include <functional>

#include "desktop_updater_native.h"
#include "desktop_updater_native_c.h"

namespace desktop_updater {
namespace native {
namespace internal {

using InstallScheduler =
    std::function<InstallResult(const InstallRequest& request)>;
using InstallPreparer = std::function<InstallResult(
    const InstallRequest& request,
    const std::string& transaction_id,
    InstallReservation* reservation,
    bool* recovery_required)>;
using TransactionOperation = std::function<InstallTransactionStatus(
    const std::string& transaction_id)>;
using StatusOperation = std::function<InstallTransactionStatus()>;

desktop_updater_result_v1 ScheduleInstallAndRelaunchWith(
    const desktop_updater_install_request_v1* request,
    const InstallScheduler& scheduler);

desktop_updater_result_v1 PrepareInstallV2With(
    const desktop_updater_install_request_v1* request,
    const std::uint16_t* transaction_id,
    desktop_updater_reservation_handle_v1** reservation,
    desktop_updater_transaction_status_v1* status,
    std::uint32_t* prepare_outcome,
    const InstallPreparer& preparer);

desktop_updater_result_v1 TransactionOperationWith(
    const std::uint16_t* transaction_id,
    desktop_updater_transaction_status_v1* status,
    const TransactionOperation& operation);

desktop_updater_result_v1 StatusOperationWith(
    desktop_updater_transaction_status_v1* status,
    const StatusOperation& operation);

}  // namespace internal
}  // namespace native
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_NATIVE_C_INTERNAL_H_
