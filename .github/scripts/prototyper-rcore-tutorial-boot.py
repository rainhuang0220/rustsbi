#!/usr/bin/env python3
"""One reusable bounded UART acceptance runner for all rCore-Tutorial chapters.

Every successful result comes from the actual QEMU process. --self-test tests
the parser only and never counts as a real guest boot.
"""
import argparse
import json
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import time

ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
FATAL = re.compile(
    r"(?i)(Panicked at|Kernel panic|Synchronous Exception|Unhandled exception|"
    r"Usertests failed!|System shutdown scheduled due to RustSBI panic|"
    r"VFS: Unable to mount root fs)"
)
FW = [
    "Hello RustSBI!",
    "SiFiveClint (Base Address: 0x2000000)",
    "Redirecting hart 0 to 0x00000080200000 in Supervisor mode.",
]
MARKERS = {
    1: ["[kernel] Hello, world!"],
    2: ["[kernel] Hello, world!", "[kernel] num_app = 5", "Test power OK!",
        "All applications completed!"],
    3: ["[kernel]", "Test sleep OK!", "All applications completed!"],
    4: ["[kernel]", "Test sleep OK!", "All applications completed!"],
    5: ["[kernel]", "Usertests passed!", "Idle process exit with exit_code 0"],
    6: ["[kernel]", "found a block device of size", "Usertests passed!",
        "Idle process exit with exit_code 0"],
    7: ["[kernel]", "found a block device of size", "Rust user shell", ">> "],
    8: ["[kernel]", "found a block device of size", "Rust user shell", ">> "],
    9: ["CLOCK_FREQ from device tree:", "KERN: init gpu",
        "KERN: init keyboard", "KERN: init mouse", "found a block device of size",
        "Rust user shell", ">> "],
}
MAX_SERIAL = 3_000_000


def clean(raw):
    return ANSI.sub("", raw.decode("utf-8", errors="replace").replace("\r", ""))


def check_serial(chapter, raw):
    text = clean(raw)
    if len(raw) > MAX_SERIAL:
        return False, "unbounded QEMU serial output"
    if FATAL.search(text):
        return False, "fatal runtime evidence"
    if re.search(r"U-Boot 20\d\d|RISC-V EDK2 firmware|GNU GRUB", text):
        return False, "intermediate bootloader in direct SBI test"
    pos = -1
    for marker in FW + MARKERS[chapter]:
        nxt = text.find(marker, pos + 1)
        if nxt < 0:
            return False, f"missing/out-of-order: {marker}"
        pos = nxt
    return True, f"chapter {chapter} guest milestone reached"


def self_test():
    n = 0
    for chapter in MARKERS:
        lines = FW + MARKERS[chapter]
        good = ("\n".join(lines)).encode("utf-8")
        assert check_serial(chapter, good)[0], chapter
        n += 1
        samples = [
            good.replace(b"Hello RustSBI!", b"Unknown firmware", 1),
            good.replace(b"SiFiveClint (Base Address: 0x2000000)",
                         b"IMSIC (Base Address: 0x24000000)", 1),
            good.replace(b"Supervisor mode.", b"Machine mode.", 1),
            good.replace(MARKERS[chapter][-1].encode(), b"MISSING_END", 1),
            good + b"\nPanicked at src/trap/mod.rs:151\n",
            good + b"\nUsertests failed!\n",
            good + b"\nU-Boot 2025.10\n",
        ]
        swapped = list(lines)
        swapped[-2], swapped[-1] = swapped[-1], swapped[-2]
        samples.append(("\n".join(swapped)).encode())
        for bad in samples:
            ok, explanation = check_serial(chapter, bad)
            if ok:
                raise AssertionError((chapter, "false positive", explanation))
            n += 1
    print(f"PASS: {n} deterministic rCore-Tutorial serial checks", flush=True)


def qemu_args(chapter, firmware, kernel, fs):
    args = [
        "qemu-system-riscv64", "-machine", "virt,acpi=off",
        "-smp", "1", "-m", "128M", "-display", "none",
        "-serial", "stdio", "-monitor", "none",
        "-no-reboot", "-bios", str(firmware), "-kernel", str(kernel),
    ]
    if chapter < 9:
        args += ["-net", "none"]
    if chapter >= 6:
        if fs is None or not fs.is_file():
            raise ValueError("filesystem chapter needs a real generated fs.img")
        # Tutorial ch6-8 hardcode virtio-mmio slot 0. Chapter 9 explicitly
        # hardcodes slot 7 for block, slot 6 for GPU, slots 4/5 for input.
        bus = 7 if chapter == 9 else 0
        args += ["-drive", f"file={fs},if=none,format=raw,id=x0",
                 "-device", f"virtio-blk-device,drive=x0,bus=virtio-mmio-bus.{bus}"]
    if chapter == 9:
        args += [
            "-device", "virtio-gpu-device,bus=virtio-mmio-bus.6",
            "-device", "virtio-keyboard-device,bus=virtio-mmio-bus.4",
            "-device", "virtio-mouse-device,bus=virtio-mmio-bus.5",
            "-netdev", "user,id=net0",
            "-device", "virtio-net-device,netdev=net0,bus=virtio-mmio-bus.3",
        ]
    return args


def run(chapter, firmware, kernel, fs, logs, timeout):
    if not (15 <= timeout <= 300):
        raise ValueError("timeout must be 15-300 seconds")
    for path in (firmware, kernel):
        if not path.is_file() or not path.stat().st_size:
            raise ValueError(f"missing boot artifact: {path}")
    logs.mkdir(parents=True, exist_ok=True)
    cmd = qemu_args(chapter, firmware, kernel, fs)
    (logs / f"ch{chapter}-qemu-command.json").write_text(
        json.dumps(cmd, indent=2) + "\n", encoding="utf-8"
    )
    p = subprocess.Popen(
        cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, bufsize=0, start_new_session=True
    )
    collected = bytearray()
    t0 = time.monotonic()
    ready_at = None
    intentional_stop = False
    failure = ""
    try:
        while time.monotonic() - t0 < timeout:
            r, _, _ = select.select([p.stdout.fileno()], [], [], 0.2)
            if r:
                chunk = os.read(p.stdout.fileno(), 65536)
                if chunk:
                    collected.extend(chunk)
                elif p.poll() is not None:
                    break
            if len(collected) > MAX_SERIAL:
                failure = "serial output exceeded limit"
                break
            text = clean(collected)
            if FATAL.search(text):
                failure = "guest fatal/error evidence"
                break
            ok, _ = check_serial(chapter, collected)
            if chapter >= 7 and ok and ready_at is None:
                ready_at = time.monotonic()
            if ready_at is not None and time.monotonic() - ready_at >= 2.5:
                if p.poll() is None:
                    intentional_stop = True
                    break
                failure = "shell milestone followed by premature guest exit"
                break
            if p.poll() is not None:
                break
        else:
            failure = "guest boot timeout"
    finally:
        if p.poll() is None:
            os.killpg(p.pid, signal.SIGTERM)
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL)
                p.wait(timeout=5)
        else:
            p.wait(timeout=5)
        while True:
            r, _, _ = select.select([p.stdout.fileno()], [], [], 0)
            if not r:
                break
            chunk = os.read(p.stdout.fileno(), 65536)
            if not chunk:
                break
            collected.extend(chunk)
        path = logs / f"ch{chapter}-serial.log"
        path.write_bytes(collected)
    ok, reason = check_serial(chapter, collected)
    if failure:
        ok, reason = False, failure
    elif chapter >= 7:
        if not intentional_stop:
            ok, reason = False, "shell not observed alive for settle interval"
    elif p.returncode != 0:
        ok, reason = False, f"unexpected QEMU exit status {p.returncode}"
    print(f"ch{chapter}: {'PASS' if ok else 'FAIL'} ({reason}); "
          f"QEMU exit={p.returncode}; seconds={time.monotonic()-t0:.1f}; "
          f"UART={path}", flush=True)
    if not ok:
        print("SERIAL TAIL:\n" + clean(collected)[-2500:], file=sys.stderr)
        return 1
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["run", "self-test"])
    ap.add_argument("--chapter", type=int, choices=list(MARKERS))
    ap.add_argument("--firmware", type=Path)
    ap.add_argument("--kernel", type=Path)
    ap.add_argument("--fs", type=Path)
    ap.add_argument("--logs", type=Path, default=Path("qemu-logs/rcore-tutorial"))
    ap.add_argument("--timeout", type=int, default=75)
    a = ap.parse_args()
    if a.action == "self-test":
        self_test()
        return 0
    if a.chapter is None or a.firmware is None or a.kernel is None:
        ap.error("run requires --chapter, --firmware and --kernel")
    return run(a.chapter, a.firmware, a.kernel, a.fs, a.logs, a.timeout)


if __name__ == "__main__":
    sys.exit(main())
