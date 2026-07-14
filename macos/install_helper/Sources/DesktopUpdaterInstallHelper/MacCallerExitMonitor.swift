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
        processIdentifier: Int64
    ) throws -> any MacCallerExitMonitoring {
        guard processIdentifier > 0,
              processIdentifier <= Int64(Int32.max) else {
            throw MacCallerExitMonitorError.invalidProcessIdentifier
        }

        let descriptor = Darwin.kqueue()
        guard descriptor >= 0 else {
            throw MacCallerExitMonitorError.registrationFailed
        }
        do {
            return try SystemMacCallerExitMonitor(
                descriptor: descriptor,
                processIdentifier: pid_t(processIdentifier)
            )
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }
}

private final class SystemMacCallerExitMonitor: MacCallerExitMonitoring {
    private let descriptor: Int32

    init(descriptor: Int32, processIdentifier: pid_t) throws {
        self.descriptor = descriptor
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
            var timeout = timespec(
                tv_sec: Int(remaining / 1_000),
                tv_nsec: Int((remaining % 1_000) * 1_000_000)
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
                throw MacCallerExitMonitorError.timedOut
            }
            if errno != EINTR {
                throw MacCallerExitMonitorError.waitFailed
            }
        }
    }

    private func unixMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
    }
}
