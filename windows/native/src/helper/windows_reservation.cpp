#include "windows_reservation.h"

#include <bcrypt.h>

#include <algorithm>
#include <array>
#include <cwctype>
#include <regex>
#include <utility>

namespace desktop_updater::helper {
namespace {

const std::regex kTransactionId(
    "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$");

bool IsNonce(const std::string& nonce) {
  return nonce.size() == 43 &&
         std::all_of(nonce.begin(), nonce.end(), [](unsigned char character) {
           return (character >= 'A' && character <= 'Z') ||
                  (character >= 'a' && character <= 'z') ||
                  (character >= '0' && character <= '9') || character == '-' ||
                  character == '_';
         });
}

void ValidateLeaf(const std::wstring& leaf) {
  if (leaf.empty() || leaf == L"." || leaf == L".." ||
      leaf.find_first_of(L"\\/:*?\"<>|") != std::wstring::npos ||
      leaf.back() == L'.' || leaf.back() == L' ') {
    throw WindowsReservationError("target leaf must be one fixed component");
  }
}

std::wstring NormalizePath(std::wstring value) {
  std::replace(value.begin(), value.end(), L'/', L'\\');
  std::transform(value.begin(), value.end(), value.begin(),
                 [](wchar_t character) { return std::towlower(character); });
  return value;
}

std::string GenerateReadyToken() {
  std::array<unsigned char, 32> bytes{};
  if (BCryptGenRandom(nullptr, bytes.data(),
                      static_cast<ULONG>(bytes.size()),
                      BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0) {
    throw WindowsReservationError("ready token generation failed");
  }
  static constexpr char alphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  std::string output;
  output.reserve(43);
  std::uint32_t buffer = 0;
  int bits = 0;
  for (unsigned char byte : bytes) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 6) {
      bits -= 6;
      output.push_back(alphabet[(buffer >> bits) & 0x3f]);
    }
  }
  if (bits > 0) output.push_back(alphabet[(buffer << (6 - bits)) & 0x3f]);
  return output;
}

std::unique_ptr<WindowsReservation::OwnedHandle> OpenDirectory(
    const std::filesystem::path& path,
    DWORD access);

}  // namespace

class WindowsReservation::OwnedHandle {
 public:
  explicit OwnedHandle(HANDLE handle = INVALID_HANDLE_VALUE)
      : handle_(handle) {}
  ~OwnedHandle() { Reset(); }
  OwnedHandle(const OwnedHandle&) = delete;
  OwnedHandle& operator=(const OwnedHandle&) = delete;
  HANDLE get() const { return handle_; }
  bool valid() const {
    return handle_ != nullptr && handle_ != INVALID_HANDLE_VALUE;
  }
  void Reset() {
    if (valid()) CloseHandle(handle_);
    handle_ = INVALID_HANDLE_VALUE;
  }
  void DeleteExactFileOnClose() {
    if (!valid()) return;
    FILE_DISPOSITION_INFO disposition{};
    disposition.DeleteFile = TRUE;
    SetFileInformationByHandle(handle_, FileDispositionInfo, &disposition,
                               sizeof(disposition));
  }

 private:
  HANDLE handle_;
};

namespace {

std::unique_ptr<WindowsReservation::OwnedHandle> OpenDirectory(
    const std::filesystem::path& path,
    DWORD access) {
  HANDLE handle = CreateFileW(
      path.c_str(), access,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (handle == INVALID_HANDLE_VALUE) {
    throw WindowsReservationError("directory authority open failed");
  }
  FILE_ATTRIBUTE_TAG_INFO tag{};
  if (!GetFileInformationByHandleEx(handle, FileAttributeTagInfo, &tag,
                                    sizeof(tag)) ||
      (tag.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
      (tag.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0) {
    CloseHandle(handle);
    throw WindowsReservationError("directory authority is a reparse or non-directory");
  }
  return std::make_unique<WindowsReservation::OwnedHandle>(handle);
}

std::unique_ptr<WindowsReservation::OwnedHandle> CreateOwnedFile(
    const std::filesystem::path& path) {
  HANDLE handle = CreateFileW(
      path.c_str(), GENERIC_READ | GENERIC_WRITE | DELETE,
      FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr, CREATE_NEW,
      FILE_ATTRIBUTE_HIDDEN | FILE_FLAG_WRITE_THROUGH |
          FILE_FLAG_OPEN_REPARSE_POINT,
      nullptr);
  if (handle == INVALID_HANDLE_VALUE) {
    throw WindowsReservationError("exclusive reservation file creation failed");
  }
  return std::make_unique<WindowsReservation::OwnedHandle>(handle);
}

void WriteDurableJournal(HANDLE journal,
                         const WindowsReservationRequest& request) {
  const std::string body =
      "{\"schemaVersion\":1,\"state\":\"prepared\",\"transactionId\":\"" +
      request.transaction_id + "\"}\n";
  DWORD written = 0;
  if (!WriteFile(journal, body.data(), static_cast<DWORD>(body.size()),
                 &written, nullptr) ||
      written != body.size() || !FlushFileBuffers(journal)) {
    throw WindowsReservationError("initial reservation journal is not durable");
  }
}

}  // namespace

WindowsReservation::WindowsReservation(
    std::string transaction_id,
    std::string nonce,
    std::wstring target_key,
    std::string ready_token,
    std::int64_t expires_epoch_millis,
    std::filesystem::path lock_path,
    std::filesystem::path journal_path,
    std::unique_ptr<OwnedHandle> caller_process,
    std::unique_ptr<OwnedHandle> target_parent,
    std::unique_ptr<OwnedHandle> stage,
    std::unique_ptr<OwnedHandle> target_lock,
    std::unique_ptr<OwnedHandle> journal)
    : transaction_id_(std::move(transaction_id)),
      nonce_(std::move(nonce)),
      target_key_(std::move(target_key)),
      ready_token_(std::move(ready_token)),
      expires_epoch_millis_(expires_epoch_millis),
      lock_path_(std::move(lock_path)),
      journal_path_(std::move(journal_path)),
      caller_process_(std::move(caller_process)),
      target_parent_(std::move(target_parent)),
      stage_(std::move(stage)),
      target_lock_(std::move(target_lock)),
      journal_(std::move(journal)) {}

WindowsReservation::~WindowsReservation() {
  if (state_ == WindowsReservationState::kPrepared) DeletePreparedState();
}

bool WindowsReservation::has_caller_process_handle() const {
  return caller_process_ && caller_process_->valid();
}
bool WindowsReservation::has_target_parent_handle() const {
  return target_parent_ && target_parent_->valid();
}
bool WindowsReservation::has_stage_handle() const {
  return stage_ && stage_->valid();
}
bool WindowsReservation::has_target_lock_handle() const {
  return target_lock_ && target_lock_->valid();
}
bool WindowsReservation::has_journal_handle() const {
  return journal_ && journal_->valid();
}

void WindowsReservation::DeletePreparedState() {
  // Delete by retained handles, not by attacker-replaceable path strings.
  if (journal_) journal_->DeleteExactFileOnClose();
  if (target_lock_) target_lock_->DeleteExactFileOnClose();
  journal_.reset();
  target_lock_.reset();
  stage_.reset();
  target_parent_.reset();
  caller_process_.reset();
}

void WindowsReservation::Finish(WindowsReservationState state) {
  if (state_ != WindowsReservationState::kPrepared) {
    throw WindowsReservationError("reservation is terminal");
  }
  state_ = state;
  DeletePreparedState();
}

WindowsReservationStore::~WindowsReservationStore() {
  std::lock_guard<std::mutex> lock(mutex_);
  for (auto& entry : reservations_) {
    if (entry.second->state_ == WindowsReservationState::kPrepared) {
      entry.second->Finish(WindowsReservationState::kCancelled);
    }
  }
}

std::shared_ptr<WindowsReservation> WindowsReservationStore::Prepare(
    const WindowsReservationRequest& request) {
  if (!std::regex_match(request.transaction_id, kTransactionId)) {
    throw WindowsReservationError("transaction ID must be a lowercase UUIDv4");
  }
  if (!IsNonce(request.nonce)) {
    throw WindowsReservationError("nonce must be fresh 32-byte base64url");
  }
  ValidateLeaf(request.target_leaf);
  ValidateLeaf(request.staged_path.filename().wstring());
  if (NormalizePath(request.staged_path.parent_path().lexically_normal().wstring()) !=
      NormalizePath(request.target_parent.lexically_normal().wstring())) {
    throw WindowsReservationError("stage must be a fixed target-parent sibling");
  }
  if (request.expires_epoch_millis <= 0) {
    throw WindowsReservationError("reservation expiry is invalid");
  }

  auto parent = OpenDirectory(request.target_parent,
                              FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES);
  auto stage = OpenDirectory(request.staged_path,
                             FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES);
  HANDLE raw_caller = OpenProcess(
      PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE,
      request.caller_process_id);
  if (raw_caller == nullptr) {
    throw WindowsReservationError("caller process authority open failed");
  }
  auto caller = std::make_unique<OwnedHandle>(raw_caller);

  const std::wstring target_key = NormalizePath(
      (request.target_parent / request.target_leaf).lexically_normal().wstring());
  const std::filesystem::path lock_path =
      request.target_parent /
      (L".desktop-updater-" + request.target_leaf + L".lock");
  const std::filesystem::path journal_path =
      request.target_parent /
      (L".desktop-updater-" +
       std::wstring(request.transaction_id.begin(), request.transaction_id.end()) +
       L".journal");

  std::lock_guard<std::mutex> lock(mutex_);
  if (reservations_.find(request.transaction_id) != reservations_.end()) {
    throw WindowsReservationError("duplicate transaction ID");
  }
  if (active_targets_.find(target_key) != active_targets_.end()) {
    throw WindowsReservationError("target is already reserved");
  }
  if (consumed_nonces_.find(request.nonce) != consumed_nonces_.end()) {
    throw WindowsReservationError("nonce reuse rejected");
  }

  auto targetLock = CreateOwnedFile(lock_path);
  std::unique_ptr<OwnedHandle> journal;
  std::string ready_token;
  try {
    journal = CreateOwnedFile(journal_path);
    WriteDurableJournal(journal->get(), request);
    const bool journalDurableBeforeReadyToken = true;
    ready_token = GenerateReadyToken();
    if (!journalDurableBeforeReadyToken) {
      throw WindowsReservationError("journal durability ordering failed");
    }
  } catch (...) {
    if (journal) journal->DeleteExactFileOnClose();
    targetLock->DeleteExactFileOnClose();
    throw;
  }

  auto reservation = std::shared_ptr<WindowsReservation>(
      new WindowsReservation(
          request.transaction_id, request.nonce, target_key,
          std::move(ready_token), request.expires_epoch_millis, lock_path,
          journal_path, std::move(caller), std::move(parent), std::move(stage),
          std::move(targetLock), std::move(journal)));
  reservations_.emplace(request.transaction_id, reservation);
  active_targets_.insert(target_key);
  consumed_nonces_.insert(request.nonce);
  return reservation;
}

std::shared_ptr<WindowsReservation> WindowsReservationStore::FindPrepared(
    const std::string& transaction_id,
    const std::string& ready_token) {
  const auto found = reservations_.find(transaction_id);
  if (found == reservations_.end() ||
      found->second->state_ != WindowsReservationState::kPrepared ||
      found->second->ready_token_ != ready_token) {
    throw WindowsReservationError("unknown or terminal reservation");
  }
  return found->second;
}

void WindowsReservationStore::ReleaseTarget(
    const std::shared_ptr<WindowsReservation>& reservation) {
  active_targets_.erase(reservation->target_key_);
}

void WindowsReservationStore::Commit(const std::string& transaction_id,
                                     const std::string& ready_token,
                                     std::int64_t now_epoch_millis) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto reservation = FindPrepared(transaction_id, ready_token);
  if (now_epoch_millis > reservation->expires_epoch_millis_) {
    reservation->Finish(WindowsReservationState::kExpired);
    ReleaseTarget(reservation);
    throw WindowsReservationError("reservation expired before mutation");
  }
  reservation->Finish(WindowsReservationState::kCompleted);
  ReleaseTarget(reservation);
}

void WindowsReservationStore::Cancel(const std::string& transaction_id,
                                     const std::string& ready_token) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto reservation = FindPrepared(transaction_id, ready_token);
  reservation->Finish(WindowsReservationState::kCancelled);
  ReleaseTarget(reservation);
}

void WindowsReservationStore::CallerExited(
    const std::string& transaction_id) {
  std::lock_guard<std::mutex> lock(mutex_);
  const auto found = reservations_.find(transaction_id);
  if (found == reservations_.end() ||
      found->second->state_ != WindowsReservationState::kPrepared) {
    throw WindowsReservationError("unknown or terminal reservation");
  }
  found->second->Finish(WindowsReservationState::kCancelled);
  ReleaseTarget(found->second);
}

}  // namespace desktop_updater::helper
