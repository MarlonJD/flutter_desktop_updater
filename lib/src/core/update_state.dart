import "package:desktop_updater/src/core/release_descriptor.dart";

sealed class UpdateState {
  const UpdateState();
}

final class UpdateIdle extends UpdateState {
  const UpdateIdle();
}

final class UpdateChecking extends UpdateState {
  const UpdateChecking();
}

final class UpdateAvailable extends UpdateState {
  const UpdateAvailable({required this.descriptor, required this.mandatory});

  final ReleaseDescriptor descriptor;
  final bool mandatory;
}

final class UpdateDownloading extends UpdateState {
  const UpdateDownloading({
    required this.receivedBytes,
    required this.totalBytes,
  });

  final int receivedBytes;
  final int totalBytes;
}

final class UpdateReadyToInstall extends UpdateState {
  const UpdateReadyToInstall({required this.stagingPath});

  final String stagingPath;
}

final class UpdateInstalling extends UpdateState {
  const UpdateInstalling();
}

final class UpdateFailed extends UpdateState {
  const UpdateFailed(this.error);

  final Object error;
}
