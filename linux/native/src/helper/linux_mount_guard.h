#ifndef DESKTOP_UPDATER_LINUX_HELPER_LINUX_MOUNT_GUARD_H_
#define DESKTOP_UPDATER_LINUX_HELPER_LINUX_MOUNT_GUARD_H_

#include <sys/types.h>

#include <cstdint>
#include <stdexcept>
#include <string>

namespace desktop_updater::helper {

class LinuxMountGuardError : public std::runtime_error {
 public:
  explicit LinuxMountGuardError(const std::string& detail)
      : std::runtime_error(detail) {}
};

class UniqueLinuxFd {
 public:
  explicit UniqueLinuxFd(int fd = -1) : fd_(fd) {}
  ~UniqueLinuxFd();
  UniqueLinuxFd(const UniqueLinuxFd&) = delete;
  UniqueLinuxFd& operator=(const UniqueLinuxFd&) = delete;
  UniqueLinuxFd(UniqueLinuxFd&& other) noexcept;
  UniqueLinuxFd& operator=(UniqueLinuxFd&& other) noexcept;

  int get() const { return fd_; }
  bool valid() const { return fd_ >= 0; }
  int release();
  void reset(int fd = -1);

 private:
  int fd_;
};

struct LinuxFileIdentity {
  std::uint64_t device = 0;
  std::uint64_t inode = 0;
  std::uint64_t mount_id = 0;
  std::uint32_t mode = 0;
  std::uint32_t uid = 0;
  std::uint32_t gid = 0;
  std::uint64_t link_count = 0;
  bool directory = false;

  bool operator==(const LinuxFileIdentity& other) const;
  bool operator!=(const LinuxFileIdentity& other) const {
    return !(*this == other);
  }
};

void ValidateLinuxLeaf(const std::string& leaf);
UniqueLinuxFd OpenLinuxDirectory(const std::string& path);
UniqueLinuxFd OpenLinuxRelativeNoFollow(int parent,
                                       const std::string& leaf,
                                       int flags,
                                       mode_t mode = 0);
LinuxFileIdentity ReadLinuxFileIdentity(int fd);
LinuxFileIdentity ReadLinuxRelativeIdentity(int parent,
                                           const std::string& leaf);
bool LinuxRelativeExistsNoFollow(int parent, const std::string& leaf);
void ValidateLinuxIdentity(int fd,
                           const LinuxFileIdentity& retained,
                           const char* detail);
void ValidateLinuxMountRelationship(const LinuxFileIdentity& parent,
                                    const LinuxFileIdentity& child,
                                    const char* detail);

class LinuxMountGuard {
 public:
  LinuxMountGuard(int parent, int target, int stage);

  const LinuxFileIdentity& parent_identity() const { return parent_; }
  const LinuxFileIdentity& target_identity() const { return target_; }
  const LinuxFileIdentity& stage_identity() const { return stage_; }

  void Validate(int parent, int target, int stage) const;

 private:
  LinuxFileIdentity parent_;
  LinuxFileIdentity target_;
  LinuxFileIdentity stage_;
};

}  // namespace desktop_updater::helper

#endif  // DESKTOP_UPDATER_LINUX_HELPER_LINUX_MOUNT_GUARD_H_
