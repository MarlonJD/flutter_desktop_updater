#ifndef DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_UNINSTALL_RECORD_PROOF_H_
#define DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_UNINSTALL_RECORD_PROOF_H_

#include <windows.h>

#include <filesystem>
#include <optional>
#include <string>

namespace desktop_updater::helper {

// Returns a deterministic canonical proof for an installer-protected
// uninstall record bound to the exact target and package, when one exists and
// the named-pipe caller cannot mutate the record.
std::optional<std::string> FindCanonicalWindowsUninstallRecordProof(
    const std::filesystem::path& canonical_target,
    const std::string& package_id,
    HANDLE caller_process);

// Autonomous LocalSystem recovery has no named-pipe caller. In that mode the
// uninstall record itself must have a protected DACL and a trusted owner, with
// mutation authority limited to SYSTEM, Administrators, or TrustedInstaller.
std::optional<std::string>
FindCanonicalWindowsUninstallRecordProofForTrustedHost(
    const std::filesystem::path& canonical_target,
    const std::string& package_id);

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_WINDOWS_HELPER_WINDOWS_UNINSTALL_RECORD_PROOF_H_
