#include "desktop_updater_plugin_private.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <unistd.h>
#include <sys/utsname.h>

#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <vector>

#include "desktop_updater_native.h"

namespace {

namespace fs = std::filesystem;

bool ReadRequiredInstallString(FlValue* args,
                               const char* key,
                               std::string* value,
                               std::string* error) {
  FlValue* argument = fl_value_lookup_string(args, key);
  if (argument == nullptr) {
    *error = std::string(key) + " is required.";
    return false;
  }
  if (fl_value_get_type(argument) != FL_VALUE_TYPE_STRING) {
    *error = std::string(key) + " must be a string.";
    return false;
  }
  *value = fl_value_get_string(argument);
  if (value->empty()) {
    *error = std::string(key) + " must not be empty.";
    return false;
  }
  return true;
}

bool ReadOptionalInstallString(FlValue* args,
                               const char* key,
                               std::string* value,
                               bool* present,
                               std::string* error) {
  FlValue* argument = fl_value_lookup_string(args, key);
  if (argument == nullptr) {
    *error = std::string(key) + " is required.";
    return false;
  }
  if (fl_value_get_type(argument) == FL_VALUE_TYPE_NULL) {
    value->clear();
    *present = false;
    return true;
  }
  if (fl_value_get_type(argument) != FL_VALUE_TYPE_STRING) {
    *error = std::string(key) + " must be a string or null.";
    return false;
  }
  *value = fl_value_get_string(argument);
  if (value->empty()) {
    *error = std::string(key) + " must not be empty when present.";
    return false;
  }
  *present = true;
  return true;
}

bool IsLowerHexSha256(const std::string& value) {
  if (value.size() != 64) return false;
  for (const char character : value) {
    if (!((character >= '0' && character <= '9') ||
          (character >= 'a' && character <= 'f'))) {
      return false;
    }
  }
  return true;
}

bool CurrentExecutableTarget(std::string* install_root,
                             std::string* executable_relative_path) {
  std::vector<char> buffer(4096);
  while (buffer.size() <= 1024 * 1024) {
    const ssize_t length =
        readlink("/proc/self/exe", buffer.data(), buffer.size());
    if (length < 0) return false;
    if (static_cast<size_t>(length) < buffer.size()) {
      const fs::path executable(
          std::string(buffer.data(), static_cast<size_t>(length)));
      if (!executable.is_absolute() || executable.parent_path().empty() ||
          executable.filename().empty()) {
        return false;
      }
      *install_root = executable.parent_path().string();
      *executable_relative_path = executable.filename().string();
      return true;
    }
    buffer.resize(buffer.size() * 2);
  }
  return false;
}

struct NativeInstallHandoffResult {
  bool ok;
  bool recovery_required;
  std::string error;
};

NativeInstallHandoffResult HandoffNativeInstall(
    const desktop_updater::native::InstallRequest& request,
    const std::string& transaction_id) {
  const auto validation =
      desktop_updater::native::ValidateInstallRequest(request);
  if (!validation.ok) return {false, false, validation.error};
  desktop_updater::native::InstallReservation reservation;
  const auto prepared =
      desktop_updater::native::PrepareInstall(request, transaction_id,
                                              &reservation);
  if (!prepared.ok) return {false, true, prepared.error};
  const auto status = desktop_updater::native::CommitAfterExit(reservation);
  if (!is_accepted_install_handoff(reservation, status)) {
    return {false, true,
            status.detail.empty()
                ? "Native install helper commit was not accepted."
                : status.detail};
  }
  return {true, false, ""};
}

FlValue* RecoveryRequiredErrorDetails(const std::string& transaction_id,
                                      const std::string& detail) {
  FlValue* value = fl_value_new_map();
  fl_value_set_string_take(value, "recoveryRequired", fl_value_new_bool(true));
  fl_value_set_string_take(
      value, "transactionId", fl_value_new_string(transaction_id.c_str()));
  fl_value_set_string_take(value, "detail",
                           fl_value_new_string(detail.c_str()));
  return value;
}

const char* TransactionStateName(
    desktop_updater::native::InstallTransactionState state) {
  using State = desktop_updater::native::InstallTransactionState;
  switch (state) {
    case State::kPrepared: return "prepared";
    case State::kCommitAccepted: return "commitAccepted";
    case State::kCompleted: return "completed";
    case State::kCancelled: return "cancelled";
    case State::kExpired: return "expired";
    case State::kRolledBack: return "rolledBack";
    case State::kManualActionRequired: return "manualActionRequired";
    case State::kUnknown: return "unknown";
  }
  return "unknown";
}

const char* TransactionResultName(
    desktop_updater::native::InstallTransactionResultCode code) {
  using Code = desktop_updater::native::InstallTransactionResultCode;
  switch (code) {
    case Code::kAccepted: return "accepted";
    case Code::kSucceeded: return "succeeded";
    case Code::kRejected: return "rejected";
    case Code::kEndpointUnavailable: return "endpointUnavailable";
    case Code::kAuthenticationFailed: return "authenticationFailed";
    case Code::kInvalidResponse: return "invalidResponse";
    case Code::kRecoveryRequired: return "recoveryRequired";
    case Code::kRelaunchFailure: return "relaunchFailure";
    case Code::kNone: return "none";
  }
  return "none";
}

FlValue* TransactionStatusValue(
    const desktop_updater::native::InstallTransactionStatus& status) {
  FlValue* value = fl_value_new_map();
  fl_value_set_string_take(
      value, "transactionId", fl_value_new_string(status.transaction_id.c_str()));
  fl_value_set_string_take(value, "state",
                           fl_value_new_string(TransactionStateName(status.state)));
  fl_value_set_string_take(
      value, "resultCode",
      fl_value_new_string(TransactionResultName(status.result_code)));
  fl_value_set_string_take(value, "detail",
                           fl_value_new_string(status.detail.c_str()));
  fl_value_set_string_take(
      value, "responseDigestSha256",
      fl_value_new_string(status.response_digest_sha256.c_str()));
  fl_value_set_string_take(
      value, "helperEndpointIdentitySha256",
      fl_value_new_string(status.helper_endpoint_identity_sha256.c_str()));
  return value;
}

bool ReadTransactionId(FlValue* args, std::string* transaction_id) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return false;
  }
  FlValue* value = fl_value_lookup_string(args, "transactionId");
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) {
    return false;
  }
  *transaction_id = fl_value_get_string(value);
  return !transaction_id->empty();
}

}  // namespace

bool is_accepted_install_handoff(
    const desktop_updater::native::InstallReservation& reservation,
    const desktop_updater::native::InstallTransactionStatus& status) {
  const bool accepted_state =
      status.state ==
          desktop_updater::native::InstallTransactionState::kCommitAccepted ||
      status.state == desktop_updater::native::InstallTransactionState::kCompleted;
  const bool accepted_result =
      status.result_code ==
          desktop_updater::native::InstallTransactionResultCode::kAccepted ||
      status.result_code ==
          desktop_updater::native::InstallTransactionResultCode::kSucceeded;
  return accepted_state && accepted_result &&
         status.transaction_id == reservation.transaction_id &&
         status.response_digest_sha256 == reservation.response_digest_sha256 &&
         status.helper_endpoint_identity_sha256 ==
             reservation.helper_endpoint_identity_sha256;
}

FlMethodResponse* get_platform_version() {
  struct utsname uname_data = {};
  uname(&uname_data);
  g_autofree gchar* version = g_strdup_printf("Linux %s", uname_data.version);
  g_autoptr(FlValue) result = fl_value_new_string(version);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

#define DESKTOP_UPDATER_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), desktop_updater_plugin_get_type(), \
                              DesktopUpdaterPlugin))

struct _DesktopUpdaterPlugin {
  GObject parent_instance;
};

G_DEFINE_TYPE(DesktopUpdaterPlugin, desktop_updater_plugin, g_object_get_type())

static void desktop_updater_plugin_handle_method_call(
    DesktopUpdaterPlugin* self,
    FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* method = fl_method_call_get_name(method_call);

  if (strcmp(method, "getPlatformVersion") == 0) {
    response = get_platform_version();
  } else if (strcmp(method, "restartApp") == 0) {
    const auto result = desktop_updater::native::RestartCurrentApplication();
    if (!result.ok) {
      g_autoptr(FlValue) details = fl_value_new_string(result.error.c_str());
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "RestartError", result.error.c_str(), details));
    } else {
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
      fl_method_call_respond(method_call, response, nullptr);
      std::exit(0);
    }
  } else if (strcmp(method, "installUpdate") == 0) {
    FlValue* args = fl_method_call_get_args(method_call);
    if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "InvalidArguments", "installUpdate expects a map.", nullptr));
    } else if (fl_value_get_length(args) != 9) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "InvalidArguments", "installUpdate expects exactly nine arguments.",
          nullptr));
    } else {
      std::string staging_path;
      std::string expected_package_id;
      std::string expected_version;
      std::string expected_build_number;
      bool expected_build_number_present = false;
      std::string expected_platform;
      std::string expected_channel;
      std::string expected_artifact_sha256;
      std::string expected_provenance_sha256;
      std::string transaction_id;
      std::string argument_error;
      if (!ReadRequiredInstallString(args, "stagingPath", &staging_path,
                                     &argument_error) ||
          !ReadRequiredInstallString(args, "expectedPackageId",
                                     &expected_package_id, &argument_error) ||
          !ReadRequiredInstallString(args, "updateVersion", &expected_version,
                                     &argument_error) ||
          !ReadOptionalInstallString(args, "updateBuildNumber",
                                     &expected_build_number,
                                     &expected_build_number_present,
                                     &argument_error) ||
          !ReadRequiredInstallString(args, "platform", &expected_platform,
                                     &argument_error) ||
          !ReadRequiredInstallString(args, "channel", &expected_channel,
                                     &argument_error) ||
          !ReadRequiredInstallString(args, "expectedArtifactSha256",
                                     &expected_artifact_sha256,
                                     &argument_error) ||
          !ReadRequiredInstallString(args, "stageProvenanceSha256",
                                     &expected_provenance_sha256,
                                     &argument_error) ||
          !ReadRequiredInstallString(args, "transactionId", &transaction_id,
                                     &argument_error)) {
        response = FL_METHOD_RESPONSE(fl_method_error_response_new(
            "InvalidArguments", argument_error.c_str(), nullptr));
      } else if (!IsLowerHexSha256(expected_artifact_sha256)) {
        response = FL_METHOD_RESPONSE(fl_method_error_response_new(
            "InvalidArguments",
            "expectedArtifactSha256 must be a lowercase SHA-256 digest.",
            nullptr));
      } else {
        std::int64_t expected_build_number_value = 0;
        if (expected_build_number_present) {
          try {
            std::size_t consumed = 0;
            expected_build_number_value = std::stoll(
                expected_build_number, &consumed, 10);
            if (consumed != expected_build_number.size()) {
              throw std::invalid_argument("trailing characters");
            }
          } catch (const std::exception&) {
            response = FL_METHOD_RESPONSE(fl_method_error_response_new(
                "InvalidArguments",
                "updateBuildNumber must be an integer or null.", nullptr));
            fl_method_call_respond(method_call, response, nullptr);
            return;
          }
        }
        std::string install_root;
        std::string executable_relative_path;
        if (!CurrentExecutableTarget(&install_root,
                                     &executable_relative_path)) {
          response = FL_METHOD_RESPONSE(fl_method_error_response_new(
              "InstallError",
              "Unable to derive the running Linux install target.", nullptr));
        } else {
          desktop_updater::native::InstallRequest request;
          request.staging_path = staging_path;
          request.install_root = install_root;
          request.executable_relative_path = executable_relative_path;
          request.package_id = expected_package_id;
          request.expected_provenance_sha256 = expected_provenance_sha256;
          request.expected_artifact_sha256 = expected_artifact_sha256;
          request.expected_version = expected_version;
          request.expected_platform = expected_platform;
          request.expected_channel = expected_channel;
          request.expected_build_number_present = expected_build_number_present;
          request.expected_build_number = expected_build_number_value;
          const auto result = HandoffNativeInstall(request, transaction_id);
          if (!result.ok) {
            g_autoptr(FlValue) details = result.recovery_required
                                             ? RecoveryRequiredErrorDetails(
                                                   transaction_id,
                                                   result.error)
                                             : fl_value_new_string(
                                                   result.error.c_str());
            response = FL_METHOD_RESPONSE(fl_method_error_response_new(
                "InstallError", result.error.c_str(), details));
          } else {
            response =
                FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
            fl_method_call_respond(method_call, response, nullptr);
            std::exit(0);
          }
        }
      }
    }
  } else if (strcmp(method, "queryInstallTransaction") == 0 ||
             strcmp(method, "recoverPendingInstallTransaction") == 0) {
    std::string transaction_id;
    if (!ReadTransactionId(fl_method_call_get_args(method_call),
                           &transaction_id)) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "InvalidArguments", "transactionId must be a string.", nullptr));
    } else {
      const auto status = strcmp(method, "queryInstallTransaction") == 0
                              ? desktop_updater::native::QueryTransaction(
                                    transaction_id)
                              : desktop_updater::native::RecoverPendingInstall(
                                    transaction_id);
      g_autoptr(FlValue) value = TransactionStatusValue(status);
      response =
          FL_METHOD_RESPONSE(fl_method_success_response_new(value));
    }
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

static void desktop_updater_plugin_dispose(GObject* object) {
  G_OBJECT_CLASS(desktop_updater_plugin_parent_class)->dispose(object);
}

static void desktop_updater_plugin_class_init(DesktopUpdaterPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = desktop_updater_plugin_dispose;
}

static void desktop_updater_plugin_init(DesktopUpdaterPlugin* self) {}

static void method_call_cb(FlMethodChannel* channel,
                           FlMethodCall* method_call,
                           gpointer user_data) {
  DesktopUpdaterPlugin* plugin = DESKTOP_UPDATER_PLUGIN(user_data);
  desktop_updater_plugin_handle_method_call(plugin, method_call);
}

void desktop_updater_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  DesktopUpdaterPlugin* plugin = DESKTOP_UPDATER_PLUGIN(
      g_object_new(desktop_updater_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "desktop_updater", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      channel, method_call_cb, g_object_ref(plugin), g_object_unref);

  g_object_unref(plugin);
}
