#!/usr/bin/env bash
# Exercise pinned rCore-Tutorial ch2 with current RustSBI Prototyper.
# The guest patch below is an explicit compatibility adapter, NOT unmodified upstream.
set -euo pipefail

if (( $# != 1 )) || [[ $1 != sbi && $1 != u-boot ]]; then
  echo "Usage: $0 <sbi|u-boot>" >&2
  exit 2
fi
readonly BOOT_MODE=$1
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

readonly TUTORIAL_COMMIT=fc4af3367b7feebb2287b15fe3ff23757471e571
readonly TUTORIAL_REPO="${RCORE_TUTORIAL_REPO:-https://github.com/rcore-os/rCore-Tutorial-v3.git}"
readonly UBOOT_VERSION=2025.10-0ubuntu0.24.04.3
readonly UBOOT_DEB="u-boot-qemu_${UBOOT_VERSION}_all.deb"
readonly UBOOT_URL="https://security.ubuntu.com/ubuntu/pool/main/u/u-boot/${UBOOT_DEB}"
readonly UBOOT_SHA256=852a1f5d4a5d00a3a63f694a4bf46744f02737f5ffdea091666ee44d784f5eba
readonly CACHE_DIR="${RCORE_TUTORIAL_CACHE_DIR:-target/rcore-tutorial/cache}"
readonly LOG_DIR="${QEMU_LOG_DIR:-qemu-logs}"
readonly RUN_ROOT="${RCORE_TUTORIAL_RUN_DIR:-${TMPDIR:-/tmp}/rustsbi-rcore-tutorial}"
readonly FIRMWARE="${RCORE_TUTORIAL_RUSTSBI:-target/riscv64gc-unknown-none-elf/release/rustsbi-prototyper-dynamic.bin}"
readonly BOOT_SCRIPT=.github/scripts/prototyper-rcore-tutorial-boot.py
readonly LOCKS=.github/fixtures/rcore-tutorial-ch2
readonly GUEST_TOOLCHAIN=1.94.0

mkdir -p "$CACHE_DIR" "$RUN_ROOT" "$LOG_DIR"
TEMP_DIR="$(mktemp -d "${RUN_ROOT}/ch2.${BOOT_MODE}.XXXXXX")"
readonly TEMP_DIR
trap 'rm -rf -- "$TEMP_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
readonly SRC="${TEMP_DIR}/source"

git init --quiet "$SRC"
git -C "$SRC" fetch --quiet --depth=1 "$TUTORIAL_REPO" "$TUTORIAL_COMMIT"
git -C "$SRC" checkout --quiet --detach FETCH_HEAD
if [[ $(git -C "$SRC" rev-parse HEAD) != "$TUTORIAL_COMMIT" ]]; then
  echo "Unexpected rCore-Tutorial commit" >&2
  exit 1
fi

# The pinned upstream ch2 kernel uses SBI Legacy EID 0x01 for every byte.
# The current RustSBI Prototyper deliberately has no Legacy extensions.
# Adapt ONLY this one console write at build time to standard DBCN write_byte
# (EID 0x4442434E / FID 2), and keep its original userspace/tests untouched.
# A missing/mutated source snippet MUST fail rather than silently skip the patch.
python3 - "$SRC/os/src/sbi.rs" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = '    #[allow(deprecated)]\n    sbi_rt::legacy::console_putchar(c);'
new = '''    // Test-guest compatibility shim: SBI DBCN write_byte, not Legacy putchar.
    unsafe {
        core::arch::asm!(
            "ecall",
            inlateout("a0") c => _,
            lateout("a1") _,
            in("a6") 2usize,
            in("a7") 0x4442434Eusize,
        );
    }'''
if s.count(old) != 1:
    raise SystemExit('Pinned rCore-Tutorial guest changed: refusing to adapt')
p.write_text(s.replace(old, new))
print('Applied pinned single-call Legacy-to-DBCN test-guest shim')
PY

# Upstream does not commit ch2 Cargo.lock, so provide reviewed, immutable
# resolved dependency locks instead of allowing CI to resolve floating versions.
cp "$LOCKS/user.Cargo.lock" "$SRC/user/Cargo.lock"
cp "$LOCKS/os.Cargo.lock" "$SRC/os/Cargo.lock"
export RUSTUP_TOOLCHAIN="$GUEST_TOOLCHAIN"
cargo --version
rustup target list --installed | grep -F 'riscv64gc-unknown-none-elf'
(cd "$SRC/user" && cargo build --release --locked)
make -C "$SRC/user" binary
cp "$SRC/os/src/linker-qemu.ld" "$SRC/os/src/linker.ld"
(cd "$SRC/os" && cargo build --release --locked)
readonly KERNEL="${SRC}/os/target/riscv64gc-unknown-none-elf/release/os.bin"
rust-objcopy "$SRC/os/target/riscv64gc-unknown-none-elf/release/os" --strip-all -O binary "$KERNEL"
test -s "$KERNEL"
test -s "$FIRMWARE"

UBOOT_ELF=""
verify_sha256() {
  python3 - "$1" "$2" <<'PYHASH'
import hashlib, sys
h = hashlib.sha256()
with open(sys.argv[2], "rb") as f:
    for block in iter(lambda: f.read(1024 * 1024), b""):
        h.update(block)
sys.exit(0 if h.hexdigest() == sys.argv[1] else 1)
PYHASH
}
if [[ $BOOT_MODE = u-boot ]]; then
  readonly PKG="${CACHE_DIR}/${UBOOT_DEB}"
  if [[ ! -f "$PKG" ]] || ! verify_sha256 "$UBOOT_SHA256" "$PKG"; then
    readonly TEMP_PKG="${PKG}.part.$$"
    trap 'rm -f -- "$TEMP_PKG"; rm -rf -- "$TEMP_DIR"' EXIT
    curl --fail --location --connect-timeout 30 --max-time 240 --retry 3 \
      --retry-all-errors --retry-max-time 240 "$UBOOT_URL" -o "$TEMP_PKG"
    verify_sha256 "$UBOOT_SHA256" "$TEMP_PKG"
    mv "$TEMP_PKG" "$PKG"
    trap 'rm -rf -- "$TEMP_DIR"' EXIT
  fi
  mkdir -p "$TEMP_DIR/uboot"
  if command -v dpkg-deb >/dev/null; then
    dpkg-deb -x "$PKG" "$TEMP_DIR/uboot"
  else
    PKG_ABS="$(pwd)/$PKG"
    (cd "$TEMP_DIR/uboot"; bsdtar -xf "$PKG_ABS" data.tar.zst; bsdtar -xf data.tar.zst)
  fi
  UBOOT_ELF="$TEMP_DIR/uboot/usr/lib/u-boot/qemu-riscv64_smode/uboot.elf"
  test -s "$UBOOT_ELF"
fi

{
  echo "source=rcore-os/rCore-Tutorial-v3"
  echo "revision=$TUTORIAL_COMMIT"
  echo "guest_unmodified=false"
  echo "guest_compatibility=replace legacy console_putchar with SBI DBCN write_byte"
  echo "guest_rust_toolchain=$GUEST_TOOLCHAIN"
  echo "mode=$BOOT_MODE"
  echo "qemu=$(qemu-system-riscv64 --version | head -1)"
  sha256sum "$LOCKS/user.Cargo.lock" "$LOCKS/os.Cargo.lock" "$KERNEL" "$FIRMWARE"
  if [[ $BOOT_MODE = u-boot ]]; then sha256sum "$CACHE_DIR/$UBOOT_DEB" "$UBOOT_ELF"; fi
} > "$LOG_DIR/rcore-ch2-${BOOT_MODE}-provenance.log"

python3 "$BOOT_SCRIPT" "$BOOT_MODE" --firmware "$FIRMWARE" --kernel "$KERNEL" \
  --uboot "$UBOOT_ELF" --logs "$LOG_DIR" --timeout "${RCORE_TUTORIAL_BOOT_TIMEOUT:-90}"
