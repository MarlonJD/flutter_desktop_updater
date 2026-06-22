#include "include/desktop_updater/desktop_updater_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <sys/utsname.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <libgen.h>
#include <cstdlib>
#include <iostream>
#include <fstream>
#include <string>
#include <vector>
#include <linux/limits.h>

// Forward declarations
FlMethodResponse *get_platform_version();
bool schedule_install_update(const std::string &staging_path,
                             const std::vector<std::string> &removed_files,
                             const std::string &diagnostics_log_path,
                             std::string *error);

// Function to copy file from source to destination
bool copy_file(const char *source, const char *destination)
{
  char buffer[4096];
  size_t size;

  FILE *source_file = fopen(source, "rb");
  FILE *dest_file = fopen(destination, "wb");

  if (source_file == nullptr || dest_file == nullptr)
  {
    if (source_file)
      fclose(source_file);
    if (dest_file)
      fclose(dest_file);
    return false;
  }

  while ((size = fread(buffer, 1, sizeof(buffer), source_file)))
  {
    fwrite(buffer, 1, size, dest_file);
  }

  fclose(source_file);
  fclose(dest_file);
  return true;
}

std::string shell_quote(const std::string &value)
{
  std::string quoted = "'";
  for (char character : value)
  {
    if (character == '\'')
    {
      quoted += "'\\''";
    }
    else
    {
      quoted += character;
    }
  }
  quoted += "'";
  return quoted;
}

std::string current_executable_path()
{
  char executable_path[PATH_MAX];
  ssize_t len = readlink("/proc/self/exe", executable_path, sizeof(executable_path) - 1);
  if (len == -1)
  {
    return "";
  }
  executable_path[len] = '\0';
  return std::string(executable_path);
}

std::string parent_directory(const std::string &file_path)
{
  char *copy = strdup(file_path.c_str());
  std::string result = dirname(copy);
  free(copy);
  return result;
}

std::string base_name(const std::string &file_path)
{
  char *copy = strdup(file_path.c_str());
  std::string result = basename(copy);
  free(copy);
  return result;
}

std::string shell_array(const std::vector<std::string> &values)
{
  if (values.empty())
  {
    return "";
  }

  std::string result;
  for (const auto &value : values)
  {
    result += " " + shell_quote(value);
  }
  return result;
}

bool write_file(const std::string &path, const std::string &contents)
{
  std::ofstream file(path, std::ios::binary | std::ios::trunc);
  if (!file.is_open())
  {
    return false;
  }
  file << contents;
  return file.good();
}

bool start_detached_script(const std::string &script_path)
{
  pid_t pid = fork();
  if (pid == 0)
  {
    execl("/bin/bash", "bash", script_path.c_str(), nullptr);
    _exit(1);
  }
  return pid > 0;
}

bool schedule_install_update(const std::string &staging_path,
                             const std::vector<std::string> &removed_files,
                             const std::string &diagnostics_log_path,
                             std::string *error)
{
  const std::string executable_path = current_executable_path();
  if (executable_path.empty())
  {
    *error = "Unable to resolve executable path.";
    return false;
  }

  if (!staging_path.empty())
  {
    struct stat staging_stat = {};
    if (stat(staging_path.c_str(), &staging_stat) != 0 || !S_ISDIR(staging_stat.st_mode))
    {
      *error = "Staged update directory does not exist.";
      return false;
    }
  }

  const std::string target_directory = parent_directory(executable_path);
  const std::string script_path =
      "/tmp/desktop_updater_" + std::to_string(getpid()) + ".sh";
  const std::string removed_values = shell_array(removed_files);
  const std::string script =
      "#!/bin/bash\n"
      "set -euo pipefail\n"
      "pid_to_wait=" +
      std::to_string(getpid()) + "\n"
                              "staging=" +
      shell_quote(staging_path) + "\n"
                                  "target=" +
      shell_quote(target_directory) + "\n"
                                      "exe=" +
      shell_quote(executable_path) + "\n"
                                     "diagnostics_log=" +
      shell_quote(diagnostics_log_path) + "\n"
                                     "removed=(" +
      removed_values + ")\n"
                       "skip_relaunch=\"${DESKTOP_UPDATER_SMOKE_SKIP_RELAUNCH:-}\"\n"
                       "log_event() {\n"
                       "  [ -n \"$diagnostics_log\" ] || return 0\n"
                       "  printf '{\"timestamp\":\"%s\",\"event\":\"%s\"}\\n' \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\" \"$1\" >> \"$diagnostics_log\" 2>/dev/null || true\n"
                       "}\n"
                       "log_event \"helper scheduled\"\n"
                       "log_event \"waiting for parent process\"\n"
                       "while kill -0 \"$pid_to_wait\" 2>/dev/null; do sleep 0.5; done\n"
                       "log_event \"parent process exited\"\n"
                       "target_root=\"$(cd \"$target\" && pwd -P)\"\n"
                       "backup=\"$(mktemp -d /tmp/desktop_updater_backup_XXXXXX)\"\n"
                       "rollback() {\n"
                       "  [ -d \"$backup\" ] || return 0\n"
                       "  log_event \"rollback start\"\n"
                       "  set +e\n"
                       "  rm -rf \"$target\"\n"
                       "  mkdir -p \"$(dirname \"$target\")\"\n"
                       "  cp -a \"$backup/.\" \"$target/\"\n"
                       "  rollback_status=$?\n"
                       "  set -e\n"
                       "  if [ \"$rollback_status\" -eq 0 ]; then\n"
                       "    log_event \"rollback success\"\n"
                       "  else\n"
                       "    log_event \"rollback failure\"\n"
                       "  fi\n"
                       "  return \"$rollback_status\"\n"
                       "}\n"
                       "rollback_and_exit() {\n"
                       "  rollback || true\n"
                       "  rm -rf \"$backup\"\n"
                       "  exit 1\n"
                       "}\n"
                       "trap 'rollback_and_exit' ERR\n"
                       "log_event \"backup start\"\n"
                       "if cp -a \"$target/.\" \"$backup/\"; then\n"
                       "  log_event \"backup success\"\n"
                       "else\n"
                       "  log_event \"backup failure\"\n"
                       "  rm -rf \"$backup\"\n"
                       "  exit 1\n"
                       "fi\n"
                       "for relative in \"${removed[@]}\"; do\n"
                       "  [ -z \"$relative\" ] && continue\n"
                       "  candidate=\"$(realpath -m \"$target/$relative\")\"\n"
                       "  case \"$candidate\" in\n"
                       "    \"$target_root\"/*) [ -e \"$candidate\" ] && rm -rf \"$candidate\" ;;\n"
                       "    *) echo \"Removed file escapes app root: $relative\" >&2; rollback_and_exit ;;\n"
                       "  esac\n"
                       "done\n"
                       "if [ -n \"$staging\" ]; then\n"
                       "  log_event \"staging path validation\"\n"
                       "  if [ ! -d \"$staging\" ]; then\n"
                       "    log_event \"staging path validation failure\"\n"
                       "    rm -rf \"$backup\"\n"
                       "    exit 1\n"
                       "  fi\n"
                       "  log_event \"move start\"\n"
                       "  if find \"$target\" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + && cp -a \"$staging/.\" \"$target/\"; then\n"
                       "    log_event \"move success\"\n"
                       "  else\n"
                       "    log_event \"move failure\"\n"
                       "    rollback_and_exit\n"
                       "  fi\n"
                       "  if [ -e \"$exe\" ] && [ ! -x \"$exe\" ]; then\n"
                       "    log_event \"permission restore start\"\n"
                       "    if chmod +x \"$exe\"; then\n"
                       "      log_event \"permission restore success\"\n"
                       "    else\n"
                       "      log_event \"permission restore failure\"\n"
                       "      rollback_and_exit\n"
                       "    fi\n"
                       "  elif [ ! -e \"$exe\" ] && [ \"$skip_relaunch\" != \"1\" ]; then\n"
                       "    log_event \"permission restore failure\"\n"
                       "    rollback_and_exit\n"
                       "  fi\n"
                       "  log_event \"cleanup start\"\n"
                       "  if rm -rf \"$staging\"; then\n"
                       "    log_event \"cleanup success\"\n"
                       "  else\n"
                       "    log_event \"cleanup failure\"\n"
                       "  fi\n"
                       "fi\n"
                       "rm -rf \"$backup\"\n"
                       "trap - ERR\n"
                       "if [ \"$skip_relaunch\" != \"1\" ]; then\n"
                       "  log_event \"relaunch attempt\"\n"
                       "  cd \"$target\"\n"
                       "  \"$exe\" &\n"
                       "fi\n"
                       "rm -f \"$0\"\n";

  if (!write_file(script_path, script))
  {
    *error = "Unable to write update helper script.";
    return false;
  }

  chmod(script_path.c_str(), 0755);
  if (!start_detached_script(script_path))
  {
    *error = "Unable to start update helper script.";
    return false;
  }

  return true;
}

// Implementation of get_platform_version
FlMethodResponse *get_platform_version()
{
  struct utsname uname_data = {};
  uname(&uname_data);
  g_autofree gchar *version = g_strdup_printf("Linux %s", uname_data.version);
  g_autoptr(FlValue) result = fl_value_new_string(version);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

#define DESKTOP_UPDATER_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), desktop_updater_plugin_get_type(), \
                              DesktopUpdaterPlugin))

struct _DesktopUpdaterPlugin
{
  GObject parent_instance;
};

G_DEFINE_TYPE(DesktopUpdaterPlugin, desktop_updater_plugin, g_object_get_type())

// Called when a method call is received from Flutter.
static void desktop_updater_plugin_handle_method_call(
    DesktopUpdaterPlugin *self,
    FlMethodCall *method_call)
{
  g_autoptr(FlMethodResponse) response = nullptr;

  const gchar *method = fl_method_call_get_name(method_call);

  if (strcmp(method, "getPlatformVersion") == 0)
  {
    response = get_platform_version();
  }
  else if (strcmp(method, "restartApp") == 0)
  {
    std::string error;
    if (!schedule_install_update("", {}, "", &error))
    {
      g_autoptr(FlValue) details = fl_value_new_string(error.c_str());
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "RestartError", error.c_str(), details));
    }
    else
    {
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
      fl_method_call_respond(method_call, response, nullptr);
      exit(0);
      return;
    }
  }
  else if (strcmp(method, "installUpdate") == 0)
  {
    FlValue *args = fl_method_call_get_args(method_call);
    if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP)
    {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "InvalidArguments", "installUpdate expects a map.", nullptr));
    }
    else
    {
      FlValue *staging_value = fl_value_lookup_string(args, "stagingPath");
      if (staging_value == nullptr || fl_value_get_type(staging_value) != FL_VALUE_TYPE_STRING)
      {
        response = FL_METHOD_RESPONSE(fl_method_error_response_new(
            "InvalidArguments", "stagingPath must be a string.", nullptr));
      }
      else
      {
        std::vector<std::string> removed_files;
        FlValue *removed_value = fl_value_lookup_string(args, "removedFiles");
        if (removed_value != nullptr && fl_value_get_type(removed_value) == FL_VALUE_TYPE_LIST)
        {
          const size_t length = fl_value_get_length(removed_value);
          for (size_t i = 0; i < length; ++i)
          {
            FlValue *item = fl_value_get_list_value(removed_value, i);
            if (item != nullptr && fl_value_get_type(item) == FL_VALUE_TYPE_STRING)
            {
              removed_files.push_back(fl_value_get_string(item));
            }
          }
        }

        std::string diagnostics_log_path;
        FlValue *diagnostics_value =
            fl_value_lookup_string(args, "diagnosticsLogPath");
        if (diagnostics_value != nullptr &&
            fl_value_get_type(diagnostics_value) == FL_VALUE_TYPE_STRING)
        {
          diagnostics_log_path = fl_value_get_string(diagnostics_value);
        }

        std::string error;
        if (!schedule_install_update(fl_value_get_string(staging_value),
                                     removed_files, diagnostics_log_path,
                                     &error))
        {
          g_autoptr(FlValue) details = fl_value_new_string(error.c_str());
          response = FL_METHOD_RESPONSE(fl_method_error_response_new(
              "InstallError", error.c_str(), details));
        }
        else
        {
          response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
          fl_method_call_respond(method_call, response, nullptr);
          exit(0);
          return;
        }
      }
    }
  }
  else
  {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

static void desktop_updater_plugin_dispose(GObject *object)
{
  G_OBJECT_CLASS(desktop_updater_plugin_parent_class)->dispose(object);
}

static void desktop_updater_plugin_class_init(DesktopUpdaterPluginClass *klass)
{
  G_OBJECT_CLASS(klass)->dispose = desktop_updater_plugin_dispose;
}

static void desktop_updater_plugin_init(DesktopUpdaterPlugin *self) {}

static void method_call_cb(FlMethodChannel *channel, FlMethodCall *method_call,
                           gpointer user_data)
{
  DesktopUpdaterPlugin *plugin = DESKTOP_UPDATER_PLUGIN(user_data);
  desktop_updater_plugin_handle_method_call(plugin, method_call);
}

void desktop_updater_plugin_register_with_registrar(FlPluginRegistrar *registrar)
{
  DesktopUpdaterPlugin *plugin = DESKTOP_UPDATER_PLUGIN(
      g_object_new(desktop_updater_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "desktop_updater",
                            FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);

  g_object_unref(plugin);
}
