/// Class to represent the progress of the update.
class UpdateProgress {
  UpdateProgress({
    required this.totalBytes,
    required this.receivedBytes,
    required this.currentFile,
    required this.totalFiles,
    required this.completedFiles,
    this.stagingDirectory,
  });
  final double totalBytes;
  final double receivedBytes;
  final String currentFile;
  final int totalFiles;
  final int completedFiles;
  final String? stagingDirectory;

  double get fraction {
    if (totalBytes <= 0) {
      return completedFiles >= totalFiles ? 1 : 0;
    }

    return (receivedBytes / totalBytes).clamp(0, 1).toDouble();
  }
}
