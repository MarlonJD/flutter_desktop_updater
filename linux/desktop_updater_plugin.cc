#include "desktop_updater_plugin_private.h"

#include <cerrno>
#include <cstring>
#include <cstdlib>
#include <fstream>
#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <libgen.h>
#include <linux/limits.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <iostream>
#include <string>
#include <unordered_set>
#include <utility>
#include <vector>
#include <unistd.h>

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

namespace
{
const std::unordered_set<std::string> kProtectedInstallRoots = {
    "/",          "/bin",       "/sbin",      "/usr",
    "/usr/bin",   "/usr/sbin",  "/usr/local", "/usr/local/bin",
    "/opt",       "/etc",       "/var",       "/home",
};

bool is_canonical_absolute_path(const std::string &path)
{
  if (path.empty() || path.front() != '/')
  {
    return false;
  }
  if (path == "/")
  {
    return true;
  }
  if (path.back() == '/')
  {
    return false;
  }

  size_t segment_start = 1;
  while (segment_start < path.size())
  {
    const size_t segment_end = path.find('/', segment_start);
    const size_t length =
        segment_end == std::string::npos ? std::string::npos
                                         : segment_end - segment_start;
    const std::string segment = path.substr(segment_start, length);
    if (segment.empty() || segment == "." || segment == "..")
    {
      return false;
    }
    if (segment_end == std::string::npos)
    {
      break;
    }
    segment_start = segment_end + 1;
  }
  return true;
}

bool is_canonical_relative_path(const std::string &path)
{
  if (path.empty() || path.front() == '/' || path.back() == '/')
  {
    return false;
  }

  size_t segment_start = 0;
  while (segment_start < path.size())
  {
    const size_t segment_end = path.find('/', segment_start);
    const size_t length =
        segment_end == std::string::npos ? std::string::npos
                                         : segment_end - segment_start;
    const std::string segment = path.substr(segment_start, length);
    if (segment.empty() || segment == "." || segment == "..")
    {
      return false;
    }
    if (segment_end == std::string::npos)
    {
      break;
    }
    segment_start = segment_end + 1;
  }
  return true;
}

std::string join_path(const std::string &root, const std::string &relative)
{
  return root == "/" ? root + relative : root + "/" + relative;
}

bool is_strict_descendant(const std::string &path, const std::string &root)
{
  if (root == "/")
  {
    return path.size() > 1 && path.front() == '/';
  }
  return path.size() > root.size() &&
         path.compare(0, root.size(), root) == 0 &&
         path[root.size()] == '/';
}

bool paths_overlap(const std::string &first, const std::string &second)
{
  return first == second || is_strict_descendant(first, second) ||
         is_strict_descendant(second, first);
}

bool has_symlink_component(const std::string &path)
{
  if (!is_canonical_absolute_path(path))
  {
    return true;
  }

  std::string current;
  size_t segment_start = 1;
  while (segment_start < path.size())
  {
    const size_t segment_end = path.find('/', segment_start);
    const size_t length =
        segment_end == std::string::npos ? std::string::npos
                                         : segment_end - segment_start;
    current += "/" + path.substr(segment_start, length);
    struct stat path_stat = {};
    if (lstat(current.c_str(), &path_stat) == 0 && S_ISLNK(path_stat.st_mode))
    {
      return true;
    }
    if (segment_end == std::string::npos)
    {
      break;
    }
    segment_start = segment_end + 1;
  }
  return false;
}

bool resolve_existing_path(const std::string &path, std::string *resolved)
{
  char buffer[PATH_MAX];
  if (realpath(path.c_str(), buffer) == nullptr)
  {
    return false;
  }
  *resolved = buffer;
  return true;
}

bool read_optional_string(FlValue *args,
                          const char *key,
                          std::string *value,
                          std::string *error)
{
  FlValue *argument = fl_value_lookup_string(args, key);
  if (argument == nullptr)
  {
    value->clear();
    return true;
  }
  if (fl_value_get_type(argument) != FL_VALUE_TYPE_STRING)
  {
    *error = std::string(key) + " must be a string when provided.";
    return false;
  }
  *value = fl_value_get_string(argument);
  return true;
}
} // namespace

InstallResult ValidateLinuxInstallTarget(const LinuxInstallTarget &target)
{
  if (!is_canonical_absolute_path(target.install_root))
  {
    return {false, "Linux install root must be an absolute canonical path."};
  }
  if (kProtectedInstallRoots.count(target.install_root) != 0)
  {
    return {false, "Linux install root is a protected shared/system root."};
  }
  if (has_symlink_component(target.install_root))
  {
    return {false, "Linux install root must not contain symbolic links."};
  }
  if (!is_canonical_relative_path(target.executable_relative_path))
  {
    return {false,
            "Linux executable path must be a canonical relative path without "
            "dot segments."};
  }

  const std::string executable_path =
      join_path(target.install_root, target.executable_relative_path);
  if (!is_strict_descendant(executable_path, target.install_root) ||
      has_symlink_component(executable_path))
  {
    return {false, "Linux executable must resolve inside install root."};
  }

  std::string resolved_root;
  if (resolve_existing_path(target.install_root, &resolved_root) &&
      resolved_root != target.install_root)
  {
    return {false, "Linux install root must already be canonical."};
  }
  std::string resolved_executable;
  if (resolve_existing_path(executable_path, &resolved_executable) &&
      !is_strict_descendant(resolved_executable, target.install_root))
  {
    return {false, "Linux executable resolves outside install root."};
  }

  if (target.operation == LinuxInstallOperation::kInstall &&
      target.package_id.find_first_not_of(" \t\r\n") == std::string::npos)
  {
    return {false,
            "Linux install package identity is required; use a fresh "
            "installer when identity cannot be verified."};
  }
  return {true, ""};
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

bool schedule_install_update(LinuxInstallOperation operation,
                             const std::string &staging_path,
                             const std::vector<std::string> &removed_files,
                             const std::string &diagnostics_log_path,
                             const std::string &install_root,
                             const std::string &executable_relative_path,
                             const std::string &package_id,
                             std::string *error)
{
  std::string executable_path;
  if (!resolve_existing_path(current_executable_path(), &executable_path))
  {
    *error = "Unable to resolve executable path.";
    return false;
  }

  const std::string target_directory =
      install_root.empty() ? parent_directory(executable_path) : install_root;
  std::string target_executable_relative_path = executable_relative_path;
  if (target_executable_relative_path.empty())
  {
    if (is_strict_descendant(executable_path, target_directory))
    {
      target_executable_relative_path =
          executable_path.substr(target_directory.size() + 1);
    }
    else
    {
      target_executable_relative_path = base_name(executable_path);
    }
  }

  const LinuxInstallTarget target = {
      operation,
      target_directory,
      target_executable_relative_path,
      package_id,
  };
  const InstallResult validation = ValidateLinuxInstallTarget(target);
  if (!validation.ok)
  {
    *error = validation.error;
    return false;
  }

  std::string canonical_target;
  if (!resolve_existing_path(target.install_root, &canonical_target) ||
      canonical_target != target.install_root)
  {
    *error = "Linux install root does not resolve to an existing canonical directory.";
    return false;
  }
  const std::string requested_executable =
      join_path(canonical_target, target.executable_relative_path);
  std::string canonical_requested_executable;
  if (!resolve_existing_path(requested_executable,
                             &canonical_requested_executable) ||
      canonical_requested_executable != executable_path)
  {
    *error = "Linux install executable does not match the running app.";
    return false;
  }

  std::string canonical_staging_path;
  if (operation == LinuxInstallOperation::kInstall)
  {
    struct stat staging_stat = {};
    if (staging_path.empty() ||
        lstat(staging_path.c_str(), &staging_stat) != 0 ||
        !S_ISDIR(staging_stat.st_mode) || S_ISLNK(staging_stat.st_mode) ||
        !resolve_existing_path(staging_path, &canonical_staging_path))
    {
      *error = "Staged update directory does not exist or is not a real directory.";
      return false;
    }
    if (paths_overlap(canonical_staging_path, canonical_target))
    {
      *error = "Staging path must not overlap install root.";
      return false;
    }

    for (const auto &relative : removed_files)
    {
      if (relative.empty())
      {
        continue;
      }
      if (!is_canonical_relative_path(relative))
      {
        *error = "Removed file path escapes install root.";
        return false;
      }
      const std::string candidate = join_path(canonical_target, relative);
      if (!is_strict_descendant(candidate, canonical_target) ||
          has_symlink_component(candidate))
      {
        *error = "Removed file path escapes install root.";
        return false;
      }
      std::string resolved_candidate;
      if (resolve_existing_path(candidate, &resolved_candidate) &&
          !is_strict_descendant(resolved_candidate, canonical_target))
      {
        *error = "Removed file path escapes install root.";
        return false;
      }
    }
  }

  const std::string script_path =
      "/tmp/desktop_updater_" + std::to_string(getpid()) + ".sh";
  const std::string removed_values = shell_array(removed_files);
  std::string script =
      "#!/bin/bash\n"
      "set -euo pipefail\n"
      "pid_to_wait=" +
      std::to_string(getpid()) + "\n"
                              "staging=" +
      shell_quote(canonical_staging_path) + "\n"
                                  "target=" +
      shell_quote(canonical_target) + "\n"
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
                       "resolved_target=\"$(cd \"$target\" && pwd -P)\"\n"
                       "if [ \"$resolved_target\" != \"$target\" ]; then exit 1; fi\n";

  if (operation == LinuxInstallOperation::kRestart)
  {
    script += "if [ \"$skip_relaunch\" != \"1\" ]; then\n"
              "  log_event \"relaunch attempt\"\n"
              "  cd \"$target\"\n"
              "  \"$exe\" &\n"
              "fi\n"
              "rm -f \"$0\"\n";
  }
  else
  {
    script += "target_root=\"$resolved_target\"\n"
                       "staging_root=\"$(cd \"$staging\" && pwd -P)\"\n"
                       "case \"$staging_root\" in\n"
                       "  \"$target_root\"|\"$target_root\"/*) exit 1 ;;\n"
                       "esac\n"
                       "case \"$target_root\" in\n"
                       "  \"$staging_root\"/*) exit 1 ;;\n"
                       "esac\n"
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
  }

  if (!write_file(script_path, script))
  {
    *error = "Unable to write update helper script.";
    return false;
  }

  chmod(script_path.c_str(), 0755);
  if (!start_detached_script(script_path))
  {
    unlink(script_path.c_str());
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
    if (!schedule_install_update(LinuxInstallOperation::kRestart,
                                 "", {}, "", "", "", "", &error))
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
        std::string install_root;
        std::string executable_relative_path;
        std::string package_id;
        std::string argument_error;
        const bool context_is_valid =
            read_optional_string(args, "diagnosticsLogPath",
                                 &diagnostics_log_path, &argument_error) &&
            read_optional_string(args, "installRoot", &install_root,
                                 &argument_error) &&
            read_optional_string(args, "executableRelativePath",
                                 &executable_relative_path, &argument_error) &&
            read_optional_string(args, "packageId", &package_id,
                                 &argument_error);
        if (!context_is_valid)
        {
          response = FL_METHOD_RESPONSE(fl_method_error_response_new(
              "InvalidArguments", argument_error.c_str(), nullptr));
        }
        else
        {
          std::string error;
          if (!schedule_install_update(
                  LinuxInstallOperation::kInstall,
                  fl_value_get_string(staging_value), removed_files,
                  diagnostics_log_path, install_root,
                  executable_relative_path, package_id, &error))
          {
            g_autoptr(FlValue) details = fl_value_new_string(error.c_str());
            response = FL_METHOD_RESPONSE(fl_method_error_response_new(
                "InstallError", error.c_str(), details));
          }
          else
          {
            response =
                FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
            fl_method_call_respond(method_call, response, nullptr);
            exit(0);
            return;
          }
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
