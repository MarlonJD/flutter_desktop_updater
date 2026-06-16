import "package:desktop_updater/src/release_cli/release_command.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("release CLI keeps help, subcommands, and usage exit code", () async {
    final output = StringBuffer();
    final helpCode = await runReleaseCommand(["--help"], output: output);

    expect(helpCode, 0);
    expect(output.toString(), contains("release doctor"));
    expect(output.toString(), contains("release publish"));
    expect(output.toString(), contains("release sign"));
    expect(output.toString(), contains("release validate"));

    final unknownOutput = StringBuffer();
    final unknownCode = await runReleaseCommand(
      ["unknown"],
      output: unknownOutput,
    );

    expect(unknownCode, 0);
    expect(unknownOutput.toString(), contains("release doctor"));

    final badOptionOutput = StringBuffer();
    final badOptionCode = await runReleaseCommand(
      ["publish", "--definitely-not-a-real-option"],
      output: badOptionOutput,
    );

    expect(badOptionCode, 64);
    expect(
        badOptionOutput.toString(), contains("definitely-not-a-real-option"));
  });
}
