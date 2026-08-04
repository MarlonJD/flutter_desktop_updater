#include <cstdint>
#include <cstring>

#include "desktop_updater_native_c.h"
#include "desktop_updater_version.h"

int main() {
  if (desktop_updater_native_abi_version_abi2() !=
      DESKTOP_UPDATER_NATIVE_ABI_VERSION) {
    return 1;
  }

  const wchar_t transaction_id[] =
      L"00000000-0000-4000-8000-000000000012";
  desktop_updater_install_request_abi2 request{};
  request.abi_version = 1;
  request.struct_size = sizeof(request);
  desktop_updater_transaction_status_abi2 status{};
  status.abi_version = DESKTOP_UPDATER_NATIVE_ABI_VERSION;
  status.struct_size = sizeof(status);
  desktop_updater_reservation_handle_abi2* reservation = nullptr;
  desktop_updater_result_abi2 result = desktop_updater_prepare_install_abi2(
      &request, reinterpret_cast<const std::uint16_t*>(transaction_id),
      &reservation, &status);
  const bool rejected = result.ok == 0 && reservation == nullptr &&
                        status.transaction_id_utf8 == nullptr &&
                        status.detail_utf8 == nullptr;
  desktop_updater_result_free_abi2(&result);
  desktop_updater_transaction_status_free_abi2(&status);
  if (!rejected) return 1;

  desktop_updater_transaction_status_abi2 queried{};
  queried.abi_version = DESKTOP_UPDATER_NATIVE_ABI_VERSION;
  queried.struct_size = sizeof(queried);
  result = desktop_updater_query_transaction_abi2(
      reinterpret_cast<const std::uint16_t*>(transaction_id), &queried);
  const bool query_succeeded =
      result.ok != 0 &&
      queried.result_code ==
          DESKTOP_UPDATER_TRANSACTION_RESULT_ENDPOINT_UNAVAILABLE_ABI2;
  desktop_updater_result_free_abi2(&result);
  desktop_updater_transaction_status_free_abi2(&queried);
  return query_succeeded ? 0 : 1;
}
