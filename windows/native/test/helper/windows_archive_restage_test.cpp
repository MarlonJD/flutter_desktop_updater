#include <gtest/gtest.h>

#include <windows.h>
#include <aclapi.h>
#include <winternl.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdio>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iterator>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include "miniz.h"

#include "stage_provenance.h"
#include "windows_archive_restage.h"
#include "windows_file_transaction.h"
#include "windows_helper_bootstrap.h"

namespace desktop_updater::helper {
namespace {

constexpr char kTransactionId[] =
    "00000000-0000-4000-8000-000000000081";

std::string ReadBytes(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

struct TestZipEntry {
  std::string name;
  std::string bytes;
};

void WriteZipEntries(const std::filesystem::path& path,
                     const std::vector<TestZipEntry>& entries) {
  std::unique_ptr<FILE, decltype(&std::fclose)> file(
      _wfopen(path.c_str(), L"w+b"), &std::fclose);
  ASSERT_NE(nullptr, file);
  mz_zip_archive archive{};
  ASSERT_TRUE(mz_zip_writer_init_cfile(&archive, file.get(), 0));
  for (const TestZipEntry& entry : entries) {
    ASSERT_TRUE(mz_zip_writer_add_mem(
        &archive, entry.name.c_str(), entry.bytes.data(), entry.bytes.size(),
        MZ_BEST_COMPRESSION));
  }
  ASSERT_TRUE(mz_zip_writer_finalize_archive(&archive));
  ASSERT_TRUE(mz_zip_writer_end(&archive));
  ASSERT_EQ(0, std::fflush(file.get()));
}

void WriteZip(const std::filesystem::path& path) {
  WriteZipEntries(path,
                  {{"bin/example.exe", "signed-archive-payload"}});
}

enum class ZipHeaderMutation {
  kUnsupportedMethod,
  kEncrypted,
  kSymlink,
  kUnsupportedType,
  kReparsePoint,
};

std::uint32_t ReadLittleEndian32(const std::vector<unsigned char>& bytes,
                                 std::size_t offset) {
  return static_cast<std::uint32_t>(bytes[offset]) |
         (static_cast<std::uint32_t>(bytes[offset + 1]) << 8) |
         (static_cast<std::uint32_t>(bytes[offset + 2]) << 16) |
         (static_cast<std::uint32_t>(bytes[offset + 3]) << 24);
}

std::uint16_t ReadLittleEndian16(const std::vector<unsigned char>& bytes,
                                 std::size_t offset) {
  return static_cast<std::uint16_t>(bytes[offset]) |
         (static_cast<std::uint16_t>(bytes[offset + 1]) << 8);
}

void WriteLittleEndian16(std::vector<unsigned char>* bytes,
                         std::size_t offset,
                         std::uint16_t value) {
  (*bytes)[offset] = static_cast<unsigned char>(value & 0xff);
  (*bytes)[offset + 1] = static_cast<unsigned char>(value >> 8);
}

void WriteLittleEndian32(std::vector<unsigned char>* bytes,
                         std::size_t offset,
                         std::uint32_t value) {
  (*bytes)[offset] = static_cast<unsigned char>(value & 0xff);
  (*bytes)[offset + 1] = static_cast<unsigned char>((value >> 8) & 0xff);
  (*bytes)[offset + 2] = static_cast<unsigned char>((value >> 16) & 0xff);
  (*bytes)[offset + 3] = static_cast<unsigned char>((value >> 24) & 0xff);
}

void MutateZipHeaders(const std::filesystem::path& path,
                      ZipHeaderMutation mutation) {
  const std::string encoded = ReadBytes(path);
  std::vector<unsigned char> bytes(encoded.begin(), encoded.end());
  bool local_seen = false;
  bool central_seen = false;
  for (std::size_t offset = 0; offset + 46 <= bytes.size(); ++offset) {
    const std::uint32_t signature = ReadLittleEndian32(bytes, offset);
    if (signature == UINT32_C(0x04034b50)) {
      local_seen = true;
      if (mutation == ZipHeaderMutation::kUnsupportedMethod) {
        WriteLittleEndian16(&bytes, offset + 8, 99);
      } else if (mutation == ZipHeaderMutation::kEncrypted) {
        const std::uint16_t flags =
            static_cast<std::uint16_t>(bytes[offset + 6]) |
            (static_cast<std::uint16_t>(bytes[offset + 7]) << 8);
        WriteLittleEndian16(&bytes, offset + 6, flags | 1);
      }
    } else if (signature == UINT32_C(0x02014b50)) {
      central_seen = true;
      if (mutation == ZipHeaderMutation::kUnsupportedMethod) {
        WriteLittleEndian16(&bytes, offset + 10, 99);
      } else if (mutation == ZipHeaderMutation::kEncrypted) {
        const std::uint16_t flags =
            static_cast<std::uint16_t>(bytes[offset + 8]) |
            (static_cast<std::uint16_t>(bytes[offset + 9]) << 8);
        WriteLittleEndian16(&bytes, offset + 8, flags | 1);
      } else {
        bytes[offset + 5] = 3;  // ZIP creator operating system: Unix.
        std::uint32_t attributes = 0;
        if (mutation == ZipHeaderMutation::kSymlink) {
          attributes = UINT32_C(0120777) << 16;
        } else if (mutation == ZipHeaderMutation::kUnsupportedType) {
          attributes = UINT32_C(0020600) << 16;
        } else if (mutation == ZipHeaderMutation::kReparsePoint) {
          attributes = FILE_ATTRIBUTE_REPARSE_POINT;
        }
        WriteLittleEndian32(&bytes, offset + 38, attributes);
      }
    }
  }
  ASSERT_TRUE(local_seen);
  ASSERT_TRUE(central_seen);
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  ASSERT_TRUE(output.good());
  output.write(reinterpret_cast<const char*>(bytes.data()),
               static_cast<std::streamsize>(bytes.size()));
  ASSERT_TRUE(output.good());
}

void RewriteOnlyZipEntryName(const std::filesystem::path& path,
                             const std::string& replacement) {
  const std::string encoded = ReadBytes(path);
  std::vector<unsigned char> bytes(encoded.begin(), encoded.end());
  bool local_seen = false;
  bool central_seen = false;
  for (std::size_t offset = 0; offset + 46 <= bytes.size(); ++offset) {
    const std::uint32_t signature = ReadLittleEndian32(bytes, offset);
    std::size_t name_offset = 0;
    std::uint16_t name_length = 0;
    if (signature == UINT32_C(0x04034b50)) {
      local_seen = true;
      name_length = ReadLittleEndian16(bytes, offset + 26);
      name_offset = offset + 30;
    } else if (signature == UINT32_C(0x02014b50)) {
      central_seen = true;
      name_length = ReadLittleEndian16(bytes, offset + 28);
      name_offset = offset + 46;
    } else {
      continue;
    }
    ASSERT_EQ(replacement.size(), name_length);
    ASSERT_LE(name_offset + name_length, bytes.size());
    std::copy(replacement.begin(), replacement.end(),
              bytes.begin() + static_cast<std::ptrdiff_t>(name_offset));
  }
  ASSERT_TRUE(local_seen);
  ASSERT_TRUE(central_seen);
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  ASSERT_TRUE(output.good());
  output.write(reinterpret_cast<const char*>(bytes.data()),
               static_cast<std::streamsize>(bytes.size()));
  ASSERT_TRUE(output.good());
}

void AddAdministratorsFullControl(HANDLE object) {
  std::array<unsigned char, SECURITY_MAX_SID_SIZE> administrators{};
  DWORD sid_size = static_cast<DWORD>(administrators.size());
  ASSERT_TRUE(CreateWellKnownSid(WinBuiltinAdministratorsSid, nullptr,
                                 administrators.data(), &sid_size));
  PSECURITY_DESCRIPTOR raw_descriptor = nullptr;
  PACL old_dacl = nullptr;
  ASSERT_EQ(ERROR_SUCCESS,
            GetSecurityInfo(object, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION,
                            nullptr, nullptr, &old_dacl, nullptr,
                            &raw_descriptor));
  std::unique_ptr<void, decltype(&LocalFree)> descriptor(raw_descriptor,
                                                         LocalFree);
  EXPLICIT_ACCESSW access{};
  access.grfAccessPermissions = FILE_ALL_ACCESS;
  access.grfAccessMode = GRANT_ACCESS;
  access.grfInheritance = SUB_CONTAINERS_AND_OBJECTS_INHERIT;
  BuildTrusteeWithSidW(&access.Trustee, administrators.data());
  PACL raw_new_dacl = nullptr;
  ASSERT_EQ(ERROR_SUCCESS,
            SetEntriesInAclW(1, &access, old_dacl, &raw_new_dacl));
  std::unique_ptr<void, decltype(&LocalFree)> new_dacl(raw_new_dacl,
                                                       LocalFree);
  ASSERT_EQ(ERROR_SUCCESS,
            SetSecurityInfo(object, SE_FILE_OBJECT,
                            DACL_SECURITY_INFORMATION |
                                PROTECTED_DACL_SECURITY_INFORMATION,
                            nullptr, nullptr, raw_new_dacl, nullptr));
}

WindowsVerifiedPayloadIdentity ExpectedIdentity(
    const WindowsVerifiedArchiveRestage& restage) {
  const auto executable = std::find_if(
      restage.provenance().entries.begin(),
      restage.provenance().entries.end(), [](const auto& entry) {
        return entry.path == "bin/example.exe" && entry.kind == "file";
      });
  if (executable == restage.provenance().entries.end()) {
    throw std::runtime_error("restaged executable missing");
  }
  return {
      "com.example.app",
      "Example Software LLC",
      restage.provenance().descriptor_sha256,
      std::string(64, 'c'),
      restage.provenance().artifact_sha256,
      L"bin\\example.exe",
      executable->sha256,
      restage.payload_seal_sha256(),
  };
}

class ExactArchivePayloadVerifier final : public WindowsInstallPayloadVerifier {
 public:
  explicit ExactArchivePayloadVerifier(WindowsVerifiedPayloadIdentity expected)
      : expected_(std::move(expected)) {}

  WindowsVerifiedPayloadIdentity Verify(
      HANDLE parent,
      const std::wstring& bundle_leaf) override {
    auto bundle = OpenRelativeNoReparse(
        parent, bundle_leaf,
        FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
        FILE_SHARE_READ | FILE_SHARE_DELETE, FILE_OPEN,
        FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
    if (ExistsRelativeNoReparse(bundle.get(), L"caller-injected.dll")) {
      throw std::runtime_error("caller-injected payload reached transaction");
    }
    if (ReadUtf8FileRelative(bundle.get(), L"bin\\example.exe", 1024) !=
        "signed-archive-payload") {
      throw std::runtime_error("archive payload changed");
    }
    return expected_;
  }

 private:
  WindowsVerifiedPayloadIdentity expected_;
};

TEST(WindowsArchiveRestage,
     CallerInjectedDllAbsentFromSignedZipIsNeverActivated) {
  const std::filesystem::path root =
      std::filesystem::temp_directory_path() /
      (L"desktop-updater-archive-restage-" +
       std::to_wstring(GetCurrentProcessId()) + L"-" +
       std::to_wstring(GetTickCount64()));
  const std::filesystem::path target = root / L"Example.app";
  const std::filesystem::path caller_stage = root / L"caller-stage";
  ASSERT_TRUE(std::filesystem::create_directories(target));
  ASSERT_TRUE(std::filesystem::create_directories(caller_stage));
  std::ofstream(target / L"old.txt", std::ios::binary) << "old";

  const std::filesystem::path archive =
      caller_stage / L".desktop_updater_artifact.zip";
  WriteZip(archive);
  std::ofstream(caller_stage / L"caller-injected.dll", std::ios::binary)
      << "unsigned injected bytes";
  ASSERT_TRUE(std::filesystem::exists(caller_stage /
                                      L"caller-injected.dll"));

  const std::string artifact_bytes = ReadBytes(archive);
  const std::string artifact_sha256 =
      desktop_updater::runtime::internal::StageBytesToHex(
          WindowsHelperSha256Bytes(artifact_bytes));
  const std::string release_manifest =
      R"({"artifact":{"kind":"zip"},"schemaVersion":3})";
  const std::string descriptor_sha256 =
      desktop_updater::runtime::internal::StageBytesToHex(
          WindowsHelperSha256Bytes(release_manifest));
  WindowsVerifiedArchiveRestage restage = RestageVerifiedWindowsZip(
      caller_stage, root, kTransactionId, "com.example.app",
      descriptor_sha256, artifact_sha256,
      static_cast<std::int64_t>(artifact_bytes.size()),
      release_manifest,
      WindowsArchiveRestageAuthority::kPortableExactCaller,
      GetCurrentProcess());

  EXPECT_FALSE(std::filesystem::exists(restage.path() /
                                       L"caller-injected.dll"));
  EXPECT_FALSE(std::filesystem::exists(
      restage.path() / L".desktop_updater_artifact.zip"));
  EXPECT_FALSE(std::filesystem::exists(
      restage.path() / L".desktop_updater_release_manifest.json"));
  EXPECT_FALSE(std::filesystem::exists(
      restage.path() / L".desktop_updater_stage_provenance.json"));
  EXPECT_EQ(restage.provenance().entries.end(),
            std::find_if(restage.provenance().entries.begin(),
                         restage.provenance().entries.end(),
                         [](const auto& entry) {
                           return entry.path == "caller-injected.dll";
                         }));
  std::vector<UniqueWindowsHandle> sealed_handles;
  const WindowsPayloadSeal recomputed = SealWindowsPayloadTree(
      restage.parent_handle(), restage.path().filename().wstring(),
      "com.example.app", descriptor_sha256, artifact_sha256,
      &sealed_handles);
  EXPECT_EQ(restage.payload_seal_sha256(), recomputed.sha256);
  EXPECT_NO_THROW(VerifyWindowsArchiveRestageSecurity(
      restage.root_handle(),
      WindowsArchiveRestageAuthority::kPortableExactCaller,
      GetCurrentProcess()));
  auto executable_handle = OpenRelativeNoReparse(
      restage.root_handle(), L"bin\\example.exe",
      GENERIC_READ | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_DELETE, FILE_OPEN,
      FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
  EXPECT_EQ(1U,
            ReadWindowsFileIdentity(executable_handle.get()).number_of_links);
  executable_handle.reset();
  sealed_handles.clear();

  const WindowsVerifiedPayloadIdentity expected = ExpectedIdentity(restage);
  ExactArchivePayloadVerifier verifier(expected);
  WindowsFileTransaction transaction(target, restage.path(), kTransactionId,
                                     GetCurrentProcessId(), expected, verifier,
                                     restage.parent_handle(),
                                     restage.root_handle(), nullptr, {},
                                     std::nullopt, {}, [&restage]() {
                                       restage.ReleaseToTransaction();
                                     });
  EXPECT_EQ(WindowsFileTransactionResult::kCompleted,
            transaction.Execute());
  EXPECT_FALSE(std::filesystem::exists(target / L"caller-injected.dll"));
  EXPECT_EQ("signed-archive-payload",
            ReadBytes(target / L"bin" / L"example.exe"));

  auto active_root = OpenRelativeNoReparse(
      restage.parent_handle(), target.filename().wstring(),
      READ_CONTROL | WRITE_DAC | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, FILE_OPEN,
      FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT);
  AddAdministratorsFullControl(active_root.get());
  EXPECT_THROW(VerifyWindowsArchiveRestageSecurity(
                   restage.root_handle(),
                   WindowsArchiveRestageAuthority::kPortableExactCaller,
                   GetCurrentProcess()),
               WindowsArchiveRestageError);

  std::error_code ignored;
  std::filesystem::remove_all(root, ignored);
}

class ThrowAtRestageFault final : public WindowsArchiveRestageFaultInjector {
 public:
  explicit ThrowAtRestageFault(WindowsArchiveRestageFaultPoint point)
      : point_(point) {}

  void Hit(WindowsArchiveRestageFaultPoint point) override {
    if (!thrown_ && point == point_) {
      thrown_ = true;
      throw std::runtime_error("simulated restage process crash");
    }
  }

 private:
  WindowsArchiveRestageFaultPoint point_;
  bool thrown_ = false;
};

class InjectExtraAfterExtraction final
    : public WindowsArchiveRestageFaultInjector {
 public:
  explicit InjectExtraAfterExtraction(std::filesystem::path root)
      : root_(std::move(root)) {}

  void Hit(WindowsArchiveRestageFaultPoint point) override {
    if (point != WindowsArchiveRestageFaultPoint::kBeforePayloadSeal ||
        injected_) {
      return;
    }
    for (const auto& entry : std::filesystem::directory_iterator(root_)) {
      if (entry.is_directory() &&
          entry.path().filename().wstring().rfind(
              L"desktop_updater_stage_", 0) == 0) {
        std::ofstream(entry.path() / L"concurrent-extra.dll",
                      std::ios::binary)
            << "not-in-signed-zip";
        injected_ = true;
        return;
      }
    }
    throw std::runtime_error("restaged payload root was not found");
  }

  bool injected() const { return injected_; }

 private:
  std::filesystem::path root_;
  bool injected_ = false;
};

bool IsRestageControlArtifact(const std::filesystem::path& path) {
  const std::wstring leaf = path.filename().wstring();
  return leaf.rfind(L".desktop-updater-restage-", 0) == 0 ||
         leaf.rfind(L"desktop_updater_stage_", 0) == 0 ||
         (leaf.rfind(L".desktop-updater-", 0) == 0 &&
          leaf.find(L".restage.json") != std::wstring::npos);
}

void ExpectExactPortableRestageSecurity(
    const std::filesystem::path& path) {
  const DWORD attributes = GetFileAttributesW(path.c_str());
  ASSERT_NE(INVALID_FILE_ATTRIBUTES, attributes) << path.string();
  UniqueWindowsHandle handle(CreateFileW(
      path.c_str(), FILE_READ_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING,
      FILE_FLAG_OPEN_REPARSE_POINT |
          ((attributes & FILE_ATTRIBUTE_DIRECTORY) != 0
               ? FILE_FLAG_BACKUP_SEMANTICS
               : static_cast<DWORD>(0)),
      nullptr));
  ASSERT_TRUE(handle.valid()) << path.string();
  EXPECT_NO_THROW(VerifyWindowsArchiveRestageSecurity(
      handle.get(), WindowsArchiveRestageAuthority::kPortableExactCaller,
      GetCurrentProcess()));
  if ((attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
    for (const auto& child : std::filesystem::directory_iterator(path)) {
      ExpectExactPortableRestageSecurity(child.path());
    }
  }
}

std::unique_ptr<void, decltype(&LocalFree)> ReadObjectSecurityDescriptor(
    HANDLE object) {
  PSECURITY_DESCRIPTOR raw_descriptor = nullptr;
  const DWORD result = GetSecurityInfo(
      object, SE_FILE_OBJECT,
      OWNER_SECURITY_INFORMATION | GROUP_SECURITY_INFORMATION |
          DACL_SECURITY_INFORMATION,
      nullptr, nullptr, nullptr, nullptr, &raw_descriptor);
  if (result != ERROR_SUCCESS || raw_descriptor == nullptr) {
    if (raw_descriptor != nullptr) LocalFree(raw_descriptor);
    throw std::runtime_error("test security descriptor read failed");
  }
  return {raw_descriptor, LocalFree};
}

UniqueWindowsHandle OpenMutablePayloadRoot(
    const std::filesystem::path& path) {
  UniqueWindowsHandle result(CreateFileW(
      path.c_str(),
      GENERIC_READ | GENERIC_WRITE | DELETE | FILE_LIST_DIRECTORY |
          FILE_ADD_FILE | FILE_ADD_SUBDIRECTORY | FILE_TRAVERSE |
          FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES | READ_CONTROL |
          SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (!result.valid()) {
    throw std::runtime_error("test payload root open failed");
  }
  return result;
}

UniqueWindowsHandle CreateExactTestDirectory(
    HANDLE parent,
    const std::wstring& leaf,
    PSECURITY_DESCRIPTOR security_descriptor) {
  return OpenRelativeNoReparse(
      parent, leaf,
      GENERIC_READ | GENERIC_WRITE | DELETE | FILE_LIST_DIRECTORY |
          FILE_ADD_FILE | FILE_ADD_SUBDIRECTORY | FILE_TRAVERSE |
          FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES | READ_CONTROL |
          SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, FILE_CREATE,
      FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT |
          FILE_WRITE_THROUGH,
      FILE_ATTRIBUTE_NORMAL, security_descriptor);
}

void CreateExactTestFile(HANDLE parent,
                         const std::wstring& leaf,
                         PSECURITY_DESCRIPTOR security_descriptor) {
  auto file = OpenRelativeNoReparse(
      parent, leaf,
      GENERIC_READ | GENERIC_WRITE | DELETE | FILE_READ_ATTRIBUTES |
          FILE_WRITE_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, FILE_CREATE,
      FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT |
          FILE_WRITE_THROUGH,
      FILE_ATTRIBUTE_NORMAL, security_descriptor);
  const char byte = 'x';
  DWORD written = 0;
  if (!WriteFile(file.get(), &byte, 1, &written, nullptr) || written != 1 ||
      !FlushFileBuffers(file.get())) {
    throw std::runtime_error("test payload file write failed");
  }
}

std::filesystem::path FindRestagePayload(
    const std::filesystem::path& root) {
  for (const auto& entry : std::filesystem::directory_iterator(root)) {
    if (entry.is_directory() &&
        entry.path().filename().wstring().rfind(
            L"desktop_updater_stage_", 0) == 0) {
      return entry.path();
    }
  }
  throw std::runtime_error("test restage payload was not found");
}

std::size_t CountPayloadDescendants(const std::filesystem::path& root) {
  return static_cast<std::size_t>(std::distance(
      std::filesystem::recursive_directory_iterator(root),
      std::filesystem::recursive_directory_iterator()));
}

void ExpectArchiveRejected(
    const std::vector<TestZipEntry>& entries,
    const WindowsArchiveRestageLimits& limits = {},
    const ZipHeaderMutation* mutation = nullptr,
    const std::string* rewritten_name = nullptr) {
  static LONG sequence = 0;
  const std::filesystem::path root =
      std::filesystem::temp_directory_path() /
      (L"desktop-updater-archive-rejected-" +
       std::to_wstring(GetCurrentProcessId()) + L"-" +
       std::to_wstring(GetTickCount64()) + L"-" +
       std::to_wstring(InterlockedIncrement(&sequence)));
  const std::filesystem::path caller_stage = root / L"caller-stage";
  ASSERT_TRUE(std::filesystem::create_directories(caller_stage));
  const std::filesystem::path archive =
      caller_stage / L".desktop_updater_artifact.zip";
  WriteZipEntries(archive, entries);
  if (rewritten_name != nullptr) {
    RewriteOnlyZipEntryName(archive, *rewritten_name);
  }
  if (mutation != nullptr) MutateZipHeaders(archive, *mutation);
  const std::string artifact_bytes = ReadBytes(archive);
  const std::string artifact_sha256 =
      desktop_updater::runtime::internal::StageBytesToHex(
          WindowsHelperSha256Bytes(artifact_bytes));
  const std::string release_manifest =
      R"({"artifact":{"kind":"zip"},"schemaVersion":3})";
  const std::string descriptor_sha256 =
      desktop_updater::runtime::internal::StageBytesToHex(
          WindowsHelperSha256Bytes(release_manifest));

  EXPECT_THROW(
      {
        WindowsVerifiedArchiveRestage rejected = RestageVerifiedWindowsZip(
            caller_stage, root, kTransactionId, "com.example.app",
            descriptor_sha256, artifact_sha256,
            static_cast<std::int64_t>(artifact_bytes.size()),
            release_manifest,
            WindowsArchiveRestageAuthority::kPortableExactCaller,
            GetCurrentProcess(), limits);
      },
      WindowsArchiveRestageError);
  for (const auto& entry : std::filesystem::directory_iterator(root)) {
    EXPECT_FALSE(IsRestageControlArtifact(entry.path()))
        << entry.path().string();
  }
  std::error_code ignored;
  std::filesystem::remove_all(root, ignored);
}

TEST(WindowsArchiveRestage,
     RejectsUnsafeWindowsPathsDuplicatesAndControlPlaneNames) {
  std::string too_deep;
  for (int index = 0; index < 257; ++index) {
    if (!too_deep.empty()) too_deep.push_back('/');
    too_deep.push_back('a');
  }
  const std::vector<std::pair<std::string, std::vector<TestZipEntry>>> cases = {
      {"parent traversal", {{"../evil.dll", "x"}}},
      {"embedded traversal", {{"bin/../evil.dll", "x"}}},
      {"dot component", {{"bin/./evil.dll", "x"}}},
      {"empty component", {{"bin//evil.dll", "x"}}},
      {"drive", {{"C:/evil.dll", "x"}}},
      {"backslash", {{"bin\\evil.dll", "x"}}},
      {"alternate data stream", {{"example.exe:evil", "x"}}},
      {"DOS device", {{"CON.txt", "x"}}},
      {"DOS numbered device", {{"bin/LPT9.log", "x"}}},
      {"trailing dot", {{"evil.", "x"}}},
      {"trailing space", {{"evil ", "x"}}},
      {"overlong component", {{std::string(256, 'a'), "x"}}},
      {"overdeep path", {{too_deep, "x"}}},
      {"duplicate", {{"a.dll", "x"}, {"a.dll", "y"}}},
      {"case collision", {{"A.dll", "x"}, {"a.dll", "y"}}},
      {"case parent collision",
       {{"Bin/a.dll", "x"}, {"bin/b.dll", "y"}}},
      {"file parent collision", {{"bin", "x"}, {"bin/a.dll", "y"}}},
      {"file directory collision", {{"bin/", ""}, {"bin", "x"}}},
      {"artifact control name",
       {{".desktop_updater_artifact.zip", "x"}}},
      {"manifest control name",
       {{".desktop_updater_release_manifest.json", "x"}}},
      {"provenance control name",
       {{".desktop_updater_stage_provenance.json", "x"}}},
  };
  for (const auto& [label, entries] : cases) {
    SCOPED_TRACE(label);
    ExpectArchiveRejected(entries);
  }
  for (const std::string& rejected_name :
       {std::string("/evil.dll"),
        std::string("//server/share/evil.dll")}) {
    SCOPED_TRACE(rejected_name);
    const std::string placeholder(rejected_name.size(), 'x');
    ExpectArchiveRejected({{placeholder, "x"}}, {}, nullptr,
                          &rejected_name);
  }
}

TEST(WindowsArchiveRestage,
     RejectsEncryptedUnsupportedSymlinkReparseAndSpecialTypeEntries) {
  const std::array<ZipHeaderMutation, 5> mutations = {
      ZipHeaderMutation::kUnsupportedMethod,
      ZipHeaderMutation::kEncrypted,
      ZipHeaderMutation::kSymlink,
      ZipHeaderMutation::kUnsupportedType,
      ZipHeaderMutation::kReparsePoint,
  };
  for (const ZipHeaderMutation mutation : mutations) {
    SCOPED_TRACE(static_cast<int>(mutation));
    ExpectArchiveRejected({{"bin/example.exe", "x"}}, {}, &mutation);
  }
}

TEST(WindowsArchiveRestage, RejectsEntryCountAndExpandedSizeLimitViolations) {
  WindowsArchiveRestageLimits entry_count;
  entry_count.maximum_archive_entries = 1;
  ExpectArchiveRejected({{"a", "x"}, {"b", "y"}}, entry_count);

  WindowsArchiveRestageLimits single_entry;
  single_entry.maximum_single_entry_bytes = 3;
  single_entry.maximum_uncompressed_bytes = 100;
  ExpectArchiveRejected({{"a", "four"}}, single_entry);

  WindowsArchiveRestageLimits total;
  total.maximum_single_entry_bytes = 100;
  total.maximum_uncompressed_bytes = 5;
  ExpectArchiveRejected({{"a", "abc"}, {"b", "def"}}, total);

  WindowsArchiveRestageLimits loosened_entries;
  loosened_entries.maximum_archive_entries = 100001;
  ExpectArchiveRejected({{"a", "x"}}, loosened_entries);

  WindowsArchiveRestageLimits loosened_single;
  loosened_single.maximum_single_entry_bytes =
      INT64_C(4) * 1024 * 1024 * 1024 + 1;
  ExpectArchiveRejected({{"a", "x"}}, loosened_single);

  WindowsArchiveRestageLimits loosened_total;
  loosened_total.maximum_uncompressed_bytes =
      INT64_C(8) * 1024 * 1024 * 1024 + 1;
  ExpectArchiveRejected({{"a", "x"}}, loosened_total);

  WindowsArchiveRestageLimits loosened_recovery_depth;
  loosened_recovery_depth.maximum_recovery_depth = 257;
  ExpectArchiveRejected({{"a", "x"}}, loosened_recovery_depth);

  WindowsArchiveRestageLimits loosened_recovery_work;
  loosened_recovery_work.maximum_recovery_work_units = 1000001;
  ExpectArchiveRejected({{"a", "x"}}, loosened_recovery_work);

  ExpectArchiveRejected({});
}

TEST(WindowsArchiveRestage,
     RejectsCumulativePayloadSealBytesBeforeCanonicalEncoding) {
  WindowsArchiveRestageLimits seal;
  seal.maximum_payload_seal_bytes = 256;
  ExpectArchiveRejected({{"bin/example.exe", "x"}}, seal);
}

TEST(WindowsArchiveRestage,
     RejectsCumulativePathStorageBeforeBuildingArchiveInventory) {
  WindowsArchiveRestageLimits paths;
  paths.maximum_payload_path_bytes = 512;
  const std::string first = std::string(220, 'a') + ".dll";
  const std::string second = std::string(220, 'b') + ".dll";
  ExpectArchiveRejected({{first, "x"}, {second, "y"}}, paths);
}

TEST(WindowsArchiveRestage,
     RejectsConcurrentEntryInsertedAfterSignedArchiveExtraction) {
  const std::filesystem::path root =
      std::filesystem::temp_directory_path() /
      (L"desktop-updater-archive-concurrent-extra-" +
       std::to_wstring(GetCurrentProcessId()) + L"-" +
       std::to_wstring(GetTickCount64()));
  const std::filesystem::path caller_stage = root / L"caller-stage";
  ASSERT_TRUE(std::filesystem::create_directories(caller_stage));
  const std::filesystem::path archive =
      caller_stage / L".desktop_updater_artifact.zip";
  WriteZip(archive);
  const std::string artifact_bytes = ReadBytes(archive);
  const std::string artifact_sha256 =
      desktop_updater::runtime::internal::StageBytesToHex(
          WindowsHelperSha256Bytes(artifact_bytes));
  const std::string release_manifest =
      R"({"artifact":{"kind":"zip"},"schemaVersion":3})";
  const std::string descriptor_sha256 =
      desktop_updater::runtime::internal::StageBytesToHex(
          WindowsHelperSha256Bytes(release_manifest));
  InjectExtraAfterExtraction injector(root);

  EXPECT_THROW(
      RestageVerifiedWindowsZip(
          caller_stage, root, kTransactionId, "com.example.app",
          descriptor_sha256, artifact_sha256,
          static_cast<std::int64_t>(artifact_bytes.size()), release_manifest,
          WindowsArchiveRestageAuthority::kPortableExactCaller,
          GetCurrentProcess(), {}, &injector),
      WindowsArchiveRestageError);
  EXPECT_TRUE(injector.injected());
  for (const auto& entry : std::filesystem::directory_iterator(root)) {
    EXPECT_FALSE(IsRestageControlArtifact(entry.path()))
        << entry.path().string();
  }
  std::error_code ignored;
  std::filesystem::remove_all(root, ignored);
}

TEST(WindowsArchiveRestage,
     DurableControlRecoversEveryPreJournalCrashPointOnRetry) {
  const std::array<WindowsArchiveRestageFaultPoint, 12> fault_points = {
      WindowsArchiveRestageFaultPoint::kAfterControlFileCreate,
      WindowsArchiveRestageFaultPoint::kAfterControlFileFlushBeforeRename,
      WindowsArchiveRestageFaultPoint::kAfterControlRenameBeforeDirectoryFlush,
      WindowsArchiveRestageFaultPoint::kAfterArchiveFileCreate,
      WindowsArchiveRestageFaultPoint::kDuringArchiveCopy,
      WindowsArchiveRestageFaultPoint::kAfterArchiveCopyBeforePreflight,
      WindowsArchiveRestageFaultPoint::kAfterPayloadRootDirectoryCreate,
      WindowsArchiveRestageFaultPoint::kAfterPayloadDirectoryCreate,
      WindowsArchiveRestageFaultPoint::kAfterPayloadFileCreate,
      WindowsArchiveRestageFaultPoint::kDuringExtraction,
      WindowsArchiveRestageFaultPoint::kBeforePayloadSeal,
      WindowsArchiveRestageFaultPoint::
          kAfterExtractionBeforeTransactionJournal,
  };
  std::uint64_t suffix = 0;
  for (const WindowsArchiveRestageFaultPoint fault_point : fault_points) {
    const std::filesystem::path root =
        std::filesystem::temp_directory_path() /
        (L"desktop-updater-archive-retry-" +
         std::to_wstring(GetCurrentProcessId()) + L"-" +
         std::to_wstring(GetTickCount64()) + L"-" +
         std::to_wstring(suffix++));
    const std::filesystem::path caller_stage = root / L"caller-stage";
    ASSERT_TRUE(std::filesystem::create_directories(caller_stage));
    const std::filesystem::path archive =
        caller_stage / L".desktop_updater_artifact.zip";
    WriteZip(archive);
    const std::string artifact_bytes = ReadBytes(archive);
    const std::string artifact_sha256 =
        desktop_updater::runtime::internal::StageBytesToHex(
            WindowsHelperSha256Bytes(artifact_bytes));
    const std::string release_manifest =
        R"({"artifact":{"kind":"zip"},"schemaVersion":3})";
    const std::string descriptor_sha256 =
        desktop_updater::runtime::internal::StageBytesToHex(
            WindowsHelperSha256Bytes(release_manifest));

    ThrowAtRestageFault injector(fault_point);
    EXPECT_THROW(
        RestageVerifiedWindowsZip(
            caller_stage, root, kTransactionId, "com.example.app",
            descriptor_sha256, artifact_sha256,
            static_cast<std::int64_t>(artifact_bytes.size()),
            release_manifest,
            WindowsArchiveRestageAuthority::kPortableExactCaller,
            GetCurrentProcess(), {}, &injector),
        std::runtime_error);
    const std::filesystem::path control =
        root /
        L".desktop-updater-00000000-0000-4000-8000-000000000081.restage.json";
    if (fault_point ==
            WindowsArchiveRestageFaultPoint::kAfterControlFileCreate ||
        fault_point == WindowsArchiveRestageFaultPoint::
                           kAfterControlFileFlushBeforeRename) {
      EXPECT_TRUE(std::filesystem::exists(control.wstring() + L".next"));
    } else {
      EXPECT_TRUE(std::filesystem::exists(control));
    }
    for (const auto& entry : std::filesystem::directory_iterator(root)) {
      if (IsRestageControlArtifact(entry.path())) {
        ExpectExactPortableRestageSecurity(entry.path());
      }
    }

    {
      WindowsVerifiedArchiveRestage retry = RestageVerifiedWindowsZip(
          caller_stage, root, kTransactionId, "com.example.app",
          descriptor_sha256, artifact_sha256,
          static_cast<std::int64_t>(artifact_bytes.size()), release_manifest,
          WindowsArchiveRestageAuthority::kPortableExactCaller,
          GetCurrentProcess());
      EXPECT_EQ("signed-archive-payload",
                ReadBytes(retry.path() / L"bin" / L"example.exe"));
    }

    for (const auto& entry : std::filesystem::directory_iterator(root)) {
      EXPECT_FALSE(IsRestageControlArtifact(entry.path()))
          << entry.path().string();
    }
    std::error_code ignored;
    std::filesystem::remove_all(root, ignored);
  }
}

TEST(WindowsArchiveRestage,
     PostJournalControlCleanupFailurePreservesPayloadForRecovery) {
  const std::filesystem::path root =
      std::filesystem::temp_directory_path() /
      (L"desktop-updater-archive-release-failure-" +
       std::to_wstring(GetCurrentProcessId()) + L"-" +
       std::to_wstring(GetTickCount64()));
  const std::filesystem::path caller_stage = root / L"caller-stage";
  ASSERT_TRUE(std::filesystem::create_directories(caller_stage));
  const std::filesystem::path archive =
      caller_stage / L".desktop_updater_artifact.zip";
  WriteZip(archive);
  const std::string artifact_bytes = ReadBytes(archive);
  const std::string artifact_sha256 =
      desktop_updater::runtime::internal::StageBytesToHex(
          WindowsHelperSha256Bytes(artifact_bytes));
  const std::string release_manifest =
      R"({"artifact":{"kind":"zip"},"schemaVersion":3})";
  const std::string descriptor_sha256 =
      desktop_updater::runtime::internal::StageBytesToHex(
          WindowsHelperSha256Bytes(release_manifest));
  const std::filesystem::path control =
      root /
      L".desktop-updater-00000000-0000-4000-8000-000000000081.restage.json";
  std::filesystem::path payload;

  {
    ThrowAtRestageFault injector(
        WindowsArchiveRestageFaultPoint::kDuringPostJournalControlCleanup);
    WindowsVerifiedArchiveRestage restage = RestageVerifiedWindowsZip(
        caller_stage, root, kTransactionId, "com.example.app",
        descriptor_sha256, artifact_sha256,
        static_cast<std::int64_t>(artifact_bytes.size()), release_manifest,
        WindowsArchiveRestageAuthority::kPortableExactCaller,
        GetCurrentProcess(), {}, &injector);
    payload = restage.path();
    EXPECT_THROW(restage.ReleaseToTransaction(), std::runtime_error);
  }

  EXPECT_TRUE(std::filesystem::exists(payload / L"bin" / L"example.exe"));
  EXPECT_TRUE(std::filesystem::exists(control));

  {
    WindowsVerifiedArchiveRestage retry = RestageVerifiedWindowsZip(
        caller_stage, root, kTransactionId, "com.example.app",
        descriptor_sha256, artifact_sha256,
        static_cast<std::int64_t>(artifact_bytes.size()), release_manifest,
        WindowsArchiveRestageAuthority::kPortableExactCaller,
        GetCurrentProcess());
    EXPECT_EQ("signed-archive-payload",
              ReadBytes(retry.path() / L"bin" / L"example.exe"));
  }
  std::error_code ignored;
  std::filesystem::remove_all(root, ignored);
}

TEST(WindowsArchiveRestage,
     CrashRetryRefusesDeepWidePathAndWorkBudgetMutationWithoutPartialDelete) {
  using ConfigureLimits =
      std::function<void(WindowsArchiveRestageLimits*)>;
  using MutatePayload =
      std::function<void(HANDLE, PSECURITY_DESCRIPTOR)>;
  static LONG sequence = 0;
  auto run_case = [&](const char* label,
                      const ConfigureLimits& configure_limits,
                      const MutatePayload& mutate_payload) {
    SCOPED_TRACE(label);
    const std::filesystem::path root =
        std::filesystem::temp_directory_path() /
        (L"desktop-updater-archive-bounded-retry-" +
         std::to_wstring(GetCurrentProcessId()) + L"-" +
         std::to_wstring(GetTickCount64()) + L"-" +
         std::to_wstring(InterlockedIncrement(&sequence)));
    const std::filesystem::path caller_stage = root / L"caller-stage";
    ASSERT_TRUE(std::filesystem::create_directories(caller_stage));
    const std::filesystem::path archive =
        caller_stage / L".desktop_updater_artifact.zip";
    WriteZip(archive);
    const std::string artifact_bytes = ReadBytes(archive);
    const std::string artifact_sha256 =
        desktop_updater::runtime::internal::StageBytesToHex(
            WindowsHelperSha256Bytes(artifact_bytes));
    const std::string release_manifest =
        R"({"artifact":{"kind":"zip"},"schemaVersion":3})";
    const std::string descriptor_sha256 =
        desktop_updater::runtime::internal::StageBytesToHex(
            WindowsHelperSha256Bytes(release_manifest));

    ThrowAtRestageFault crash(
        WindowsArchiveRestageFaultPoint::kAfterPayloadRootDirectoryCreate);
    EXPECT_THROW(
        RestageVerifiedWindowsZip(
            caller_stage, root, kTransactionId, "com.example.app",
            descriptor_sha256, artifact_sha256,
            static_cast<std::int64_t>(artifact_bytes.size()), release_manifest,
            WindowsArchiveRestageAuthority::kPortableExactCaller,
            GetCurrentProcess(), {}, &crash),
        std::runtime_error);

    const std::filesystem::path payload = FindRestagePayload(root);
    {
      auto payload_root = OpenMutablePayloadRoot(payload);
      auto descriptor = ReadObjectSecurityDescriptor(payload_root.get());
      mutate_payload(payload_root.get(), descriptor.get());
    }
    ExpectExactPortableRestageSecurity(payload);
    const std::size_t before = CountPayloadDescendants(payload);
    ASSERT_GT(before, 0U);

    WindowsArchiveRestageLimits limits;
    configure_limits(&limits);
    EXPECT_THROW(
        RestageVerifiedWindowsZip(
            caller_stage, root, kTransactionId, "com.example.app",
            descriptor_sha256, artifact_sha256,
            static_cast<std::int64_t>(artifact_bytes.size()), release_manifest,
            WindowsArchiveRestageAuthority::kPortableExactCaller,
            GetCurrentProcess(), limits),
        WindowsArchiveRestageError);
    EXPECT_TRUE(std::filesystem::exists(payload));
    EXPECT_EQ(before, CountPayloadDescendants(payload));
    EXPECT_TRUE(std::filesystem::exists(
        root /
        L".desktop-updater-00000000-0000-4000-8000-000000000081.restage.json"));

    {
      WindowsVerifiedArchiveRestage retry = RestageVerifiedWindowsZip(
          caller_stage, root, kTransactionId, "com.example.app",
          descriptor_sha256, artifact_sha256,
          static_cast<std::int64_t>(artifact_bytes.size()), release_manifest,
          WindowsArchiveRestageAuthority::kPortableExactCaller,
          GetCurrentProcess());
      EXPECT_FALSE(std::filesystem::exists(payload));
      EXPECT_EQ("signed-archive-payload",
                ReadBytes(retry.path() / L"bin" / L"example.exe"));
    }
    std::error_code ignored;
    std::filesystem::remove_all(root, ignored);
  };

  run_case(
      "depth",
      [](WindowsArchiveRestageLimits* limits) {
        limits->maximum_recovery_depth = 2;
      },
      [](HANDLE root, PSECURITY_DESCRIPTOR descriptor) {
        HANDLE parent = root;
        UniqueWindowsHandle current;
        for (int depth = 0; depth < 3; ++depth) {
          auto child = CreateExactTestDirectory(
              parent, L"deep-" + std::to_wstring(depth), descriptor);
          current = std::move(child);
          parent = current.get();
        }
      });
  run_case(
      "width",
      [](WindowsArchiveRestageLimits* limits) {
        limits->maximum_archive_entries = 2;
      },
      [](HANDLE root, PSECURITY_DESCRIPTOR descriptor) {
        for (int index = 0; index < 3; ++index) {
          CreateExactTestFile(root, L"wide-" + std::to_wstring(index),
                              descriptor);
        }
      });
  run_case(
      "cumulative-path",
      [](WindowsArchiveRestageLimits* limits) {
        limits->maximum_payload_path_bytes = 16;
      },
      [](HANDLE root, PSECURITY_DESCRIPTOR descriptor) {
        CreateExactTestFile(root, L"path-budget-overflow", descriptor);
      });
  run_case(
      "work",
      [](WindowsArchiveRestageLimits* limits) {
        limits->maximum_recovery_work_units = 2;
      },
      [](HANDLE root, PSECURITY_DESCRIPTOR descriptor) {
        CreateExactTestFile(root, L"work", descriptor);
      });
}

TEST(WindowsArchiveRestage,
     LiveDurableControlCannotBeMisclassifiedAsCrashedRetry) {
  const std::filesystem::path root =
      std::filesystem::temp_directory_path() /
      (L"desktop-updater-archive-live-owner-" +
       std::to_wstring(GetCurrentProcessId()) + L"-" +
       std::to_wstring(GetTickCount64()));
  const std::filesystem::path caller_stage = root / L"caller-stage";
  ASSERT_TRUE(std::filesystem::create_directories(caller_stage));
  const std::filesystem::path archive =
      caller_stage / L".desktop_updater_artifact.zip";
  WriteZip(archive);
  const std::string artifact_bytes = ReadBytes(archive);
  const std::string artifact_sha256 =
      desktop_updater::runtime::internal::StageBytesToHex(
          WindowsHelperSha256Bytes(artifact_bytes));
  const std::string release_manifest =
      R"({"artifact":{"kind":"zip"},"schemaVersion":3})";
  const std::string descriptor_sha256 =
      desktop_updater::runtime::internal::StageBytesToHex(
          WindowsHelperSha256Bytes(release_manifest));

  {
    WindowsVerifiedArchiveRestage live = RestageVerifiedWindowsZip(
        caller_stage, root, kTransactionId, "com.example.app",
        descriptor_sha256, artifact_sha256,
        static_cast<std::int64_t>(artifact_bytes.size()), release_manifest,
        WindowsArchiveRestageAuthority::kPortableExactCaller,
        GetCurrentProcess());
    const std::filesystem::path live_path = live.path();
    const std::string live_seal = live.payload_seal_sha256();

    EXPECT_THROW(
        RestageVerifiedWindowsZip(
            caller_stage, root, kTransactionId, "com.example.app",
            descriptor_sha256, artifact_sha256,
            static_cast<std::int64_t>(artifact_bytes.size()),
            release_manifest,
            WindowsArchiveRestageAuthority::kPortableExactCaller,
            GetCurrentProcess()),
        std::runtime_error);
    EXPECT_EQ("signed-archive-payload",
              ReadBytes(live_path / L"bin" / L"example.exe"));
    std::vector<UniqueWindowsHandle> retained_handles;
    EXPECT_EQ(live_seal,
              SealWindowsPayloadTree(
                  live.parent_handle(), live_path.filename().wstring(),
                  "com.example.app", descriptor_sha256, artifact_sha256,
                  &retained_handles)
                  .sha256);
  }

  std::error_code ignored;
  std::filesystem::remove_all(root, ignored);
}

}  // namespace
}  // namespace desktop_updater::helper
