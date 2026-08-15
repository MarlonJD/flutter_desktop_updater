#include "windows_inno_restage.h"

#include <winternl.h>

#include <sddl.h>

#include <array>
#include <climits>
#include <limits>
#include <memory>
#include <regex>
#include <utility>

#include "helper_authenticode.h"
#include "windows_archive_restage.h"

namespace desktop_updater::helper {
namespace {

const std::regex kTransactionId(
    "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$");

[[noreturn]] void Fail(const std::string &detail) {
  throw WindowsInnoRestageError(detail);
}

std::int64_t FileLength(HANDLE file) {
  LARGE_INTEGER length{};
  if (!GetFileSizeEx(file, &length) || length.QuadPart < 1) {
    Fail("Inno installer length is unavailable");
  }
  return length.QuadPart;
}

UniqueWindowsHandle OpenAbsoluteDirectory(const std::filesystem::path &path) {
  UniqueWindowsHandle result(CreateFileW(
      path.c_str(),
      FILE_LIST_DIRECTORY | FILE_ADD_FILE | FILE_TRAVERSE |
          FILE_READ_ATTRIBUTES | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
      nullptr));
  if (!result.valid())
    Fail("protected Inno target parent is unavailable");
  const WindowsFileIdentity identity = ReadWindowsFileIdentity(result.get());
  if (!identity.directory ||
      (identity.attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    Fail("protected Inno target parent is not authoritative");
  }
  return result;
}

class LocalDescriptor {
public:
  LocalDescriptor() {
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            L"O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;BU)",
            SDDL_REVISION_1, &value_, nullptr) ||
        value_ == nullptr) {
      Fail("protected Inno security descriptor creation failed");
    }
  }
  ~LocalDescriptor() {
    if (value_ != nullptr)
      LocalFree(value_);
  }
  PSECURITY_DESCRIPTOR get() const { return value_; }

private:
  PSECURITY_DESCRIPTOR value_ = nullptr;
};

} // namespace

UniqueWindowsHandle
OpenProtectedWindowsInnoParentDirectory(const std::filesystem::path &path) {
  return OpenAbsoluteDirectory(path);
}

struct ProtectedWindowsInnoRestage::Impl {
  ~Impl() {
    if (!cleanup_on_destroy || !present || !installer.valid() ||
        !parent.valid()) {
      return;
    }
    try {
      DeleteHandleExact(installer.get());
      installer.reset();
      FlushWindowsDirectory(parent.get());
    } catch (...) {
    }
  }

  std::filesystem::path path;
  std::wstring leaf;
  WindowsFileIdentity identity;
  UniqueWindowsHandle parent;
  UniqueWindowsHandle installer;
  bool cleanup_on_destroy = true;
  bool present = true;
};

ProtectedWindowsInnoRestage::ProtectedWindowsInnoRestage(
    std::unique_ptr<Impl> impl)
    : impl_(std::move(impl)) {}

ProtectedWindowsInnoRestage::ProtectedWindowsInnoRestage(
    ProtectedWindowsInnoRestage &&) noexcept = default;
ProtectedWindowsInnoRestage &ProtectedWindowsInnoRestage::operator=(
    ProtectedWindowsInnoRestage &&) noexcept = default;
ProtectedWindowsInnoRestage::~ProtectedWindowsInnoRestage() = default;

const std::filesystem::path &ProtectedWindowsInnoRestage::path() const {
  return impl_->path;
}
const std::wstring &ProtectedWindowsInnoRestage::leaf() const {
  return impl_->leaf;
}
const WindowsFileIdentity &ProtectedWindowsInnoRestage::identity() const {
  return impl_->identity;
}
HANDLE ProtectedWindowsInnoRestage::parent_handle() const {
  return impl_->parent.get();
}
void ProtectedWindowsInnoRestage::PreserveForRecovery() {
  if (!impl_->present || !impl_->installer.valid() || !impl_->parent.valid()) {
    Fail("protected Inno restage cannot be preserved");
  }
  impl_->cleanup_on_destroy = false;
}
void ProtectedWindowsInnoRestage::RemoveExact() {
  if (!impl_->present)
    return;
  if (!impl_->installer.valid() || !impl_->parent.valid() ||
      ReadWindowsFileIdentity(impl_->installer.get()) != impl_->identity) {
    Fail("protected Inno restage identity changed before cleanup");
  }
  DeleteHandleExact(impl_->installer.get());
  impl_->installer.reset();
  FlushWindowsDirectory(impl_->parent.get());
  impl_->present = false;
  impl_->cleanup_on_destroy = false;
}

ProtectedWindowsInnoRestage RestageProtectedWindowsInnoInstaller(
    const std::filesystem::path &source_installer,
    const std::filesystem::path &target_parent,
    const std::string &transaction_id, const std::string &expected_sha256,
    std::int64_t expected_length, HANDLE caller_process) {
  if (!std::regex_match(transaction_id, kTransactionId) ||
      expected_sha256.size() != 64 || expected_length < 1 ||
      caller_process == nullptr || caller_process == INVALID_HANDLE_VALUE) {
    Fail("protected Inno restage request is invalid");
  }
  UniqueWindowsHandle source(CreateFileW(
      source_installer.c_str(), GENERIC_READ | FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (!source.valid()) {
    Fail("source Inno installer is unavailable");
  }
  const VerifiedWindowsExecutable source_identity =
      VerifyRetainedWindowsExecutable(source.get(), source_installer);
  if (!source_identity.signature_valid ||
      source_identity.sha256 != expected_sha256 ||
      FileLength(source.get()) != expected_length ||
      !VerifyRetainedWindowsExecutableStillMatches(source.get(),
                                                   source_identity)) {
    Fail("source Inno installer changed before protected restage");
  }

  auto result = std::make_unique<ProtectedWindowsInnoRestage::Impl>();
  result->parent = OpenProtectedWindowsInnoParentDirectory(target_parent);
  result->leaf = L".desktop-updater-inno-" +
                 std::wstring(transaction_id.begin(), transaction_id.end()) +
                 L".exe";
  result->path = target_parent / result->leaf;
  LocalDescriptor descriptor;
  result->installer = OpenRelativeNoReparse(
      result->parent.get(), result->leaf,
      GENERIC_READ | GENERIC_WRITE | DELETE | FILE_READ_ATTRIBUTES |
          READ_CONTROL | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_DELETE, FILE_CREATE,
      FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT |
          FILE_WRITE_THROUGH,
      FILE_ATTRIBUTE_HIDDEN, descriptor.get());
  VerifyWindowsArchiveRestageSecurity(
      result->installer.get(),
      WindowsArchiveRestageAuthority::kInstallerProtected, caller_process);

  LARGE_INTEGER beginning{};
  if (!SetFilePointerEx(source.get(), beginning, nullptr, FILE_BEGIN)) {
    Fail("source Inno installer seek failed");
  }
  std::array<unsigned char, 64 * 1024> buffer{};
  std::int64_t copied = 0;
  for (;;) {
    DWORD count = 0;
    if (!ReadFile(source.get(), buffer.data(),
                  static_cast<DWORD>(buffer.size()), &count, nullptr)) {
      Fail("source Inno installer read failed");
    }
    if (count == 0)
      break;
    DWORD written = 0;
    if (!WriteFile(result->installer.get(), buffer.data(), count, &written,
                   nullptr) ||
        written != count || copied > INT64_MAX - count) {
      Fail("protected Inno installer copy failed");
    }
    copied += count;
  }
  if (!FlushFileBuffers(result->installer.get()) || copied != expected_length ||
      FileLength(result->installer.get()) != expected_length) {
    Fail("protected Inno installer copy is not durable");
  }
  result->identity = ReadWindowsFileIdentity(result->installer.get());
  const VerifiedWindowsExecutable copied_identity =
      VerifyRetainedWindowsExecutable(result->installer.get(), result->path);
  if (!copied_identity.signature_valid ||
      copied_identity.sha256 != expected_sha256 ||
      copied_identity.signer_certificate_sha256 !=
          source_identity.signer_certificate_sha256 ||
      !VerifyRetainedWindowsExecutableStillMatches(result->installer.get(),
                                                   copied_identity) ||
      ReadWindowsFileIdentity(result->installer.get()) != result->identity) {
    Fail("protected Inno installer restage identity mismatch");
  }
  FlushWindowsDirectory(result->parent.get());
  return ProtectedWindowsInnoRestage(std::move(result));
}

void RemoveRecoveredProtectedWindowsInnoInstaller(
    const std::filesystem::path &installer_path,
    const std::string &expected_sha256, std::int64_t expected_length) {
  if (!installer_path.is_absolute() ||
      installer_path.lexically_normal() != installer_path ||
      installer_path.filename().empty() || expected_sha256.size() != 64 ||
      expected_length < 1) {
    Fail("recovered protected Inno cleanup request is invalid");
  }
  UniqueWindowsHandle parent =
      OpenProtectedWindowsInnoParentDirectory(installer_path.parent_path());
  const std::wstring leaf = installer_path.filename().wstring();
  if (!ExistsRelativeNoReparse(parent.get(), leaf))
    return;
  UniqueWindowsHandle installer = OpenRelativeNoReparse(
      parent.get(), leaf,
      GENERIC_READ | DELETE | FILE_READ_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_DELETE, FILE_OPEN,
      FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
  VerifyWindowsArchiveRestageSecurity(
      installer.get(), WindowsArchiveRestageAuthority::kInstallerProtected,
      nullptr);
  const WindowsFileIdentity file_identity =
      ReadWindowsFileIdentity(installer.get());
  const VerifiedWindowsExecutable signature =
      VerifyRetainedWindowsExecutable(installer.get(), installer_path);
  if (!signature.signature_valid || signature.sha256 != expected_sha256 ||
      FileLength(installer.get()) != expected_length ||
      !VerifyRetainedWindowsExecutableStillMatches(installer.get(),
                                                   signature) ||
      ReadWindowsFileIdentity(installer.get()) != file_identity) {
    Fail("recovered protected Inno restage identity changed");
  }
  DeleteHandleExact(installer.get());
  installer.reset();
  FlushWindowsDirectory(parent.get());
}

} // namespace desktop_updater::helper
