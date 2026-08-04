#include "linux_helper_diagnostics.h"

#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <syslog.h>
#include <unistd.h>

#include <chrono>
#include <set>
#include <string>
#include <utility>

#include "json_value.h"
#include "linux_transaction_registry.h"

namespace desktop_updater::helper {
namespace {

bool SafeAtom(const std::string& value, std::size_t maximum) {
  if (value.empty() || value.size() > maximum) return false;
  for (unsigned char byte : value) {
    if (!((byte >= 'A' && byte <= 'Z') ||
          (byte >= 'a' && byte <= 'z') ||
          (byte >= '0' && byte <= '9') || byte == '.' || byte == '_' ||
          byte == '-')) {
      return false;
    }
  }
  return true;
}

void WriteAll(int fd, const std::string& bytes) {
  std::size_t offset = 0;
  while (offset < bytes.size()) {
    const ssize_t count =
        write(fd, bytes.data() + offset, bytes.size() - offset);
    if (count <= 0) return;
    offset += static_cast<std::size_t>(count);
  }
}

}  // namespace

void EmitLinuxHelperDiagnostic(
    bool broker_mode,
    const runtime::internal::NativeInstallTransactionRequestV1& request,
    const std::string& journal_state,
    const std::string& event,
    const std::string& detail_code) noexcept {
  static const std::set<std::string> events = {
      "helper authenticated", "target lock acquired",
      "transaction journal persisted", "caller exit observed",
      "recovery detected", "backup restored", "activation verified",
      "package manager state verified", "manual action required",
      "transaction completed"};
  try {
    if (events.count(event) == 0 ||
        !SafeAtom(request.package_id, 128) ||
        !SafeAtom(request.transaction_id, 64) ||
        !SafeAtom(request.target.target_class, 64) ||
        !SafeAtom(request.target.target_name_hint, 255) ||
        !SafeAtom(journal_state, 64) || !SafeAtom(detail_code, 128)) {
      return;
    }
    runtime::internal::JsonValue::Object value;
    value.emplace("detailCode",
                  runtime::internal::JsonValue(detail_code));
    value.emplace("event", runtime::internal::JsonValue(event));
    value.emplace("journalState",
                  runtime::internal::JsonValue(journal_state));
    value.emplace("packageId",
                  runtime::internal::JsonValue(request.package_id));
    value.emplace("targetClass",
                  runtime::internal::JsonValue(request.target.target_class));
    value.emplace("targetName",
                  runtime::internal::JsonValue(
                      request.target.target_name_hint));
    value.emplace(
        "timestampUnixMilliseconds",
        runtime::internal::JsonValue(
            std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::system_clock::now().time_since_epoch())
                .count()));
    value.emplace("transactionId",
                  runtime::internal::JsonValue(request.transaction_id));
    const std::string line = runtime::internal::EncodeCanonicalJson(
                                 runtime::internal::JsonValue(std::move(value))) +
                             "\n";
    openlog("desktop-updater-helper", LOG_PID | LOG_NDELAY, LOG_USER);
    syslog(LOG_NOTICE, "%s", line.c_str());
    closelog();

    LinuxTransactionRegistry registry(broker_mode);
    const auto path = registry.directory() / "events.jsonl";
    const int fd = open(path.c_str(),
                        O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                        0600);
    if (fd < 0) return;
    struct stat status {};
    if (fstat(fd, &status) == 0 && S_ISREG(status.st_mode) &&
        status.st_uid == geteuid() &&
        (status.st_mode & (S_IWGRP | S_IWOTH)) == 0 &&
        flock(fd, LOCK_EX) == 0) {
      WriteAll(fd, line);
      (void)fdatasync(fd);
      (void)flock(fd, LOCK_UN);
    }
    close(fd);
  } catch (...) {
  }
}

}  // namespace desktop_updater::helper
