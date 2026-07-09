import "dart:io";

typedef InnoProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

class InnoCompiler {
  const InnoCompiler({
    this.runProcess = Process.run,
  });

  final InnoProcessRunner runProcess;

  Future<void> compile({
    required File scriptFile,
    required String? isccPath,
  }) async {
    final executable =
        isccPath == null || isccPath.trim().isEmpty ? "iscc" : isccPath;
    final result = await runProcess(executable, [scriptFile.path]);
    if (result.exitCode != 0) {
      throw ProcessException(
        executable,
        [scriptFile.path],
        "${result.stdout}\n${result.stderr}",
        result.exitCode,
      );
    }
  }
}
