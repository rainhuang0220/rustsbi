#!/usr/bin/env bash
# Offline process/serial fixtures; these are NOT QEMU or guest boot results.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ ! -f "$SCRIPT_DIR/prototyper-openeuler-boot.sh" ]]; then
  echo 'FAIL: openEuler boot implementation is missing' >&2
  exit 1
fi
# shellcheck source=prototyper-openeuler-boot.sh
source "$SCRIPT_DIR/prototyper-openeuler-boot.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

fixture() {
  local scenario=$1
  [[ "$scenario" = missing-rustsbi ]] || printf '\033[1;37m[RustSBI] \033[1;32mINFO \033[0m - Hello RustSBI!\n'
  printf '[RustSBI] INFO - Platform IPI Extension        : SiFiveClint (Base Address: 0x2000000)\n'
  printf '[RustSBI] INFO - Redirecting hart 0 to 0x00000020000000 in Supervisor mode.\n'
  [[ "$scenario" = missing-edk2 ]] || printf 'RISC-V EDK2 firmware version 2.7\n'
  printf 'Loading Linux 6.6.0-102.0.0.5.oe2509.riscv64 ...\nLoading initial ramdisk ...\n'
  [[ "$scenario" = missing-linux ]] || printf '[    4.982194][    T1] integrity: Unable to open file: /etc/keys/x509_ima.der (-2)\n'
  [[ "$scenario" != linux-only ]] || return 0
  [[ "$scenario" != early-login ]] || printf '\nlocalhost login: \n'
  if [[ "$scenario" = wrong-version ]]; then
    printf 'Welcome to openEuler 24.03\n'
  else
    printf 'Welcome to openEuler 25.09\n'
  fi
  printf 'Kernel 6.6.0-102.0.0.5.oe2509.riscv64 on an riscv64\n'
  case "$scenario" in
    panic) printf 'Kernel panic - not syncing: test\n' ;;
    rootfs) printf 'VFS: Unable to mount root fs on unknown-block(0,0)\n' ;;
    injected) printf 'echo localhost login:\n'; return 0 ;;
    marker-only) printf 'RUSTSBI-OPENEULER-SMOKE-OK\n'; return 0 ;;
    early-login) return 0 ;;
  esac
  printf '\r\nlocalhost login: '
}

serial_case() (
  local scenario=$1 expected=$2 result=0
  LOG_DIR="$TEST_DIR/$scenario"
  mkdir -p "$LOG_DIR"
  LOG_FILE="$LOG_DIR/serial.log"
  BOOT_TIMEOUT_SECS=4
  SETTLE_SECS=1
  RUN_DIR=$(mktemp -d "$TEST_DIR/run.XXXXXX")
  trap cleanup EXIT
  : > "$LOG_FILE"
  if [[ "$scenario" = stale-log ]]; then
    fixture success > "$LOG_FILE"
    # start_qemu must truncate an earlier run's serial evidence.
    QEMU=/usr/bin/true
    RUSTSBI=/dev/null
    start_qemu
  else
    (
      [[ "$scenario" != timeout ]] || exec sleep 20
      fixture "$scenario"
      [[ "$scenario" != early-exit ]] || exit 0
      if [[ "$scenario" = late-panic ]]; then
        sleep 0.5
        printf '\nKernel panic - not syncing: after login\n'
      fi
      exec sleep 20
    ) > "$LOG_FILE" &
    QEMU_PID=$!
  fi
  wait_for_guest > "$LOG_DIR/result.txt" 2>&1 || result=$?
  if [[ "$expected" = pass && "$result" != 0 ]] ||
     [[ "$expected" = fail && "$result" = 0 ]]; then
    cat "$LOG_DIR/result.txt" "$LOG_FILE" >&2
    echo "FAIL: $scenario (expected $expected, exit $result)" >&2
    exit 1
  fi
  local pid=$QEMU_PID run=$RUN_DIR
  cleanup
  [[ ! -d "$run" && -f "$LOG_FILE" ]]
  [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null
  echo "PASS: $scenario ($expected, process cleaned, log retained)"
)

download_case() (
  local scenario=$1 result=0
  RUN_DIR=$(mktemp -d "$TEST_DIR/download.XXXXXX")
  trap cleanup EXIT
  printf 'verified asset\n' > "$RUN_DIR/source"
  local digest destination="$RUN_DIR/asset"
  digest=$(sha256sum "$RUN_DIR/source")
  digest=${digest%% *}
  if [[ "$scenario" = bad-digest ]]; then digest=$(printf '%064d' 0); fi
  if [[ "$scenario" = interrupted ]]; then
    # Model curl's partial-write/error boundary, not its HTTP implementation.
    # shellcheck disable=SC2329 # Called indirectly by download_asset.
    curl() {
      while [[ "$1" != --output ]]; do shift; done
      printf partial > "$2"
      return 18
    }
  fi
  download_asset "file://$RUN_DIR/source" "$destination" "$digest" || result=$?
  if [[ "$scenario" = success ]]; then
    [[ "$result" = 0 ]]
    cmp "$RUN_DIR/source" "$destination"
    # Corrupt cache must be revalidated and replaced, never accepted by size.
    printf corrupt > "$destination"
    download_asset "file://$RUN_DIR/source" "$destination" "$digest"
    cmp "$RUN_DIR/source" "$destination"
  else
    [[ "$result" != 0 && ! -f "$destination" ]]
  fi
  local temporary=$DOWNLOAD_TEMP run=$RUN_DIR
  cleanup
  [[ ! -d "$run" ]]
  [[ -z "$temporary" || ! -f "$temporary" ]]
  echo "PASS: download $scenario (verification and cleanup)"
)

for scenario in success missing-rustsbi missing-edk2 missing-linux linux-only marker-only \
  injected early-login panic rootfs early-exit timeout late-panic stale-log wrong-version; do
  expected=fail
  [[ "$scenario" != success ]] || expected=pass
  serial_case "$scenario" "$expected"
done
for scenario in success bad-digest interrupted; do download_case "$scenario"; done
echo 'Offline openEuler self-tests passed; no guest boot was performed.'
