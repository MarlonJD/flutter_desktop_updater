#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "linux_mount_guard.h"

#include <fcntl.h>
#include <linux/stat.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cerrno>
#include <fstream>
#include <sstream>
#include <utility>
#include <vector>

namespace desktop_updater::helper {
namespace {

std::uint64_t MountIdFromFdInfo(int fd) {
  std::ifstream input("/proc/self/fdinfo/" + std::to_string(fd));
  std::string line;
  while (std::getline(input, line)) {
    if (line.rfind("mnt_id:", 0) == 0) {
      std::istringstream value(line.substr(7));
      std::uint64_t mount_id = 0;
      if (value >> mount_id) return mount_id;
    }
  }
  throw LinuxMountGuardError("mount identity unavailable from fdinfo");
}

void RequireKnownMountId(std::uint64_t mount_id) {
  std::ifstream input("/proc/self/mountinfo");
  if (!input) {
    throw LinuxMountGuardError("/proc/self/mountinfo unavailable");
  }
  std::string line;
  while (std::getline(input, line)) {
    std::istringstream fields(line);
    std::uint64_t observed = 0;
    if (fields >> observed && observed == mount_id) return;
  }
  throw LinuxMountGuardError("descriptor mount ID is absent from mountinfo");
}

std::vector<std::string> PathComponents(const std::string& path,
                                        bool absolute) {
  if (path.empty() || path.find('\0') != std::string::npos ||
      (absolute && path.front() != '/') ||
      (!absolute && path.front() == '/')) {
    throw LinuxMountGuardError("directory path rejected");
  }
  std::vector<std::string> components;
  std::size_t start = absolute ? 1 : 0;
  while (start < path.size()) {
    const std::size_t end = path.find('/', start);
    const std::string component =
        path.substr(start, end == std::string::npos ? std::string::npos
                                                   : end - start);
    if (component.empty() || component == "." || component == "..") {
      throw LinuxMountGuardError("directory path component rejected");
    }
    components.push_back(component);
    if (end == std::string::npos) break;
    start = end + 1;
  }
  return components;
}

UniqueLinuxFd DuplicateDirectory(int fd) {
  const int duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 0);
  if (duplicate < 0) {
    throw LinuxMountGuardError("directory descriptor duplication failed");
  }
  UniqueLinuxFd result(duplicate);
  if (!ReadLinuxFileIdentity(result.get()).directory) {
    throw LinuxMountGuardError("directory descriptor rejected");
  }
  return result;
}

UniqueLinuxFd OpenDirectoryComponents(int root,
                                      const std::vector<std::string>& components,
                                      bool reject_mount_change) {
  UniqueLinuxFd current = DuplicateDirectory(root);
  const LinuxFileIdentity root_identity = ReadLinuxFileIdentity(current.get());
  for (const std::string& component : components) {
    const int next = openat(current.get(), component.c_str(),
                            O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (next < 0) {
      throw LinuxMountGuardError("directory component pin failed");
    }
    UniqueLinuxFd retained(next);
    const LinuxFileIdentity identity = ReadLinuxFileIdentity(retained.get());
    if (!identity.directory) {
      throw LinuxMountGuardError("pinned path component is not a directory");
    }
    if (reject_mount_change) {
      ValidateLinuxMountRelationship(
          root_identity, identity,
          "directory traversal crossed a mount boundary");
    }
    current = std::move(retained);
  }
  return current;
}

}  // namespace

UniqueLinuxFd::~UniqueLinuxFd() { reset(); }

UniqueLinuxFd::UniqueLinuxFd(UniqueLinuxFd&& other) noexcept
    : fd_(other.release()) {}

UniqueLinuxFd& UniqueLinuxFd::operator=(UniqueLinuxFd&& other) noexcept {
  if (this != &other) reset(other.release());
  return *this;
}

int UniqueLinuxFd::release() {
  const int result = fd_;
  fd_ = -1;
  return result;
}

void UniqueLinuxFd::reset(int fd) {
  if (fd_ >= 0) close(fd_);
  fd_ = fd;
}

bool LinuxFileIdentity::operator==(const LinuxFileIdentity& other) const {
  return device == other.device && inode == other.inode &&
         mount_id == other.mount_id && mode == other.mode && uid == other.uid &&
         gid == other.gid && link_count == other.link_count &&
         directory == other.directory;
}

void ValidateLinuxLeaf(const std::string& leaf) {
  if (leaf.empty() || leaf == "." || leaf == ".." ||
      leaf.find('/') != std::string::npos ||
      leaf.find('\0') != std::string::npos) {
    throw LinuxMountGuardError("expected one derived path component");
  }
}

UniqueLinuxFd OpenLinuxDirectory(const std::string& path) {
  UniqueLinuxFd filesystem_root(
      open("/", O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
  if (!filesystem_root.valid()) {
    throw LinuxMountGuardError("filesystem root pin failed");
  }
  return OpenDirectoryComponents(
      filesystem_root.get(), PathComponents(path, true), false);
}

UniqueLinuxFd OpenLinuxDirectoryBeneath(int root,
                                       const std::string& relative_path) {
  if (relative_path == ".") return DuplicateDirectory(root);
  return OpenDirectoryComponents(
      root, PathComponents(relative_path, false), true);
}

UniqueLinuxFd OpenLinuxRelativeNoFollow(int parent,
                                       const std::string& leaf,
                                       int flags,
                                       mode_t mode) {
  ValidateLinuxLeaf(leaf);
  const int fd = openat(parent, leaf.c_str(), flags | O_NOFOLLOW | O_CLOEXEC,
                        mode);
  if (fd < 0) throw LinuxMountGuardError("openat no-follow failed");
  UniqueLinuxFd result(fd);
  const auto identity = ReadLinuxFileIdentity(fd);
  if ((identity.mode & S_IFMT) == S_IFLNK) {
    throw LinuxMountGuardError("symbolic link rejected");
  }
  return result;
}

LinuxFileIdentity ReadLinuxFileIdentity(int fd) {
  struct stat status {};
  if (fstat(fd, &status) != 0) {
    throw LinuxMountGuardError("fstat failed");
  }
  std::uint64_t mount_id = 0;
#ifdef STATX_MNT_ID
  struct statx extended {};
  if (statx(fd, "", AT_EMPTY_PATH | AT_SYMLINK_NOFOLLOW,
            STATX_BASIC_STATS | STATX_MNT_ID, &extended) == 0 &&
      (extended.stx_mask & STATX_MNT_ID) != 0) {
    mount_id = extended.stx_mnt_id;
  }
#endif
  if (mount_id == 0) mount_id = MountIdFromFdInfo(fd);
  RequireKnownMountId(mount_id);
  return {
      static_cast<std::uint64_t>(status.st_dev),
      static_cast<std::uint64_t>(status.st_ino),
      mount_id,
      static_cast<std::uint32_t>(status.st_mode),
      static_cast<std::uint32_t>(status.st_uid),
      static_cast<std::uint32_t>(status.st_gid),
      static_cast<std::uint64_t>(status.st_nlink),
      S_ISDIR(status.st_mode),
  };
}

LinuxFileIdentity ReadLinuxRelativeIdentity(int parent,
                                           const std::string& leaf) {
  auto handle = OpenLinuxRelativeNoFollow(parent, leaf, O_PATH);
  return ReadLinuxFileIdentity(handle.get());
}

bool LinuxRelativeExistsNoFollow(int parent, const std::string& leaf) {
  ValidateLinuxLeaf(leaf);
  struct stat status {};
  if (fstatat(parent, leaf.c_str(), &status, AT_SYMLINK_NOFOLLOW) == 0) {
    return true;
  }
  if (errno == ENOENT) return false;
  throw LinuxMountGuardError("fstatat existence check failed");
}

void ValidateLinuxIdentity(int fd,
                           const LinuxFileIdentity& retained,
                           const char* detail) {
  if (ReadLinuxFileIdentity(fd) != retained) {
    throw LinuxMountGuardError(detail);
  }
}

void ValidateLinuxMountRelationship(const LinuxFileIdentity& parent,
                                    const LinuxFileIdentity& child,
                                    const char* detail) {
  if (parent.device != child.device || parent.mount_id != child.mount_id) {
    throw LinuxMountGuardError(detail);
  }
}

LinuxMountGuard::LinuxMountGuard(int parent, int target, int stage)
    : parent_(ReadLinuxFileIdentity(parent)),
      target_(ReadLinuxFileIdentity(target)),
      stage_(ReadLinuxFileIdentity(stage)) {
  if (!parent_.directory) {
    throw LinuxMountGuardError("target parent is not a directory");
  }
  ValidateLinuxMountRelationship(parent_, target_,
                                 "target is a mount point or bind mount");
  ValidateLinuxMountRelationship(parent_, stage_,
                                 "stage is a mount point or bind mount");
}

void LinuxMountGuard::Validate(int parent, int target, int stage) const {
  ValidateLinuxIdentity(parent, parent_, "target parent identity changed");
  ValidateLinuxIdentity(target, target_, "target identity or permissions changed");
  ValidateLinuxIdentity(stage, stage_, "stage identity or permissions changed");
  ValidateLinuxMountRelationship(parent_, ReadLinuxFileIdentity(target),
                                 "target mount changed");
  ValidateLinuxMountRelationship(parent_, ReadLinuxFileIdentity(stage),
                                 "stage mount changed");
}

}  // namespace desktop_updater::helper
