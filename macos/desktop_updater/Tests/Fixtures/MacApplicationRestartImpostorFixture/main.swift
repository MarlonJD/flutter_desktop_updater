import Darwin
import DesktopUpdaterKit
import Foundation

guard MacApplicationRestarter.awaitRestartParentExitIfRequested() else {
    _exit(5)
}

guard let proof = ProcessInfo.processInfo.environment[
    "DESKTOP_UPDATER_TEST_RESTART_IMPOSTOR_PROOF"
],
    !proof.isEmpty else {
    _exit(6)
}

do {
    try Data("impostor-ran\n".utf8).write(
        to: URL(fileURLWithPath: proof),
        options: .atomic
    )
    exit(0)
} catch {
    exit(7)
}
