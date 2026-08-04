#include "desktop_updater_native_c.h"

#include <cstring>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <new>
#include <string>
#include <utility>

#include "desktop_updater_native.h"
#include "desktop_updater_native_c_legacy.h"

struct desktop_updater_reservation_handle_abi2 {
  desktop_updater::native::InstallReservation value;
  bool active = true;
};

namespace desktop_updater {
namespace native {
namespace {

char* CopyString(const std::string& value) {
  char* copy = new (std::nothrow) char[value.size() + 1];
  if (copy != nullptr) {
    std::memcpy(copy, value.c_str(), value.size() + 1);
  }
  return copy;
}

desktop_updater_result_abi2 SuccessResult() {
  return {DESKTOP_UPDATER_NATIVE_ABI_VERSION, sizeof(desktop_updater_result_abi2),
          1, nullptr};
}

desktop_updater_result_abi2 ErrorResult(const std::string& message) {
  return {DESKTOP_UPDATER_NATIVE_ABI_VERSION, sizeof(desktop_updater_result_abi2),
          0, CopyString(message)};
}

void ClearStatusStrings(desktop_updater_transaction_status_abi2* status) {
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

template <typename Struct>
bool ValidateAbi2Prefix(const Struct* value,
                        const char* label,
                        std::string* error) {
  if (value == nullptr) {
    *error = std::string(label) + " must not be null.";
    return false;
  }
  if (value->abi_version != DESKTOP_UPDATER_NATIVE_ABI_VERSION) {
    *error = std::string(label) + " has an unsupported ABI version.";
    return false;
  }
  if (value->struct_size < sizeof(Struct)) {
    *error = std::string(label) + " is truncated before a required field.";
    return false;
  }
  return true;
}

bool ValidateStatusDestination(
    const desktop_updater_transaction_status_abi2* destination,
    std::string* error) {
  if (!ValidateAbi2Prefix(destination, "transaction status", error)) {
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
                 desktop_updater_transaction_status_abi2* destination,
                 std::string* error) {
  if (!ValidateStatusDestination(destination, error)) return false;
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

bool IsHighSurrogate(std::uint16_t value) {
  return value >= 0xD800 && value <= 0xDBFF;
}

bool IsLowSurrogate(std::uint16_t value) {
  return value >= 0xDC00 && value <= 0xDFFF;
}

bool ReadUtf16(const std::uint16_t* value,
               const char* field_name,
               std::wstring* output,
               std::string* error) {
  output->clear();
  if (value == nullptr) {
    *error = std::string(field_name) + " must not be null.";
    return false;
  }
  for (std::size_t index = 0; value[index] != 0; ++index) {
    const std::uint16_t code_unit = value[index];
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
  std::wstring wide;
  if (!ReadUtf16(value, "transaction_id", &wide, error)) return false;
  transaction_id->clear();
  transaction_id->reserve(wide.size());
  for (wchar_t character : wide) {
    if (character > 0x7f) {
      *error = "transaction_id must be ASCII.";
      return false;
    }
    transaction_id->push_back(static_cast<char>(character));
  }
  if (!IsCanonicalTransactionId(*transaction_id)) {
    *error = "transaction_id must be a canonical UUIDv4.";
    return false;
  }
  return true;
}

bool ParseRequest(const desktop_updater_install_request_abi2* request,
                  InstallRequest* parsed,
                  std::string* error) {
  if (!ValidateAbi2Prefix(request, "install request", error)) return false;
  if (!ReadUtf16(request->staging_path, "staging_path", &parsed->staging_path,
                 error) ||
      !ReadUtf16(request->expected_provenance_sha256,
                 "expected_provenance_sha256",
                 &parsed->expected_provenance_sha256, error) ||
      !ReadUtf16(request->expected_artifact_sha256,
                 "expected_artifact_sha256", &parsed->expected_artifact_sha256,
                 error) ||
      !ReadUtf16(request->install_root, "install_root", &parsed->install_root,
                 error) ||
      !ReadUtf16(request->executable_relative_path,
                 "executable_relative_path", &parsed->executable_relative_path,
                 error) ||
      !ReadUtf16(request->expected_package_id, "expected_package_id",
                 &parsed->expected_package_id, error)) {
    return false;
  }
  if (request->removed_file_count > 0 && request->removed_files == nullptr) {
    *error = "removed_files must not be null when its count is non-zero.";
    return false;
  }
  parsed->removed_files.clear();
  parsed->removed_files.reserve(request->removed_file_count);
  for (std::size_t index = 0; index < request->removed_file_count; ++index) {
    std::wstring removed_file;
    if (!ReadUtf16(request->removed_files[index], "removed_files item",
                   &removed_file, error)) {
      return false;
    }
    parsed->removed_files.push_back(std::move(removed_file));
  }
  return true;
}

desktop_updater_result_abi2 PrepareInstallWithAbi2(
    const desktop_updater_install_request_abi2* request,
    const std::uint16_t* transaction_id,
    desktop_updater_reservation_handle_abi2** reservation,
    desktop_updater_transaction_status_abi2* status) {
  try {
    if (reservation == nullptr) {
      return ErrorResult("reservation output must not be null.");
    }
    std::string error;
    InstallRequest parsed;
    std::string requested_transaction_id;
    if (!ParseRequest(request, &parsed, &error) ||
        !ReadCanonicalTransactionId(transaction_id, &requested_transaction_id,
                                    &error) ||
        !ValidateStatusDestination(status, &error)) {
      return ErrorResult(error);
    }

    InstallReservation native_reservation;
    const InstallResult prepared =
        PrepareInstall(parsed, requested_transaction_id, &native_reservation);
    if (!prepared.ok) {
      const InstallTransactionStatus rejected = {
          requested_transaction_id,
          InstallTransactionState::kUnknown,
          InstallTransactionResultCode::kRejected,
          prepared.error_message,
          "",
          ""};
      if (!WriteStatus(rejected, status, &error)) return ErrorResult(error);
      return ErrorResult(prepared.error_message);
    }
    if (native_reservation.transaction_id != requested_transaction_id) {
      (void)CancelReservation(native_reservation);
      return ErrorResult("Windows helper changed the requested transaction binding.");
    }
    auto* handle = new (std::nothrow) desktop_updater_reservation_handle_abi2;
    if (handle == nullptr) {
      (void)CancelReservation(native_reservation);
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
      return ErrorResult(error);
    }
    *reservation = handle;
    return SuccessResult();
  } catch (const std::exception& error) {
    return ErrorResult(error.what());
  } catch (...) {
    return ErrorResult("Unknown C++ exception in ABI2 preparation.");
  }
}

template <typename Operation>
desktop_updater_result_abi2 WriteOperationStatus(
    desktop_updater_transaction_status_abi2* status,
    Operation operation) {
  try {
    std::string error;
    if (!ValidateStatusDestination(status, &error)) return ErrorResult(error);
    if (!WriteStatus(operation(), status, &error)) return ErrorResult(error);
    return SuccessResult();
  } catch (const std::exception& error) {
    return ErrorResult(error.what());
  } catch (...) {
    return ErrorResult("Unknown C++ exception in transaction operation.");
  }
}

template <typename Operation>
desktop_updater_result_abi2 WriteTransactionStatus(
    const std::uint16_t* transaction_id,
    desktop_updater_transaction_status_abi2* status,
    Operation operation) {
  try {
    std::string error;
    if (!ValidateStatusDestination(status, &error)) return ErrorResult(error);
    std::string requested_transaction_id;
    if (!ReadCanonicalTransactionId(transaction_id, &requested_transaction_id,
                                    &error)) {
      return ErrorResult(error);
    }
    const InstallTransactionStatus result = operation(requested_transaction_id);
    if (result.transaction_id != requested_transaction_id) {
      return ErrorResult(
          "Windows helper changed the requested transaction binding.");
    }
    if (!WriteStatus(result, status, &error)) return ErrorResult(error);
    return SuccessResult();
  } catch (const std::exception& error) {
    return ErrorResult(error.what());
  } catch (...) {
    return ErrorResult("Unknown C++ exception in transaction operation.");
  }
}

}  // namespace
}  // namespace native
}  // namespace desktop_updater

extern "C" desktop_updater_result_v1 DESKTOP_UPDATER_CALL
desktop_updater_prepare_install_v2(
    const desktop_updater_install_request_v1* /*request*/,
    const std::uint16_t* /*transaction_id*/,
    desktop_updater_reservation_handle_v1** reservation,
    desktop_updater_transaction_status_v1* status,
    std::uint32_t* prepare_outcome) {
  if (reservation != nullptr) *reservation = nullptr;
  if (prepare_outcome != nullptr) {
    *prepare_outcome = DESKTOP_UPDATER_PREPARE_OUTCOME_REJECTED;
  }
  if (status != nullptr &&
      status->abi_version == DESKTOP_UPDATER_NATIVE_ABI_VERSION_1 &&
      status->struct_size >= sizeof(desktop_updater_transaction_status_v1) &&
      status->transaction_id_utf8 == nullptr && status->detail_utf8 == nullptr &&
      status->response_digest_sha256_utf8 == nullptr &&
      status->helper_endpoint_identity_sha256_utf8 == nullptr) {
    status->state = 0;
    status->result_code = 3;
  }
  constexpr char kRemovedApi[] =
      "desktop_updater_prepare_install_v2 was removed in ABI 2.";
  char* message = new (std::nothrow) char[sizeof(kRemovedApi)];
  if (message != nullptr) std::memcpy(message, kRemovedApi, sizeof(kRemovedApi));
  return {DESKTOP_UPDATER_NATIVE_ABI_VERSION_1, 0, message};
}

extern "C" std::uint32_t DESKTOP_UPDATER_CALL
desktop_updater_native_abi_version_abi2() {
  return DESKTOP_UPDATER_NATIVE_ABI_VERSION;
}

extern "C" desktop_updater_result_abi2 DESKTOP_UPDATER_CALL
desktop_updater_prepare_install_abi2(
    const desktop_updater_install_request_abi2* request,
    const std::uint16_t* transaction_id,
    desktop_updater_reservation_handle_abi2** reservation,
    desktop_updater_transaction_status_abi2* status) {
  return desktop_updater::native::PrepareInstallWithAbi2(
      request, transaction_id, reservation, status);
}

extern "C" desktop_updater_result_abi2 DESKTOP_UPDATER_CALL
desktop_updater_commit_after_exit_abi2(
    desktop_updater_reservation_handle_abi2* reservation,
    desktop_updater_transaction_status_abi2* status) {
  if (reservation == nullptr || !reservation->active) {
    return desktop_updater::native::ErrorResult(
        "install reservation handle is invalid or inactive.");
  }
  const auto operation = [reservation]() {
    const desktop_updater::native::InstallTransactionStatus result =
        desktop_updater::native::CommitAfterExit(reservation->value);
    if (result.state ==
            desktop_updater::native::InstallTransactionState::kCommitAccepted ||
        result.state ==
            desktop_updater::native::InstallTransactionState::kCompleted) {
      reservation->active = false;
    }
    return result;
  };
  return desktop_updater::native::WriteOperationStatus(status, operation);
}

extern "C" desktop_updater_result_abi2 DESKTOP_UPDATER_CALL
desktop_updater_cancel_reservation_abi2(
    desktop_updater_reservation_handle_abi2* reservation,
    desktop_updater_transaction_status_abi2* status) {
  if (reservation == nullptr || !reservation->active) {
    return desktop_updater::native::ErrorResult(
        "install reservation handle is invalid or inactive.");
  }
  const auto operation = [reservation]() {
    const desktop_updater::native::InstallTransactionStatus result =
        desktop_updater::native::CancelReservation(reservation->value);
    if (result.state ==
        desktop_updater::native::InstallTransactionState::kCancelled) {
      reservation->active = false;
    }
    return result;
  };
  return desktop_updater::native::WriteOperationStatus(status, operation);
}

extern "C" desktop_updater_result_abi2 DESKTOP_UPDATER_CALL
desktop_updater_query_transaction_abi2(
    const std::uint16_t* transaction_id,
    desktop_updater_transaction_status_abi2* status) {
  return desktop_updater::native::WriteTransactionStatus(
      transaction_id, status, desktop_updater::native::QueryTransaction);
}

extern "C" desktop_updater_result_abi2 DESKTOP_UPDATER_CALL
desktop_updater_resolve_pending_install_after_exit_abi2(
    const std::uint16_t* transaction_id,
    desktop_updater_transaction_status_abi2* status) {
  return desktop_updater::native::WriteTransactionStatus(
      transaction_id, status,
      desktop_updater::native::ResolvePendingInstallAfterExit);
}

extern "C" void DESKTOP_UPDATER_CALL
desktop_updater_transaction_status_free_abi2(
    desktop_updater_transaction_status_abi2* status) {
  if (status == nullptr) return;
  desktop_updater::native::ClearStatusStrings(status);
  status->abi_version = 0;
  status->struct_size = 0;
  status->state = 0;
  status->result_code = 0;
}

extern "C" void DESKTOP_UPDATER_CALL
desktop_updater_reservation_release_abi2(
    desktop_updater_reservation_handle_abi2* reservation) {
  if (reservation == nullptr) return;
  if (reservation->active) {
    (void)desktop_updater::native::CancelReservation(reservation->value);
    reservation->active = false;
  }
  delete reservation;
}

extern "C" void DESKTOP_UPDATER_CALL
desktop_updater_result_free_abi2(desktop_updater_result_abi2* result) {
  if (result == nullptr) return;
  delete[] result->error_message_utf8;
  result->error_message_utf8 = nullptr;
  result->abi_version = 0;
  result->struct_size = 0;
  result->ok = 0;
}

// These cleanup exports remain private to the frozen ABI1 binary surface.
extern "C" void DESKTOP_UPDATER_CALL
desktop_updater_transaction_status_free_v1(
    desktop_updater_transaction_status_v1* status) {
  if (status == nullptr) return;
  delete[] status->transaction_id_utf8;
  delete[] status->detail_utf8;
  delete[] status->response_digest_sha256_utf8;
  delete[] status->helper_endpoint_identity_sha256_utf8;
  status->transaction_id_utf8 = nullptr;
  status->detail_utf8 = nullptr;
  status->response_digest_sha256_utf8 = nullptr;
  status->helper_endpoint_identity_sha256_utf8 = nullptr;
  status->abi_version = 0;
  status->struct_size = 0;
  status->state = 0;
  status->result_code = 0;
}

extern "C" void DESKTOP_UPDATER_CALL
desktop_updater_reservation_release_v1(
    desktop_updater_reservation_handle_v1* /*reservation*/) {}

extern "C" void DESKTOP_UPDATER_CALL
desktop_updater_result_free_v1(desktop_updater_result_v1* result) {
  if (result == nullptr) return;
  delete[] result->error_message_utf8;
  result->error_message_utf8 = nullptr;
  result->abi_version = 0;
  result->ok = 0;
}
