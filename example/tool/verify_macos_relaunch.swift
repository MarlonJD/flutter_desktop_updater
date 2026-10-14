import AppKit
import Foundation

// Observe LaunchServices after the replacement has emitted its Dart marker.
// A regular activation policy represents one application in the Dock.
guard CommandLine.arguments.count == 6,
      let outgoingPID = Int32(CommandLine.arguments[3]) else {
    fatalError("Expected bundle ID, bundle path, outgoing PID, version, and build")
}
let packageID = CommandLine.arguments[1]
let expectedURL = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
let expectedVersion = CommandLine.arguments[4]
let expectedBuild = CommandLine.arguments[5]
let applications = NSRunningApplication.runningApplications(withBundleIdentifier: packageID)
guard applications.count == 1, let application = applications.first,
      application.processIdentifier != outgoingPID,
      application.isFinishedLaunching,
      !application.isTerminated,
      application.activationPolicy == .regular,
      application.bundleURL?.standardizedFileURL == expectedURL,
      let bundle = Bundle(url: expectedURL),
      bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == expectedVersion,
      bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String == expectedBuild else {
    fputs("Expected one fully launched replacement app at the requested version/build; found PIDs \(applications.map(\.processIdentifier))\n", stderr)
    exit(1)
}
let evidence: [String: Any] = [
    "event": "verified-macos-relaunch",
    "outgoingPID": outgoingPID,
    "replacementPID": application.processIdentifier,
    "bundlePath": expectedURL.path,
    "version": expectedVersion,
    "build": expectedBuild,
    "regularApplicationCount": applications.count,
    "finishedLaunching": application.isFinishedLaunching,
]
let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
