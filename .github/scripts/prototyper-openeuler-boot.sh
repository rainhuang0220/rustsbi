#!/usr/bin/env bash
# RustSBI dynamic firmware -> EDK II -> the unmodified openEuler disk.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly BASE_URL=https://repo.openeuler.org/openEuler-25.09/virtual_machine_img/riscv64
readonly IMAGE_NAME=openEuler-25.09-riscv64.qcow2
# Published in the official .xz.sha256sum file in BASE_URL.
readonly IMAGE_SHA256=5ba2eb5f0dac1594e8e041e36125fc6e5a2bd4547b4039258e5bd5139fa067ba
# Fixed release firmware from the same directory, also used by the AIA test.
readonly CODE_SHA256=58e96e55744516ed5debff8ed90eaface7b8a51a9466e7c0a687f4025ed5c600
readonly VARS_SHA256=ea8094e953b1215444bd001ee1cf22818f1f7f8abcb158e62180cbaa6c1f70af
CACHE_DIR=${OPENEULER_CACHE_DIR:-target/openeuler-boot/cache}
WORK_DIR=${OPENEULER_WORK_DIR:-target/openeuler-boot/work}
LOG_DIR=${QEMU_LOG_DIR:-qemu-logs}
LOG_FILE="$LOG_DIR/prototyper-openeuler-edk2.log"
RUSTSBI=target/riscv64gc-unknown-none-elf/release/rustsbi-prototyper-dynamic.bin
QEMU=qemu-system-riscv64
BOOT_TIMEOUT_SECS=${OPENEULER_BOOT_TIMEOUT_SECS:-900}
DOWNLOAD_TIMEOUT_SECS=1200
SETTLE_SECS=5
QEMU_PID=
DOWNLOAD_TEMP=
RUN_DIR=
IMAGE_PATH=

cleanup() {
  local i
  if [[ -n "$QEMU_PID" ]]; then
    if kill -0 "$QEMU_PID" 2>/dev/null; then
      kill "$QEMU_PID" 2>/dev/null || true
      for ((i=0; i<5; i++)); do
        kill -0 "$QEMU_PID" 2>/dev/null || break
        sleep 1
      done
      kill -KILL "$QEMU_PID" 2>/dev/null || true
    fi
    wait "$QEMU_PID" 2>/dev/null || true
    QEMU_PID=
  fi
  [[ -z "$DOWNLOAD_TEMP" ]] || rm -f "$DOWNLOAD_TEMP"
  [[ -z "$RUN_DIR" ]] || rm -rf "$RUN_DIR"
}

verify_sha256() {
  # Hash bytes directly: filenames cannot inject checksum-file entries.
  local actual
  actual=$(sha256sum < "$2") || return 1
  [[ "${actual%% *}" = "$1" ]]
}

download_asset() {
  local url=$1 destination=$2 digest=$3
  if [[ -f "$destination" ]] && verify_sha256 "$digest" "$destination"; then
    echo "Using verified $(basename "$destination")"
    return 0
  fi
  DOWNLOAD_TEMP=$(mktemp "${destination}.part.XXXXXX") || return 1
  curl --fail --location --connect-timeout 30 --max-time "$DOWNLOAD_TIMEOUT_SECS" \
    --retry 2 --retry-all-errors --retry-max-time "$DOWNLOAD_TIMEOUT_SECS" \
    --output "$DOWNLOAD_TEMP" "$url" || return 1
  if ! verify_sha256 "$digest" "$DOWNLOAD_TEMP"; then
    echo "SHA-256 mismatch: $url" >&2
    return 1
  fi
  mv "$DOWNLOAD_TEMP" "$destination" || return 1
  DOWNLOAD_TEMP=
}

prepare_assets() {
  download_asset "$BASE_URL/$IMAGE_NAME.xz" "$CACHE_DIR/$IMAGE_NAME.xz" "$IMAGE_SHA256"
  download_asset "$BASE_URL/RISCV_VIRT_CODE.fd" "$CACHE_DIR/RISCV_VIRT_CODE.fd" "$CODE_SHA256"
  download_asset "$BASE_URL/RISCV_VIRT_VARS.fd" "$CACHE_DIR/RISCV_VIRT_VARS.fd" "$VARS_SHA256"
  # Always extract verified bytes into a fresh run directory; never trust an
  # unverified, previously extracted image from cache. The base is disposable.
  IMAGE_PATH="$RUN_DIR/$IMAGE_NAME"
  timeout --foreground 300 xz -dc "$CACHE_DIR/$IMAGE_NAME.xz" > "$IMAGE_PATH"
  chmod a-w "$IMAGE_PATH"
  cp "$CACHE_DIR/RISCV_VIRT_VARS.fd" "$RUN_DIR/RISCV_VIRT_VARS.fd"
  qemu-img create -q -f qcow2 -F qcow2 -b "$IMAGE_PATH" "$RUN_DIR/overlay.qcow2"
}

start_qemu() {
  local -a args=(
    -machine 'virt,pflash0=pflash0,pflash1=pflash1,acpi=off'
    -accel tcg -smp 4 -m 4G -display none -monitor none -no-reboot
    -bios "$RUSTSBI"
    -blockdev "node-name=pflash0,driver=file,read-only=on,filename=$CACHE_DIR/RISCV_VIRT_CODE.fd"
    -blockdev "node-name=pflash1,driver=file,filename=$RUN_DIR/RISCV_VIRT_VARS.fd"
    -drive "file=$RUN_DIR/overlay.qcow2,format=qcow2,id=hd0,if=none"
    -device 'virtio-blk-device,drive=hd0'
    -device virtio-rng-device
    -serial "file:$LOG_FILE"
  )
  # Only the guest UART writes LOG_FILE. Host commands, paths and QEMU stderr
  # cannot supply boot evidence, and a previous run's log is never reused.
  : > "$LOG_FILE"
  {
    printf 'QEMU command: '
    printf '%q ' "$QEMU" "${args[@]}"
    printf '\n'
  } >> "$LOG_DIR/prototyper-openeuler-metadata.log"
  "$QEMU" "${args[@]}" </dev/null > "$LOG_DIR/prototyper-openeuler-qemu.log" 2>&1 &
  QEMU_PID=$!
}

check_serial() {
  # Return 0 for the complete ordered chain, 1 while booting, 2 on fatal error.
  # openEuler requires an authenticated login. No password or guest changes are
  # introduced: getty is the same minimum userspace milestone as the AIA CI.
  awk '
    {
      gsub(/\r/, "")
      gsub(/\033\[[0-?]*[ -\/]*[@-~]/, "")
      if (/Kernel panic|not syncing|VFS: Unable to mount root fs|Cannot open root device|Attempted to kill init|panicked at|Synchronous Exception|Unhandled exception|grub rescue>|No bootable device|SystemFailure|Invalid data in dynamic/) fatal=1
      if (stage == 0 && /^\[RustSBI\].*Hello RustSBI!$/) stage=1
      if (stage == 1 && /^\[RustSBI\].*Platform IPI Extension *: SiFiveClint /) clint=1
      if (stage == 1 && /^\[RustSBI\].*Redirecting hart [0-9]+ to 0x00000020000000 in Supervisor mode\.$/) handoff=1
      if (stage == 1 && /^RISC-V EDK2 firmware version 2\.7$/) stage=2
      if (stage == 2 && /^Loading Linux 6\.6\.0-102\.0\.0\.5\.oe2509\.riscv64 /) loading=1
      if (stage == 2 && /^Loading initial ramdisk /) initrd=1
      # The release grub.cfg uses quiet. Kernel task/timestamp lines and the
      # getty kernel/architecture banner remain visible without changing it.
      if (stage == 2 && loading && initrd && /^\[ *[0-9.]+\]\[ *T[0-9]+\] /) stage=3
      if (stage == 3 && /^(Welcome to )?openEuler 25\.09$/) distro=1
      if (stage == 3 && distro && /^Kernel 6\.6\.0-102\.0\.0\.5\.oe2509\.riscv64 on an riscv64$/) kernel=1
      if (stage == 3 && kernel && /^localhost login: *$/) login=1
    }
    END { if (fatal) exit 2; exit !(stage == 3 && clint && handoff && distro && kernel && login) }
  ' "$LOG_FILE"
}

wait_for_guest() {
  local deadline=$((SECONDS + BOOT_TIMEOUT_SECS)) ready_at=0 result qemu_exit
  while (( SECONDS < deadline )); do
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
      qemu_exit=0
      wait "$QEMU_PID" || qemu_exit=$?
      QEMU_PID=
      echo "QEMU exited before acceptance (exit=$qemu_exit)" >&2
      return 1
    fi
    result=0
    check_serial || result=$?
    if (( result == 2 )); then
      echo 'Fatal firmware, kernel or RootFS error in guest serial log' >&2
      return 1
    elif (( result == 0 )); then
      if (( ready_at == 0 )); then ready_at=$SECONDS; fi
      if (( SECONDS - ready_at >= SETTLE_SECS )); then
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        return 0
      fi
    else
      ready_at=0
    fi
    sleep 1
  done
  echo "openEuler boot timed out after ${BOOT_TIMEOUT_SECS}s" >&2
  return 1
}

main() {
  if [[ ! "$BOOT_TIMEOUT_SECS" =~ ^[1-9][0-9]*$ ]] || (( BOOT_TIMEOUT_SECS > 1800 )); then
    echo 'OPENEULER_BOOT_TIMEOUT_SECS must be an integer in 1..1800' >&2
    return 2
  fi
  cd "$SCRIPT_DIR/../.."
  # QEMU keyval paths use comma separators; reject ambiguous overrides.
  for path in "$CACHE_DIR" "$WORK_DIR" "$LOG_DIR"; do
    [[ "$path" != *','* && "$path" != *$'\n'* ]] || {
      echo 'Directory paths must not contain commas or newlines' >&2
      return 2
    }
  done
  mkdir -p "$CACHE_DIR" "$WORK_DIR" "$LOG_DIR"
  CACHE_DIR=$(realpath "$CACHE_DIR")
  LOG_DIR=$(realpath "$LOG_DIR")
  LOG_FILE="$LOG_DIR/prototyper-openeuler-edk2.log"
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  test -s "$RUSTSBI" || {
    echo "Missing $RUSTSBI; run cargo prototyper build first" >&2
    return 1
  }
  RUN_DIR=$(mktemp -d "$(realpath "$WORK_DIR")/edk2.XXXXXX")
  {
    printf 'RustSBI checkout: '; git rev-parse HEAD
    printf 'CI revision: %s\n' "${GITHUB_SHA:-local}"
    git status --short
    "$QEMU" --version
    sha256sum "$RUSTSBI"
    printf 'Guest URL: %s/%s.xz\n' "$BASE_URL" "$IMAGE_NAME"
    printf 'Serial log: %s\n' "$LOG_FILE"
  } > "$LOG_DIR/prototyper-openeuler-metadata.log"
  prepare_assets
  sha256sum "$CACHE_DIR/$IMAGE_NAME.xz" "$CACHE_DIR/"*.fd >> "$LOG_DIR/prototyper-openeuler-metadata.log"
  start_qemu
  if ! wait_for_guest; then
    tail -n 160 "$LOG_FILE" "$LOG_DIR/prototyper-openeuler-qemu.log" >&2 || true
    return 1
  fi
  # Stop QEMU, then reject fatal errors emitted during the shutdown race too.
  cleanup
  check_serial
  tail -n 80 "$LOG_FILE"
  echo "RustSBI -> EDK II -> openEuler 25.09 userspace (serial login): $LOG_FILE"
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
  case "${1:-edk2}" in
    --self-test) exec bash "$SCRIPT_DIR/prototyper-openeuler-boot-test.sh" ;;
    edk2) (( $# <= 1 )) || exit 2; main ;;
    *) echo "Usage: $0 [edk2|--self-test]" >&2; exit 2 ;;
  esac
fi
