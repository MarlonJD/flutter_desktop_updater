#include "desktop_updater_plugin_private.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <sys/utsname.h>

#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "desktop_updater_native.h"

namespace {

bool ReadOptionalString(FlValue* args,
                        const char* key,
                        std::string* value,
                        std::string* error) {
  FlValue* argument = fl_value_lookup_string(args, key);
  if (argument == nullptr) {
    value->clear();
    return true;
  }
  if (fl_value_get_type(argument) != FL_VALUE_TYPE_STRING) {
    *error = std::string(key) + " must be a string when provided.";
    return false;
  }
  *value = fl_value_get_string(argument);
  return true;
}

desktop_updater::native::InstallRequest RestartRequest() {
  desktop_updater::native::InstallRequest request;
  request.operation = desktop_updater::native::LinuxInstallOperation::kRestart;
  return request;
}

}  // namespace

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
    const auto result = desktop_updater::native::ScheduleInstallAndRelaunch(
        RestartRequest());
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
    } else {
      FlValue* staging_value = fl_value_lookup_string(args, "stagingPath");
      if (staging_value == nullptr ||
          fl_value_get_type(staging_value) != FL_VALUE_TYPE_STRING) {
        response = FL_METHOD_RESPONSE(fl_method_error_response_new(
            "InvalidArguments", "stagingPath must be a string.", nullptr));
      } else {
        std::vector<std::string> removed_files;
        FlValue* removed_value = fl_value_lookup_string(args, "removedFiles");
        if (removed_value != nullptr &&
            fl_value_get_type(removed_value) == FL_VALUE_TYPE_LIST) {
          const size_t length = fl_value_get_length(removed_value);
          for (size_t index = 0; index < length; ++index) {
            FlValue* item = fl_value_get_list_value(removed_value, index);
            if (item != nullptr &&
                fl_value_get_type(item) == FL_VALUE_TYPE_STRING) {
              removed_files.push_back(fl_value_get_string(item));
            }
          }
        }

        std::string diagnostics_log_path;
        std::string install_root;
        std::string executable_relative_path;
        std::string package_id;
        std::string argument_error;
        const bool context_is_valid =
            ReadOptionalString(args, "diagnosticsLogPath",
                               &diagnostics_log_path, &argument_error) &&
            ReadOptionalString(args, "installRoot", &install_root,
                               &argument_error) &&
            ReadOptionalString(args, "executableRelativePath",
                               &executable_relative_path, &argument_error) &&
            ReadOptionalString(args, "packageId", &package_id,
                               &argument_error);
        if (!context_is_valid) {
          response = FL_METHOD_RESPONSE(fl_method_error_response_new(
              "InvalidArguments", argument_error.c_str(), nullptr));
        } else {
          desktop_updater::native::InstallRequest request;
          request.operation =
              desktop_updater::native::LinuxInstallOperation::kInstall;
          request.staging_path = fl_value_get_string(staging_value);
          request.install_root = install_root;
          request.executable_relative_path = executable_relative_path;
          request.package_id = package_id;
          request.removed_files = removed_files;
          request.diagnostics_log_path = diagnostics_log_path;
          const auto result =
              desktop_updater::native::ScheduleInstallAndRelaunch(request);
          if (!result.ok) {
            g_autoptr(FlValue) details =
                fl_value_new_string(result.error.c_str());
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
