import Darwin
import Foundation

enum MacCallerExitMonitorError: Error, Equatable {
    case invalidProcessIdentifier
    case registrationFailed
    case timedOut
    case waitFailed
}

final class SystemMacCallerExitMonitorFactory: MacCallerExitMonitorCreating {
    func makeMonitor(
        processIdentifier: Int64,
        processStartIdentity: String
    ) throws -> any MacCallerExitMonitoring {
        guard processIdentifier > 0,
              processIdentifier <= Int64(Int32.max) else {
            throw MacCallerExitMonitorError.invalidProcessIdentifier
        }

        let pid = pid_t(processIdentifier)
        guard macCallerProcessStartIdentity(pid) == processStartIdentity else {
            throw MacCallerExitMonitorError.registrationFailed
        }

        let descriptor = Darwin.kqueue()
        guard descriptor >= 0 else {
            throw MacCallerExitMonitorError.registrationFailed
        }
        do {
            return try SystemMacCallerExitMonitor(
                descriptor: descriptor,
                processIdentifier: pid,
                processStartIdentity: processStartIdentity
            )
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }
}

private final class SystemMacCallerExitMonitor: MacCallerExitMonitoring {
    private static let processIdentityPollMilliseconds: Int64 = 100

    private let descriptor: Int32
    private let processIdentifier: pid_t
    private let processStartIdentity: String

    init(
        descriptor: Int32,
        processIdentifier: pid_t,
        processStartIdentity: String
    ) throws {
        self.descriptor = descriptor
        self.processIdentifier = processIdentifier
        self.processStartIdentity = processStartIdentity
        var registration = kevent64_s()
        registration.ident = UInt64(processIdentifier)
        registration.filter = Int16(EVFILT_PROC)
        registration.flags = UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT)
        registration.fflags = UInt32(NOTE_EXIT)
        guard Darwin.kevent64(
            descriptor,
            &registration,
            1,
            nil,
            0,
            0,
            nil
        ) == 0 else {
            throw MacCallerExitMonitorError.registrationFailed
        }
    }

    deinit {
        Darwin.close(descriptor)
    }

    func waitForExit(expiresAtUnixMilliseconds: Int64) throws {
        while true {
            let remaining = expiresAtUnixMilliseconds - unixMilliseconds()
            guard remaining > 0 else {
                throw MacCallerExitMonitorError.timedOut
            }
            let waitMilliseconds = min(
                remaining,
                Self.processIdentityPollMilliseconds
            )
            var timeout = timespec(
                tv_sec: Int(waitMilliseconds / 1_000),
                tv_nsec: Int(
                    (waitMilliseconds % 1_000) * 1_000_000
                )
            )
            var event = kevent64_s()
            let result = Darwin.kevent64(
                descriptor,
                nil,
                0,
                &event,
                1,
                0,
                &timeout
            )
            if result == 1 {
                guard event.filter == Int16(EVFILT_PROC),
                      event.fflags & UInt32(NOTE_EXIT) != 0,
                      event.flags & UInt16(EV_ERROR) == 0 else {
                    throw MacCallerExitMonitorError.waitFailed
                }
                return
            }
            if result == 0 {
                if callerProcessExited() {
                    return
                }
                continue
            }
            if errno != EINTR {
                throw MacCallerExitMonitorError.waitFailed
            }
        }
    }

    private func unixMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
    }

    private func callerProcessExited() -> Bool {
        if let current = macCallerProcessStartIdentity(processIdentifier) {
            return current != processStartIdentity
        }
        errno = 0
        return Darwin.kill(processIdentifier, 0) == -1 && errno == ESRCH
    }
}

private func macCallerProcessStartIdentity(_ processIdentifier: pid_t)
    -> String?
{
    var info = proc_bsdinfo()
    let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(
        processIdentifier,
        PROC_PIDTBSDINFO,
        0,
        &info,
        expected
    ) == expected else {
        return nil
    }
    return "macos:\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
}
