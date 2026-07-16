import Darwin
import DesktopUpdaterKit
import Foundation

private let environment = ProcessInfo.processInfo.environment

private func environmentURL(_ name: String) -> URL? {
    guard let value = environment[name], !value.isEmpty else { return nil }
    return URL(fileURLWithPath: value)
}

private func write(_ value: String, to url: URL?) throws {
    guard let url else { throw FixtureError.missingEnvironment }
    try Data(value.utf8).write(to: url, options: .atomic)
}

private enum FixtureError: Error {
    case missingEnvironment
    case pipeFailed
    case sleeperFailed
}

private func spawnConcurrentSleeper() throws -> pid_t {
    var processIdentifier: pid_t = 0
    var arguments = [strdup("/bin/sleep"), strdup("4"), nil]
    defer {
        for argument in arguments where argument != nil {
            free(argument)
        }
    }
    let result = arguments.withUnsafeMutableBufferPointer { buffer in
        posix_spawn(
            &processIdentifier,
            "/bin/sleep",
            nil,
            nil,
            buffer.baseAddress,
            environ
        )
    }
    guard result == 0, processIdentifier > 0 else {
        throw FixtureError.sleeperFailed
    }
    return processIdentifier
}

guard MacApplicationRestarter.awaitRestartParentExitIfRequested() else {
    _exit(5)
}

if environment["DESKTOP_UPDATER_TEST_CLOSE_STANDARD_FDS"] == "1" {
    close(STDIN_FILENO)
    close(STDOUT_FILENO)
    close(STDERR_FILENO)
}

let readyProof = environmentURL(
    "DESKTOP_UPDATER_TEST_RESTART_READY_PROOF"
)
let exitProof = environmentURL("DESKTOP_UPDATER_TEST_RESTART_EXIT_PROOF")
let restartProof = environmentURL("DESKTOP_UPDATER_TEST_RESTART_PROOF")
let replacementProof = environmentURL(
    "DESKTOP_UPDATER_TEST_RESTART_REPLACEMENT_PROOF"
)
let concurrentChildProof = environmentURL(
    "DESKTOP_UPDATER_TEST_CONCURRENT_CHILD_PID_PROOF"
)

do {
    if CommandLine.arguments.count == 1 {
        let descriptorValue = environment[
            "DESKTOP_UPDATER_TEST_UNRELATED_FD"
        ]
        let descriptor = descriptorValue.flatMap(Int32.init) ?? -1
        errno = 0
        let descriptorResult = fcntl(descriptor, F_GETFD)
        let unrelatedDescriptorClosed =
            descriptorResult == -1 && errno == EBADF
        let executable = Bundle.main.executableURL?
            .resolvingSymlinksInPath().path ?? ""
        let oldProcessExited = exitProof.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        try write(
            "executable=\(executable)\n"
                + "oldProcessExited=\(oldProcessExited)\n"
                + "unrelatedDescriptorClosed=\(unrelatedDescriptorClosed)\n",
            to: restartProof
        )
        exit(0)
    }

    let restartArguments = [
        [CommandLine.arguments[0], "--restart"],
        [CommandLine.arguments[0], "--restart-with-concurrent-child"],
    ]
    guard restartArguments.contains(CommandLine.arguments) else {
        guard CommandLine.arguments == [
            CommandLine.arguments[0],
            "--replace-before-restart",
        ],
            let impostor = environmentURL(
                "DESKTOP_UPDATER_TEST_RESTART_IMPOSTOR"
            ) else {
            exit(2)
        }
        let replacement = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("RestartFixture.next")
        try FileManager.default.copyItem(at: impostor, to: replacement)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: replacement.path
        )
        guard rename(replacement.path, CommandLine.arguments[0]) == 0 else {
            exit(6)
        }
        do {
            try MacApplicationRestarter().scheduleCurrentApplicationRestart()
            try write("identity-accepted\n", to: replacementProof)
            exit(7)
        } catch MacApplicationRestartError.executableIdentityMismatch {
            try write("identity-rejected\n", to: replacementProof)
            exit(0)
        } catch {
            try write("other-error\n", to: replacementProof)
            exit(8)
        }
    }
    var unrelatedPipe = [Int32](repeating: -1, count: 2)
    guard pipe(&unrelatedPipe) == 0 else { throw FixtureError.pipeFailed }
    defer {
        close(unrelatedPipe[0])
        close(unrelatedPipe[1])
    }
    setenv(
        "DESKTOP_UPDATER_TEST_UNRELATED_FD",
        String(unrelatedPipe[0]),
        1
    )
    try MacApplicationRestarter().scheduleCurrentApplicationRestart()
    if CommandLine.arguments.last == "--restart-with-concurrent-child" {
        let sleeper = try spawnConcurrentSleeper()
        try write("\(sleeper)\n", to: concurrentChildProof)
    }
    try write("replacement-ready\n", to: readyProof)
    Thread.sleep(forTimeInterval: 0.5)
    try write("old-process-exiting\n", to: exitProof)
    exit(0)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
