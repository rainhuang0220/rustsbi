#!/usr/bin/env bash
# Pin and boot all nine rCore-Tutorial v3 chapter kernels through current RustSBI.
# This is one sequential CI job. Guest-only compatibility shims are explicitly recorded.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

readonly REPO="${RCORE_TUTORIAL_REPO:-https://github.com/rcore-os/rCore-Tutorial-v3.git}"
readonly FIRMWARE="${RCORE_TUTORIAL_RUSTSBI:-target/riscv64gc-unknown-none-elf/release/rustsbi-prototyper-dynamic.bin}"
readonly LOG_DIR="${QEMU_LOG_DIR:-qemu-logs/rcore-tutorial}"
readonly PYTHON=.github/scripts/prototyper-rcore-tutorial-boot.py
readonly TOOLCHAIN=1.94.0

# Snapshot each actual, non-dev upstream chapter, not a mutable branch name.
readonly -a REVISIONS=(
  unused
  85fe952a04c4b671fef1beb2f470591ae7ea5123
  fc4af3367b7feebb2287b15fe3ff23757471e571
  9ca4aedb66f626dcc72f835a5946742a82b61c7c
  f384222b9b5bf33c4eb6b1a87ad5a7a2b8122c79
  a55bd5598a19cd5878af9bd8211540cff48dd4d1
  47bbec297476f0009b8b3ac99fc9fb11743bd837
  af89affce453082c4aacd646b9bd908eba5cee79
  3b1bc659ffdbbe0dcf457ddd81ed45261bf3dc75
  209476f27359b47cd6534ebb91afc5d01692b429
)

if [[ ${1:-} == --self-test ]]; then
  test $# -eq 1
  exec python3 "$PYTHON" self-test
fi
if (( $# == 0 )); then
  CHAPTERS=(1 2 3 4 5 6 7 8 9)
else
  CHAPTERS=("$@")
  for chapter in "${CHAPTERS[@]}"; do
    case "$chapter" in 1|2|3|4|5|6|7|8|9) ;; *)
      echo "Usage: $0 [--self-test|1 ... 9]" >&2; exit 2 ;;
    esac
  done
fi
test -s "$FIRMWARE"
mkdir -p "$LOG_DIR"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rustsbi-rcore-tutorial.XXXXXX")"
readonly WORK
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

readonly SOURCE_REPO="$WORK/repo"
git init --quiet "$SOURCE_REPO"
git -C "$SOURCE_REPO" remote add origin "$REPO"
export RUSTUP_TOOLCHAIN="$TOOLCHAIN"
echo "rCore-Tutorial: one CI item, chapters ${CHAPTERS[*]}, direct SBI only"
echo "Rust toolchain: $(rustc --version); QEMU: $(qemu-system-riscv64 --version | head -1)"

for chapter in "${CHAPTERS[@]}"; do
  sha="${REVISIONS[$chapter]}"
  dir="$WORK/ch$chapter"
  mkdir -p "$dir"
  echo "=== ch$chapter @ $sha ==="

  # Fetch exact commit and unpack tracked source. No edits to the repository.
  git -C "$SOURCE_REPO" fetch --quiet --depth=1 origin "$sha"
  test "$(git -C "$SOURCE_REPO" rev-parse FETCH_HEAD)" = "$sha"
  git -C "$SOURCE_REPO" archive FETCH_HEAD | tar -xf - -C "$dir"
  test -f "$dir/os/Cargo.toml"

  shim=none
  if (( chapter <= 8 )); then
    # These upstream chapters use SBI Legacy console putchar/getchar; current
    # Prototyper does not implement the legacy console extension. This is a
    # TEST-GUEST-ONLY adaptation. Its original user applications are unchanged.
    python3 - "$dir/os/src/sbi.rs" "$chapter" <<'PY_SHIM'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old_out = '    #[allow(deprecated)]\n    sbi_rt::legacy::console_putchar(c);'
new_out = '''    // Test-guest shim: SBI DBCN write_byte EID 0x4442434E / FID 2.
    unsafe {
        core::arch::asm!(
            "ecall",
            inlateout("a0") c => _,
            lateout("a1") _,
            in("a6") 2usize,
            in("a7") 0x4442434Eusize,
        );
    }'''
old_in = '    #[allow(deprecated)]\n    sbi_rt::legacy::console_getchar()'
new_in = '''    // Test-guest shim: poll the standard QEMU NS16550 UART (no SBI DBCN read).
    // A zero byte signals no data, as required by the tutorial stdin driver.
    unsafe {
        if core::ptr::read_volatile(0x1000_0005 as *const u8) & 1 == 0 { 0 }
        else { core::ptr::read_volatile(0x1000_0000 as *const u8) as usize }
    }'''
if s.count(old_out) != 1:
    raise SystemExit('Pinned chapter does not contain the expected legacy putchar')
s = s.replace(old_out, new_out)
if old_in in s:
    if s.count(old_in) != 1: raise SystemExit('Ambiguous legacy getchar')
    s = s.replace(old_in, new_in)
p.write_text(s)
# ch7/ch8 use the Legacy getchar after enabling paging, but their board MMIO
# map lacks the physical UART page. Add only that mapping in the disposable
# test guest so the explicit UART stdin adapter is safe in S-mode.
if int(sys.argv[2]) in (7, 8):
    board = p.parent / "boards/qemu.rs"
    source = board.read_text()
    anchor = "    (0x1000_1000, 0x00_1000), // Virtio Block in virt machine"
    if source.count(anchor) != 1:
        raise SystemExit("Expected tutorial virtio MMIO board definition missing")
    board.write_text(source.replace(
        anchor,
        "    (0x1000_0000, 0x00_1000), // CI guest UART input adapter MMIO\n" + anchor,
    ))
print('Adapted guest Legacy console output/input; guest_unmodified=false')
PY_SHIM
    shim=legacy-to-dbcn-and-uart
  fi
  # ch5/ch6 have finite, self-checking usertests. The later chapters contain
  # long or interactive tests; accept only a live user-shell milestone there.
  test_mode=1
  if (( chapter >= 7 )); then test_mode=0; fi

  if [[ -d "$dir/user" ]]; then
    make -C "$dir/user" build "TEST=$test_mode"
  fi
  cp "$dir/os/src/linker-qemu.ld" "$dir/os/src/linker.ld"
  (cd "$dir/os" && cargo build --release)
  kernel="$dir/os/target/riscv64gc-unknown-none-elf/release/os.bin"
  rust-objcopy "$dir/os/target/riscv64gc-unknown-none-elf/release/os" --strip-all -O binary "$kernel"
  test -s "$kernel"

  if (( chapter >= 6 )); then
    # The generated fs.img belongs only to this disposable checkout and may
    # be written by user tests. Never mount or alter an original guest image.
    make -C "$dir/os" fs-img "TEST=$test_mode"
    fs="$dir/user/target/riscv64gc-unknown-none-elf/release/fs.img"
    test -s "$fs"
  fi

  {
    printf 'source=rcore-os/rCore-Tutorial-v3\nsource_sha=%s\nchapter=%s\n' "$sha" "$chapter"
    printf 'firmware=RustSBI-from-checked-out-revision\nguest_unmodified=%s\n' "$([[ "$shim" == none ]] && echo true || echo false)"
    printf 'guest_console_adapter=%s\ntest_mode=%s\n' "$shim" "$test_mode"
    printf 'rust_toolchain=%s\nqemu=%s\n' "$TOOLCHAIN" "$(qemu-system-riscv64 --version | head -1)"
    shasum -a 256 "$FIRMWARE" "$kernel"
    for lock in "$dir/os/Cargo.lock" "$dir/user/Cargo.lock" "$dir/easy-fs-fuse/Cargo.lock"; do
      if test -f "$lock"; then shasum -a 256 "$lock"; fi
    done
    if (( chapter >= 6 )); then shasum -a 256 "$fs"; fi
  } > "$LOG_DIR/ch$chapter-provenance.log"

  qemu_args=(run --chapter "$chapter" --firmware "$FIRMWARE"
             --kernel "$kernel" --logs "$LOG_DIR"
             --timeout "${RCORE_TUTORIAL_BOOT_TIMEOUT:-75}")
  if (( chapter >= 6 )); then qemu_args+=(--fs "$fs"); fi
  python3 "$PYTHON" "${qemu_args[@]}"
done

echo 'PASS: all requested rCore-Tutorial chapters booted through direct RustSBI'
