#ifndef DESKTOP_UPDATER_RUNTIME_NATIVE_INSTALL_SERVICE_RUNTIME_H_
#define DESKTOP_UPDATER_RUNTIME_NATIVE_INSTALL_SERVICE_RUNTIME_H_

#include <cstdint>
#include <memory>
#include <string>

#include "native_install_request.h"
#include "native_install_session.h"

namespace desktop_updater {
namespace runtime {
namespace internal {

class NativeInstallWireChannelV1 {
 public:
  virtual ~NativeInstallWireChannelV1() = default;
  virtual std::string ReadFrame() = 0;
  virtual std::string ReadFrameUntil(
      std::int64_t expires_at_unix_milliseconds) = 0;
  virtual void WriteFrame(const std::string& canonical_frame) = 0;
};

class NativeInstallCallerExitMonitorV1 {
 public:
  virtual ~NativeInstallCallerExitMonitorV1() = default;
  virtual void WaitForExit(
      std::int64_t expires_at_unix_milliseconds) = 0;
};

class NativeInstallCallerExitMonitorFactoryV1 {
 public:
  virtual ~NativeInstallCallerExitMonitorFactoryV1() = default;
  virtual std::unique_ptr<NativeInstallCallerExitMonitorV1> Create(
      const NativeInstallCallerV1& caller) = 0;
};

class NativeInstallOneShotServiceRuntimeV1 {
 public:
  NativeInstallOneShotServiceRuntimeV1(
      NativeInstallOneShotSessionV1& session,
      NativeInstallCallerExitMonitorFactoryV1& caller_monitor_factory);

  void Run(NativeInstallWireChannelV1& channel);

 private:
  NativeInstallOneShotSessionV1& session_;
  NativeInstallCallerExitMonitorFactoryV1& caller_monitor_factory_;
};

}  // namespace internal
}  // namespace runtime
}  // namespace desktop_updater

#endif  // DESKTOP_UPDATER_RUNTIME_NATIVE_INSTALL_SERVICE_RUNTIME_H_
