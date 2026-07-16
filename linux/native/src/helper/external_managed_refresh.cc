#include "install_strategy.h"

#include <regex>
#include <utility>

namespace desktop_updater::helper {
namespace {

const std::regex kManagedId("^[A-Za-z0-9][A-Za-z0-9._-]{1,255}$");
const std::regex kTrack("^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$");
const std::regex kAuthority("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$");

void ValidateBase(const LinuxExternalRefreshRequest& request) {
  if ((request.provider != "flatpak" && request.provider != "snap") ||
      !std::regex_match(request.package_id, kManagedId) ||
      !std::regex_match(request.branch_or_channel, kTrack) ||
      !std::regex_match(request.remote_identity, kAuthority) ||
      request.expected_revision.empty() || !request.caller_arguments.empty() ||
      request.dangerous_sideload || request.direct_revision_mutation) {
    throw LinuxInstallStrategyError(
        "managed refresh authority, caller_arguments, or revision target rejected");
  }
}

}  // namespace

LinuxProviderCommand BuildLinuxExternalRefreshCommand(
    const LinuxExternalRefreshRequest& request) {
  ValidateBase(request);
  if (request.provider == "flatpak") {
    if (!request.signed_remote && request.remote_identity != "flathub") {
      throw LinuxInstallStrategyError("Flatpak remote is not signed or Flathub");
    }
    return {"/usr/bin/flatpak",
            {"update", "--noninteractive", "--or-update",
             request.remote_identity + ":" + request.package_id + "//" +
                 request.branch_or_channel},
            request.provider,
            request.package_id,
            request.expected_revision,
            "",
            request.branch_or_channel,
            request.remote_identity};
  }
  if (!request.public_or_brand_store) {
    throw LinuxInstallStrategyError(
        "Snap refresh requires public or Brand Store authority");
  }
  return {"/usr/bin/snap",
          {"refresh", request.package_id,
           "--channel=" + request.branch_or_channel},
          request.provider,
          request.package_id,
          request.expected_revision,
          "",
          request.branch_or_channel,
          request.remote_identity};
}

LinuxProviderTransaction StartLinuxExternalManagedRefresh(
    const LinuxExternalRefreshRequest& request,
    LinuxProviderRunner& runner) {
  const auto command = BuildLinuxExternalRefreshCommand(request);
  std::string identity = runner.StartFixed(command);
  if (identity.empty()) {
    throw LinuxInstallStrategyError("managed provider transaction ID missing");
  }
  LinuxProviderTransaction transaction{
      request.provider, request.package_id, std::move(identity),
      LinuxProviderTransactionState::kManagerStarted};
  transaction.provider_scope = request.branch_or_channel;
  transaction.provider_authority = request.remote_identity;
  return transaction;
}

LinuxProviderTransaction RecoverLinuxExternalManagedRefresh(
    LinuxProviderTransaction transaction,
    const std::string& expected_revision,
    LinuxProviderRunner& runner) {
  if (transaction.transaction_identity.empty()) {
    transaction.state = LinuxProviderTransactionState::kManualActionRequired;
    return transaction;
  }
  const LinuxProviderStateObservation observation =
      runner.QueryInstalledState(transaction, expected_revision);
  transaction.state = observation.state;
  if (!observation.transaction_identity.empty()) {
    transaction.transaction_identity = observation.transaction_identity;
  }
  return transaction;
}

LinuxProviderTransaction StartDurableLinuxExternalManagedRefresh(
    const std::string& transaction_id,
    const LinuxExternalRefreshRequest& request,
    LinuxProviderRunner& runner,
    LinuxProviderJournal& journal) {
  const LinuxProviderCommand command =
      BuildLinuxExternalRefreshCommand(request);
  LinuxProviderJournalRecord record;
  record.transaction_id = transaction_id;
  record.transaction = {
      request.provider, request.package_id,
      "pending-" + Sha256LinuxProviderCommand(command),
      LinuxProviderTransactionState::kPrepared};
  record.transaction.provider_scope = request.branch_or_channel;
  record.transaction.provider_authority = request.remote_identity;
  record.expected_version_or_revision = request.expected_revision;
  record.command_sha256 = Sha256LinuxProviderCommand(command);
  journal.Persist(record);
  try {
    record.transaction.transaction_identity = runner.StartFixed(command);
    if (record.transaction.transaction_identity.empty()) {
      throw LinuxInstallStrategyError("managed provider transaction ID missing");
    }
    record.transaction.state = LinuxProviderTransactionState::kManagerStarted;
    journal.Persist(record);
    return record.transaction;
  } catch (...) {
    record.transaction.state =
        LinuxProviderTransactionState::kVerificationPending;
    try {
      journal.Persist(record);
    } catch (...) {
    }
    throw;
  }
}

LinuxProviderTransaction RecoverDurableLinuxExternalManagedRefresh(
    const std::string& transaction_id,
    LinuxProviderRunner& runner,
    LinuxProviderJournal& journal) {
  const auto loaded = journal.Load(transaction_id);
  if (!loaded.has_value()) {
    throw LinuxProviderJournalError("provider transaction is not journaled");
  }
  LinuxProviderJournalRecord record = *loaded;
  if (record.transaction.provider != "flatpak" &&
      record.transaction.provider != "snap") {
    throw LinuxProviderJournalError("provider journal strategy changed");
  }
  if (record.transaction.state == LinuxProviderTransactionState::kCompleted ||
      record.transaction.state ==
          LinuxProviderTransactionState::kManualActionRequired) {
    return record.transaction;
  }
  if (record.transaction.state == LinuxProviderTransactionState::kPrepared) {
    record.transaction.state =
        LinuxProviderTransactionState::kVerificationPending;
    journal.Persist(record);
  }
  record.transaction = RecoverLinuxExternalManagedRefresh(
      record.transaction, record.expected_version_or_revision, runner);
  journal.Persist(record);
  return record.transaction;
}

}  // namespace desktop_updater::helper
