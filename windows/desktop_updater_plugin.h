#ifndef FLUTTER_PLUGIN_DESKTOP_UPDATER_PLUGIN_H_
#define FLUTTER_PLUGIN_DESKTOP_UPDATER_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace desktop_updater {

class DesktopUpdaterPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  DesktopUpdaterPlugin();

  virtual ~DesktopUpdaterPlugin();

  // Disallow copy and assign.
  DesktopUpdaterPlugin(const DesktopUpdaterPlugin&) = delete;
  DesktopUpdaterPlugin& operator=(const DesktopUpdaterPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

}  // namespace desktop_updater

#endif  // FLUTTER_PLUGIN_DESKTOP_UPDATER_PLUGIN_H_
