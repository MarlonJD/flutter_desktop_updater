#!/bin/sh
set -eu

if [ "$#" -ne 2 ] || [ "$1" != "--mode" ]; then
  echo "usage: $0 --mode unprivileged|root-broker" >&2
  exit 64
fi

mode=$2
case "$mode" in
  unprivileged)
    if [ "$(id -u)" -eq 0 ]; then
      echo "unprivileged smoke must not run as root" >&2
      exit 77
    fi
    helper=${DESKTOP_UPDATER_LINUX_HELPER:-linux/native/build/desktop-updater-helper}
    test -x "$helper"
    "$helper" --version
    ;;
  root-broker)
    test "$(id -u)" -eq 0
    helper=/usr/libexec/desktop-updater-helper
    test -x "$helper"
    test "$(stat -c %u "$helper")" -eq 0
    mode_bits=$(stat -c %a "$helper")
    case "$mode_bits" in
      *[2367][0-9]|*[0-9][2367])
        echo "installed helper is group/world writable" >&2
        exit 77
        ;;
    esac
    test -d /etc/desktop-updater/policies
    command -v pkcheck >/dev/null
    "$helper" --version
    ;;
  *)
    echo "unknown smoke mode: $mode" >&2
    exit 64
    ;;
esac
