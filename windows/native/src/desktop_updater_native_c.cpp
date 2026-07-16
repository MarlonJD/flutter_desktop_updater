#include "desktop_updater_native_c.h"

#include <cstring>
#include <exception>
#include <new>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "desktop_updater_native.h"
#include "desktop_updater_native_c_internal.h"

struct desktop_updater_reservation_handle_v1 {
  desktop_updater::native::InstallReservation value;
  bool active = true;
};

namespace desktop_updater {
namespace native {
namespace internal {
namespace {

desktop_updater_result_v1 SuccessResult() {
  return {DESKTOP_UPDATER_NATIVE_ABI_VERSION, 1, nullptr};
}

desktop_updater_result_v1 ErrorResult(const std::string& message) {
  char* owned_message = new (std::nothrow) char[message.size() + 1];
  if (owned_message == nullptr) {
    return {DESKTOP_UPDATER_NATIVE_ABI_VERSION, 0, nullptr};
  }
  std::memcpy(owned_message, message.c_str(), message.size() + 1);
  return {DESKTOP_UPDATER_NATIVE_ABI_VERSION, 0, owned_message};
}

char* CopyString(const std::string& value) {
  char* copy = new (std::nothrow) char[value.size() + 1];
  if (copy != nullptr) {
    std::memcpy(copy, value.c_str(), value.size() + 1);
  }
  return copy;
}

void ClearStatusStrings(desktop_updater_transaction_status_v1* status) {
  if (status == nullptr) return;
  delete[] status->transaction_id_utf8;
  delete[] status->detail_utf8;
  delete[] status->response_digest_sha256_utf8;
  delete[] status->helper_endpoint_identity_sha256_utf8;
  status->transaction_id_utf8 = nullptr;
  status->detail_utf8 = nullptr;
  status->response_digest_sha256_utf8 = nullptr;
  status->helper_endpoint_identity_sha256_utf8 = nullptr;
}

bool ValidateStatusDestination(
    const desktop_updater_transaction_status_v1* destination,
    std::string* error) {
  if (destination == nullptr) {
    *error = "transaction status output must not be null.";
    return false;
  }
  if (destination->abi_version != DESKTOP_UPDATER_NATIVE_ABI_VERSION) {
    *error = "Unsupported desktop_updater transaction status ABI version.";
    return false;
  }
  if (destination->struct_size <
      sizeof(desktop_updater_transaction_status_v1)) {
    *error = "desktop_updater transaction status struct is undersized.";
    return false;
  }
  if (destination->transaction_id_utf8 != nullptr ||
      destination->detail_utf8 != nullptr ||
      destination->response_digest_sha256_utf8 != nullptr ||
      destination->helper_endpoint_identity_sha256_utf8 != nullptr) {
    *error = "transaction status output must be zero-initialized.";
    return false;
  }
  return true;
}

bool WriteStatus(const InstallTransactionStatus& source,
                 desktop_updater_transaction_status_v1* destination,
                 std::string* error) {
  if (!ValidateStatusDestination(destination, error)) {
    return false;
  }
  destination->state = static_cast<std::uint32_t>(source.state);
  destination->result_code = static_cast<std::uint32_t>(source.result_code);
  destination->transaction_id_utf8 = CopyString(source.transaction_id);
  destination->detail_utf8 = CopyString(source.detail);
  destination->response_digest_sha256_utf8 =
      CopyString(source.response_digest_sha256);
  destination->helper_endpoint_identity_sha256_utf8 =
      CopyString(source.helper_endpoint_identity_sha256);
  if (destination->transaction_id_utf8 == nullptr ||
      destination->detail_utf8 == nullptr ||
      destination->response_digest_sha256_utf8 == nullptr ||
      destination->helper_endpoint_identity_sha256_utf8 == nullptr) {
    ClearStatusStrings(destination);
    *error = "Unable to allocate transaction status response.";
    return false;
  }
  return true;
}

bool IsCanonicalTransactionId(const std::string& value) {
  if (value.size() != 36 || value[8] != '-' || value[13] != '-' ||
      value[18] != '-' || value[23] != '-' || value[14] != '4' ||
      std::string("89ab").find(value[19]) == std::string::npos) {
    return false;
  }
  for (std::size_t index = 0; index < value.size(); ++index) {
    if (index == 8 || index == 13 || index == 18 || index == 23) continue;
    const char byte = value[index];
    if (!(byte >= '0' && byte <= '9') && !(byte >= 'a' && byte <= 'f')) {
      return false;
    }
  }
  return true;
}

bool IsHighSurrogate(uint16_t value) {
  return value >= 0xD800 && value <= 0xDBFF;
}

bool IsLowSurrogate(uint16_t value) {
  return value >= 0xDC00 && value <= 0xDFFF;
}

bool ReadUtf16(const uint16_t* value,
               bool allow_null,
               const char* field_name,
               std::wstring* output,
               std::string* error) {
  output->clear();
  if (value == nullptr) {
    if (allow_null) {
      return true;
    }
    *error = std::string(field_name) + " must not be null.";
    return false;
  }

  for (size_t index = 0; value[index] != 0; ++index) {
    const uint16_t code_unit = value[index];
    if (IsHighSurrogate(code_unit)) {
      if (!IsLowSurrogate(value[index + 1])) {
        *error = std::string(field_name) + " contains invalid UTF-16.";
        return false;
      }
      output->push_back(static_cast<wchar_t>(code_unit));
      output->push_back(static_cast<wchar_t>(value[++index]));
      continue;
    }
    if (IsLowSurrogate(code_unit)) {
      *error = std::string(field_name) + " contains invalid UTF-16.";
      return false;
    }
    output->push_back(static_cast<wchar_t>(code_unit));
  }
  return true;
}

bool ReadCanonicalTransactionId(const std::uint16_t* value,
                                std::string* transaction_id,
                                std::string* error) {
  std::wstring wide_transaction_id;
  if (!ReadUtf16(value, false, "transaction_id", &wide_transaction_id,
                 error)) {
    return false;
  }
  transaction_id->clear();
  transaction_id->reserve(wide_transaction_id.size());
  for (wchar_t character : wide_transaction_id) {
    if (character > 0x7f) {
      *error = "transaction_id must be ASCII.";
      return false;
    }
    transaction_id->push_back(static_cast<char>(character));
  }
  if (!IsCanonicalTransactionId(*transaction_id)) {
    *error = "transaction_id must be a canonical lowercase UUIDv4.";
    return false;
  }
  return true;
}

bool ParseRequest(const desktop_updater_install_request_v1* request,
                  InstallRequest* parsed,
                  std::string* error) {
  if (request == nullptr) {
    *error = "request must not be null.";
    return false;
  }
  if (request->abi_version != DESKTOP_UPDATER_NATIVE_ABI_VERSION) {
    *error = "Unsupported desktop_updater native ABI version.";
    return false;
  }
  constexpr size_t kLegacyInstallRequestSize =
      offsetof(desktop_updater_install_request_v1,
               expected_provenance_sha256);
  if (request->struct_size < kLegacyInstallRequestSize) {
    *error = "desktop_updater install request struct is undersized.";
    return false;
  }
  if (!ReadUtf16(request->staging_path, true, "staging_path",
                 &parsed->staging_path, error) ||
      !ReadUtf16(request->diagnostics_log_path, true,
                 "diagnostics_log_path", &parsed->diagnostics_log_path,
                 error)) {
    return false;
  }
  const bool has_provenance_fields =
      request->struct_size >=
      offsetof(desktop_updater_install_request_v1, install_root);
  if (has_provenance_fields &&
      (!ReadUtf16(request->expected_provenance_sha256, true,
                 "expected_provenance_sha256",
                 &parsed->expected_provenance_sha256, error) ||
      !ReadUtf16(request->expected_artifact_sha256, true,
                 "expected_artifact_sha256",
                 &parsed->expected_artifact_sha256, error))) {
    return false;
  }
  if (has_provenance_fields &&
      request->allowed_signer_thumbprint_count > 0 &&
      request->allowed_signer_thumbprints == nullptr) {
    *error = "allowed_signer_thumbprints must not be null when its count is non-zero.";
    return false;
  }
  parsed->allowed_signer_thumbprints.clear();
  for (size_t index = 0;
       has_provenance_fields &&
       index < request->allowed_signer_thumbprint_count; ++index) {
    std::wstring thumbprint;
    if (!ReadUtf16(request->allowed_signer_thumbprints[index], false,
                   "allowed_signer_thumbprints item", &thumbprint, error)) {
      return false;
    }
    parsed->allowed_signer_thumbprints.push_back(std::move(thumbprint));
  }
  constexpr size_t kTargetFieldsSize =
      offsetof(desktop_updater_install_request_v1, expected_package_id) +
      sizeof(request->expected_package_id);
  const bool has_target_fields = request->struct_size >= kTargetFieldsSize;
  if (has_target_fields &&
      (!ReadUtf16(request->install_root, true, "install_root",
                  &parsed->install_root, error) ||
       !ReadUtf16(request->executable_relative_path, true,
                  "executable_relative_path",
                  &parsed->executable_relative_path, error) ||
       !ReadUtf16(request->expected_package_id, true,
                  "expected_package_id", &parsed->expected_package_id,
                  error))) {
    return false;
  }
  if (request->removed_file_count > 0 && request->removed_files == nullptr) {
    *error = "removed_files must not be null when removed_file_count is non-zero.";
    return false;
  }

  parsed->removed_files.clear();
  parsed->removed_files.reserve(request->removed_file_count);
  for (size_t index = 0; index < request->removed_file_count; ++index) {
    std::wstring removed_file;
    if (!ReadUtf16(request->removed_files[index], false, "removed_files item",
                   &removed_file, error)) {
      return false;
    }
    parsed->removed_files.push_back(std::move(removed_file));
  }
  if (!parsed->staging_path.empty() &&
      (parsed->expected_provenance_sha256.empty() ||
       parsed->expected_artifact_sha256.empty() ||
       parsed->install_root.empty() ||
       parsed->executable_relative_path.empty() ||
       parsed->expected_package_id.empty())) {
    *error =
        "Staged install requires complete verified provenance and target context.";
    return false;
  }
  constexpr size_t kElevationPolicySize =
      offsetof(desktop_updater_install_request_v1, elevation_policy) +
      sizeof(request->elevation_policy);
  parsed->elevation_policy = InstallElevationPolicy::kAuto;
  if (request->struct_size >= kElevationPolicySize) {
    switch (request->elevation_policy) {
      case DESKTOP_UPDATER_INSTALL_ELEVATION_AUTO:
        parsed->elevation_policy = InstallElevationPolicy::kAuto;
        break;
      case DESKTOP_UPDATER_INSTALL_ELEVATION_ALWAYS:
        parsed->elevation_policy = InstallElevationPolicy::kAlways;
        break;
      case DESKTOP_UPDATER_INSTALL_ELEVATION_NEVER:
        parsed->elevation_policy = InstallElevationPolicy::kNever;
        break;
      default:
        *error = "Invalid desktop_updater install elevation policy.";
        return false;
    }
  }
  return true;
}

}  // namespace

desktop_updater_result_v1 ScheduleInstallAndRelaunchWith(
    const desktop_updater_install_request_v1* request,
    const InstallScheduler& scheduler) {
  try {
    InstallRequest parsed;
    std::string error;
    if (!ParseRequest(request, &parsed, &error)) {
      return ErrorResult(error);
    }
    const InstallResult result = scheduler(parsed);
    return result.ok ? SuccessResult() : ErrorResult(result.error_message);
  } catch (const std::exception& error) {
    return ErrorResult(error.what());
  } catch (...) {
    return ErrorResult("Unknown C++ exception in desktop_updater native helper.");
  }
}

static desktop_updater_result_v1 PrepareInstallV2WithImpl(
    const desktop_updater_install_request_v1* request,
    const std::uint16_t* transaction_id,
    desktop_updater_reservation_handle_v1** reservation,
    desktop_updater_transaction_status_v1* status,
    std::uint32_t* prepare_outcome,
    const InstallPreparer& preparer) {
  if (prepare_outcome == nullptr) {
    return ErrorResult("prepare_outcome output must not be null.");
  }
  *prepare_outcome = DESKTOP_UPDATER_PREPARE_OUTCOME_REJECTED;
  if (reservation == nullptr) {
    return ErrorResult("reservation output must not be null.");
  }
  *reservation = nullptr;

  std::string error;
  if (!ValidateStatusDestination(status, &error)) {
    return ErrorResult(error);
  }
  std::string requested_transaction_id;
  if (!ReadCanonicalTransactionId(transaction_id, &requested_transaction_id,
                                  &error)) {
    return ErrorResult(error);
  }
  InstallRequest parsed;
  if (!ParseRequest(request, &parsed, &error)) {
    return ErrorResult(error);
  }

  InstallReservation native_reservation;
  bool recovery_required = false;
  InstallResult result;
  *prepare_outcome = DESKTOP_UPDATER_PREPARE_OUTCOME_RECOVERY_REQUIRED;
  try {
    result = preparer(parsed, requested_transaction_id, &native_reservation,
                      &recovery_required);
  } catch (const std::exception& exception) {
    recovery_required = true;
    result = {false, exception.what()};
  } catch (...) {
    recovery_required = true;
    result = {false, "Unknown C++ exception in install preparation."};
  }

  if (!result.ok) {
    *prepare_outcome =
        recovery_required
            ? DESKTOP_UPDATER_PREPARE_OUTCOME_RECOVERY_REQUIRED
            : DESKTOP_UPDATER_PREPARE_OUTCOME_REJECTED;
    const InstallTransactionStatus failed_status = {
        requested_transaction_id,
        InstallTransactionState::kUnknown,
        recovery_required ? InstallTransactionResultCode::kRecoveryRequired
                          : InstallTransactionResultCode::kRejected,
        result.error_message,
        "",
        ""};
    if (!WriteStatus(failed_status, status, &error)) {
      return ErrorResult(error);
    }
    return ErrorResult(result.error_message);
  }

  if (recovery_required ||
      native_reservation.transaction_id != requested_transaction_id) {
    (void)CancelReservation(native_reservation);
    *prepare_outcome = DESKTOP_UPDATER_PREPARE_OUTCOME_RECOVERY_REQUIRED;
    const std::string detail =
        "Windows helper changed the requested transaction binding.";
    const InstallTransactionStatus failed_status = {
        requested_transaction_id,
        InstallTransactionState::kUnknown,
        InstallTransactionResultCode::kRecoveryRequired,
        detail,
        "",
        ""};
    if (!WriteStatus(failed_status, status, &error)) {
      return ErrorResult(error);
    }
    return ErrorResult(detail);
  }

  auto* handle = new (std::nothrow) desktop_updater_reservation_handle_v1;
  if (handle == nullptr) {
    (void)CancelReservation(native_reservation);
    *prepare_outcome = DESKTOP_UPDATER_PREPARE_OUTCOME_RECOVERY_REQUIRED;
    return ErrorResult("Unable to allocate install reservation handle.");
  }
  handle->value = std::move(native_reservation);
  const InstallTransactionStatus prepared_status = {
      handle->value.transaction_id,
      InstallTransactionState::kPrepared,
      InstallTransactionResultCode::kAccepted,
      "prepared",
      handle->value.response_digest_sha256,
      handle->value.helper_endpoint_identity_sha256};
  if (!WriteStatus(prepared_status, status, &error)) {
    (void)CancelReservation(handle->value);
    delete handle;
    *prepare_outcome = DESKTOP_UPDATER_PREPARE_OUTCOME_RECOVERY_REQUIRED;
    return ErrorResult(error);
  }
  *reservation = handle;
  *prepare_outcome = DESKTOP_UPDATER_PREPARE_OUTCOME_PREPARED;
  return SuccessResult();
}

desktop_updater_result_v1 PrepareInstallV2With(
    const desktop_updater_install_request_v1* request,
    const std::uint16_t* transaction_id,
    desktop_updater_reservation_handle_v1** reservation,
    desktop_updater_transaction_status_v1* status,
    std::uint32_t* prepare_outcome,
    const InstallPreparer& preparer) {
  try {
    return PrepareInstallV2WithImpl(request, transaction_id, reservation,
                                    status, prepare_outcome, preparer);
  } catch (const std::exception& error) {
    return ErrorResult(error.what());
  } catch (...) {
    return ErrorResult("Unknown C++ exception in install preparation V2.");
  }
}

desktop_updater_result_v1 PrepareInstallWith(
    const desktop_updater_install_request_v1* request,
    desktop_updater_reservation_handle_v1** reservation,
    desktop_updater_transaction_status_v1* status) {
  try {
    if (reservation == nullptr) {
      return ErrorResult("reservation output must not be null.");
    }
    *reservation = nullptr;
    InstallRequest parsed;
    std::string error;
    if (!ValidateStatusDestination(status, &error)) {
      return ErrorResult(error);
    }
    if (!ParseRequest(request, &parsed, &error)) {
      return ErrorResult(error);
    }
    InstallReservation native_reservation;
    const InstallResult result = PrepareInstall(parsed, &native_reservation);
    if (!result.ok) {
      return ErrorResult(result.error_message);
    }
    auto* handle = new (std::nothrow) desktop_updater_reservation_handle_v1;
    if (handle == nullptr) {
      return ErrorResult("Unable to allocate install reservation handle.");
    }
    handle->value = std::move(native_reservation);
    const InstallTransactionStatus prepared_status = {
        handle->value.transaction_id, InstallTransactionState::kPrepared,
        InstallTransactionResultCode::kAccepted, "prepared",
        handle->value.response_digest_sha256,
        handle->value.helper_endpoint_identity_sha256};
    if (!WriteStatus(prepared_status, status, &error)) {
      (void)CancelReservation(handle->value);
      delete handle;
      return ErrorResult(error);
    }
    *reservation = handle;
    return SuccessResult();
  } catch (const std::exception& error) {
    return ErrorResult(error.what());
  } catch (...) {
    return ErrorResult("Unknown C++ exception in install preparation.");
  }
}

desktop_updater_result_v1 StatusOperationWith(
    desktop_updater_transaction_status_v1* status,
    const StatusOperation& operation) {
  try {
    std::string error;
    if (!ValidateStatusDestination(status, &error)) {
      return ErrorResult(error);
    }
    const InstallTransactionStatus native_status = operation();
    if (!WriteStatus(native_status, status, &error)) {
      return ErrorResult(error);
    }
    return SuccessResult();
  } catch (const std::exception& error) {
    return ErrorResult(error.what());
  } catch (...) {
    return ErrorResult("Unknown C++ exception in status operation.");
  }
}

desktop_updater_result_v1 ReservationOperationWith(
    desktop_updater_reservation_handle_v1* reservation,
    desktop_updater_transaction_status_v1* status,
    bool commit) {
  if (reservation == nullptr || !reservation->active) {
    return ErrorResult("install reservation handle is invalid or inactive.");
  }
  return StatusOperationWith(status, [reservation, commit]() {
    const InstallTransactionStatus native_status =
        commit ? CommitAfterExit(reservation->value)
               : CancelReservation(reservation->value);
    if ((commit &&
         (native_status.state == InstallTransactionState::kCommitAccepted ||
          native_status.state == InstallTransactionState::kCompleted)) ||
        (!commit &&
         native_status.state == InstallTransactionState::kCancelled)) {
      reservation->active = false;
    }
    return native_status;
  });
}

desktop_updater_result_v1 TransactionOperationWith(
    const std::uint16_t* transaction_id,
    desktop_updater_transaction_status_v1* status,
    const TransactionOperation& operation) {
  try {
    std::string error;
    if (!ValidateStatusDestination(status, &error)) {
      return ErrorResult(error);
    }
    std::string narrow_transaction_id;
    if (!ReadCanonicalTransactionId(transaction_id, &narrow_transaction_id,
                                    &error)) {
      return ErrorResult(error);
    }
    const InstallTransactionStatus native_status =
        operation(narrow_transaction_id);
    if (native_status.transaction_id != narrow_transaction_id) {
      return ErrorResult(
          "Windows helper changed the requested transaction binding.");
    }
    if (!WriteStatus(native_status, status, &error)) {
      return ErrorResult(error);
    }
    return SuccessResult();
  } catch (const std::exception& error) {
    return ErrorResult(error.what());
  } catch (...) {
    return ErrorResult("Unknown C++ exception in transaction operation.");
  }
}

}  // namespace internal
}  // namespace native
}  // namespace desktop_updater

desktop_updater_result_v1 DESKTOP_UPDATER_CALL
desktop_updater_schedule_install_and_relaunch_v1(
    const desktop_updater_install_request_v1* request) {
  return desktop_updater::native::internal::ScheduleInstallAndRelaunchWith(
      request, desktop_updater::native::ScheduleInstallAndRelaunch);
}

desktop_updater_result_v1 DESKTOP_UPDATER_CALL
desktop_updater_prepare_install_v1(
    const desktop_updater_install_request_v1* request,
    desktop_updater_reservation_handle_v1** reservation,
    desktop_updater_transaction_status_v1* status) {
  return desktop_updater::native::internal::PrepareInstallWith(request,
                                                               reservation,
                                                               status);
}

desktop_updater_result_v1 DESKTOP_UPDATER_CALL
desktop_updater_prepare_install_v2(
    const desktop_updater_install_request_v1* request,
    const uint16_t* transaction_id,
    desktop_updater_reservation_handle_v1** reservation,
    desktop_updater_transaction_status_v1* status,
    uint32_t* prepare_outcome) {
  return desktop_updater::native::internal::PrepareInstallV2With(
      request, transaction_id, reservation, status, prepare_outcome,
      desktop_updater::native::PrepareInstallWithTransactionId);
}

desktop_updater_result_v1 DESKTOP_UPDATER_CALL
desktop_updater_commit_after_exit_v1(
    desktop_updater_reservation_handle_v1* reservation,
    desktop_updater_transaction_status_v1* status) {
  return desktop_updater::native::internal::ReservationOperationWith(
      reservation, status, true);
}

desktop_updater_result_v1 DESKTOP_UPDATER_CALL
desktop_updater_cancel_reservation_v1(
    desktop_updater_reservation_handle_v1* reservation,
    desktop_updater_transaction_status_v1* status) {
  return desktop_updater::native::internal::ReservationOperationWith(
      reservation, status, false);
}

desktop_updater_result_v1 DESKTOP_UPDATER_CALL
desktop_updater_query_transaction_v1(
    const uint16_t* transaction_id,
    desktop_updater_transaction_status_v1* status) {
  return desktop_updater::native::internal::TransactionOperationWith(
      transaction_id, status, desktop_updater::native::QueryTransaction);
}

desktop_updater_result_v1 DESKTOP_UPDATER_CALL
desktop_updater_recover_pending_install_v1(
    const uint16_t* transaction_id,
    desktop_updater_transaction_status_v1* status) {
  return desktop_updater::native::internal::TransactionOperationWith(
      transaction_id, status,
      desktop_updater::native::RecoverPendingInstall);
}

desktop_updater_result_v1 DESKTOP_UPDATER_CALL
desktop_updater_resolve_pending_install_after_exit_v1(
    const uint16_t* transaction_id,
    desktop_updater_transaction_status_v1* status) {
  return desktop_updater::native::internal::TransactionOperationWith(
      transaction_id, status,
      desktop_updater::native::ResolvePendingInstallAfterExit);
}

void DESKTOP_UPDATER_CALL desktop_updater_transaction_status_free_v1(
    desktop_updater_transaction_status_v1* status) {
  if (status == nullptr) return;
  desktop_updater::native::internal::ClearStatusStrings(status);
  status->abi_version = 0;
  status->struct_size = 0;
  status->state = 0;
  status->result_code = 0;
}

void DESKTOP_UPDATER_CALL desktop_updater_reservation_release_v1(
    desktop_updater_reservation_handle_v1* reservation) {
  if (reservation == nullptr) return;
  if (reservation->active) {
    (void)desktop_updater::native::CancelReservation(reservation->value);
    reservation->active = false;
  }
  delete reservation;
}

void DESKTOP_UPDATER_CALL desktop_updater_result_free_v1(
    desktop_updater_result_v1* result) {
  if (result == nullptr) {
    return;
  }
  delete[] result->error_message_utf8;
  result->error_message_utf8 = nullptr;
  result->abi_version = 0;
  result->ok = 0;
}
