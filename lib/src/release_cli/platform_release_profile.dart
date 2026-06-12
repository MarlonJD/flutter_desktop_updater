import "package:path/path.dart" as path;

class PlatformReleaseProfile {
  const PlatformReleaseProfile._({
    required this.platform,
    required this.flutterBuildArgs,
    required this.installStrategy,
    required this.defaultInputPathBuilder,
  });

  final String platform;
  final List<String> flutterBuildArgs;
  final String installStrategy;
  final String Function(String appName) defaultInputPathBuilder;

  String defaultInputPath(String appName) => defaultInputPathBuilder(appName);

  static PlatformReleaseProfile forPlatform(String platform) {
    switch (platform) {
      case "macos":
        return PlatformReleaseProfile._(
          platform: platform,
          flutterBuildArgs: const ["build", "macos", "--release"],
          installStrategy: "wholeBundleReplace",
          defaultInputPathBuilder: (appName) {
            final appBundleName =
                appName.endsWith(".app") ? appName : "$appName.app";
            return path.join(
              "build",
              "macos",
              "Build",
              "Products",
              "Release",
              appBundleName,
            );
          },
        );
      case "windows":
        return PlatformReleaseProfile._(
          platform: platform,
          flutterBuildArgs: const ["build", "windows", "--release"],
          installStrategy: "wholeDirectoryReplace",
          defaultInputPathBuilder: (_) => path.join(
            "build",
            "windows",
            "x64",
            "runner",
            "Release",
          ),
        );
      case "linux":
        return PlatformReleaseProfile._(
          platform: platform,
          flutterBuildArgs: const ["build", "linux", "--release"],
          installStrategy: "wholeDirectoryReplace",
          defaultInputPathBuilder: (_) => path.join(
            "build",
            "linux",
            "x64",
            "release",
            "bundle",
          ),
        );
    }

    throw FormatException("Unsupported platform: $platform.");
  }
}
