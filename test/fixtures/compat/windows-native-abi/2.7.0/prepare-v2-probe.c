#include "desktop_updater_native_c.h"

typedef desktop_updater_result_v1(DESKTOP_UPDATER_CALL *prepare_v2_signature)(
    const desktop_updater_install_request_v1*,
    const uint16_t*,
    desktop_updater_reservation_handle_v1**,
    desktop_updater_transaction_status_v1*,
    uint32_t*);

_Static_assert(sizeof(desktop_updater_result_v1) >= sizeof(int32_t),
               "2.7 result ABI must remain a by-value result");

prepare_v2_signature frozen_prepare_v2 = desktop_updater_prepare_install_v2;
