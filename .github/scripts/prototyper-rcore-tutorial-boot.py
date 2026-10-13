#!/usr/bin/env python3
"""Bounded QEMU serial acceptance for rCore-Tutorial ch2 (RustSBI #329).

This is an actual guest run, not an output fixture. --self-test only tests the
pure serial validator; it cannot replace the two CI matrix guest runs.
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

CSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
FATAL = re.compile(
    r"(?im)^(?:.*(?:Synchronous Exception|Unhandled exception|RustSBI panic|Kernel panic|system panic).*)$"
)
EXPECTED = (
    "Hello RustSBI!",
    "SiFiveClint (Base Address: 0x2000000)",
    "Redirecting hart 0 to 0x00000080200000 in Supervisor mode.",
)
GUEST = (
    "[kernel] Hello, world!",
    "[kernel] num_app = 5",
    "[kernel] Loading app_0",
    "[kernel] Loading app_1",
    "[kernel] Loading app_2",
    "Test power OK!",
    "[kernel] Loading app_3",
    "[kernel] Loading app_4",
    "All applications completed!",
)
UBOOT = (
    "U-Boot 2025.10",
    "=> cp.b 0x86000000 0x80200000 ",
    "=> go 0x80200000",
    "## Starting application at 0x80200000",
)


def clean(raw):
    return CSI.sub("", raw.decode("utf-8", errors="replace").replace("\r", ""))


def validate_trace(mode, raw, exit_code, did_copy=False, did_go=False):
    """Fail closed on missing/reordered evidence and any actual QEMU failure."""
    if exit_code != 0:
        return False, "QEMU did not exit successfully"
    text = clean(raw)
    if FATAL.search(text):
        return False, "fatal runtime evidence"
    sequence = EXPECTED + (UBOOT if mode == "u-boot" else ()) + GUEST
    last = -1
    for marker in sequence:
        found = text.find(marker, last + 1)
        if found < 0:
            return False, "missing or out-of-order: " + marker
        last = found
    if mode == "sbi":
        if re.search(r"U-Boot 20\d\d|RISC-V EDK2 firmware|GNU GRUB", text):
            return False, "unexpected intermediate bootloader in direct SBI mode"
    else:
        if not did_copy or not did_go:
            return False, "U-Boot commands not actually delivered by supervisor"
    return True, "real kernel executed all five user applications"


def self_test():
    def make(mode):
        trace = "\n".join(EXPECTED + (UBOOT if mode == "u-boot" else ()) + GUEST)
        return trace.encode()
    cases = []
    for mode in ("sbi", "u-boot"):
        base = make(mode)
        actions = (mode == "u-boot")
        cases.extend([
            (mode, base, 0, actions, actions, True),
            (mode, base, 1, actions, actions, False),
            (mode, base.replace(b"Hello RustSBI!", b"Hello unknown!", 1), 0, actions, actions, False),
            (mode, base.replace(b"All applications completed!", b"All applications failed!"), 0, actions, actions, False),
            (mode, base.replace(b"[kernel] num_app = 5", b"[kernel] num_app = 0"), 0, actions, actions, False),
            (mode, base + b"\nKernel panic - not syncing\n", 0, actions, actions, False),
            (mode, base.replace(b"Test power OK!", b"", 1), 0, actions, actions, False),
            (mode, base.replace(b"[kernel] Loading app_4", b"[kernel] Loading app_5", 1), 0, actions, actions, False),
        ])
    cases.extend([
        ("sbi", make("sbi").replace(b"[kernel] num_app = 5", b"U-Boot 2025.10\n[kernel] num_app = 5"), 0, False, False, False),
        ("u-boot", make("u-boot"), 0, False, True, False),
        ("u-boot", make("u-boot"), 0, True, False, False),
        ("u-boot", make("u-boot").replace(b"=> go 0x80200000", b"=> go 0x80200001"), 0, True, True, False),
    ])
    for i, (mode, raw, code, copied, jumped, want) in enumerate(cases):
        actual, reason = validate_trace(mode, raw, code, copied, jumped)
        if actual != want:
            raise AssertionError((i, mode, reason, want))
    # Reverse independent milestones: no accidental set-based acceptance.
    for mode in ("sbi", "u-boot"):
        markers = list(EXPECTED + (UBOOT if mode == "u-boot" else ()) + GUEST)
        markers[-2], markers[-1] = markers[-1], markers[-2]
        okay, reason = validate_trace(mode, ("\n".join(markers)).encode(), 0, mode == "u-boot", mode == "u-boot")
        assert not okay, reason
    print("PASS: rCore-Tutorial trace acceptance", len(cases) + 2, "cases", flush=True)


def run(mode, firmware, kernel, uboot, logs, timeout):
    if not firmware.is_file() or not kernel.is_file() or not (mode == "sbi" or uboot.is_file()):
        raise ValueError("missing built and pinned guest boot assets")
    if not 15 <= timeout <= 300:
        raise ValueError("timeout must be between 15 and 300 seconds")
    if kernel.stat().st_size > 0x11000:
        raise ValueError("pinned ch2 kernel exceeds U-Boot copy budget")
    logs.mkdir(parents=True, exist_ok=True)
    cmd = [
        "qemu-system-riscv64", "-machine", "virt,acpi=off",
        "-smp", "1", "-m", "512M", "-display", "none",
        "-serial", "stdio", "-monitor", "none", "-no-reboot",
        "-net", "none", "-bios", str(firmware),
    ]
    if mode == "sbi":
        cmd += ["-kernel", str(kernel)]
    else:
        cmd += ["-kernel", str(uboot),
                "-device", f"loader,file={kernel},addr=0x86000000"]
    (logs / f"rcore-ch2-{mode}-command.json").write_text(json.dumps(cmd, indent=2) + "\n")
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, bufsize=0, start_new_session=True)
    captured = bytearray()
    stage = "waiting_uboot" if mode == "u-boot" else "guest"
    sent_break = sent_copy = sent_go = False
    t0 = time.monotonic()
    failed = ""
    def send(value):
        p.stdin.write(value)
        p.stdin.flush()
    try:
        while time.monotonic() - t0 < timeout:
            ready, _, _ = select.select([p.stdout.fileno()], [], [], 0.2)
            if ready:
                chunk = os.read(p.stdout.fileno(), 65536)
                if chunk:
                    captured.extend(chunk)
                elif p.poll() is not None:
                    break
            txt = clean(captured)
            if mode == "u-boot":
                if stage == "waiting_uboot" and not sent_break and (
                    "Hit any key to stop autoboot:" in txt or time.monotonic() - t0 > 4
                ):
                    send(b"\n")
                    sent_break = True
                if stage == "waiting_uboot" and re.search(r"=> $", txt):
                    send(b"cp.b 0x86000000 0x80200000 0x11000\n")
                    sent_copy = True
                    stage = "waiting_copy"
                if stage == "waiting_copy" and txt.count("=> ") >= 2 and re.search(r"=> $", txt):
                    send(b"go 0x80200000\n")
                    sent_go = True
                    stage = "guest"
            if FATAL.search(txt):
                failed = "fatal serial output"
                break
            if p.poll() is not None:
                break
        else:
            failed = "QEMU timed out"
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
        # Collect buffered serial bytes after exit (not a second authority source).
        while True:
            r, _, _ = select.select([p.stdout.fileno()], [], [], 0)
            if not r:
                break
            b = os.read(p.stdout.fileno(), 65536)
            if not b:
                break
            captured.extend(b)
        path = logs / f"prototyper-rcore-ch2-{mode}.serial.log"
        path.write_bytes(captured)
    good, reason = validate_trace(mode, bytes(captured), p.returncode, sent_copy, sent_go)
    if failed:
        good, reason = False, failed
    print(f"boot mode={mode} QEMU exit={p.returncode} elapsed={time.monotonic()-t0:.1f}s serial={path}")
    print(f"result={'PASS' if good else 'FAIL'}: {reason}")
    if not good:
        print("Serial tail:", clean(captured)[-2600:], file=sys.stderr)
        return 1
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["sbi", "u-boot", "self-test"])
    parser.add_argument("--firmware", type=Path)
    parser.add_argument("--kernel", type=Path)
    parser.add_argument("--uboot", type=Path)
    parser.add_argument("--logs", type=Path, default=Path("qemu-logs"))
    parser.add_argument("--timeout", type=int, default=90)
    args = parser.parse_args()
    if args.mode == "self-test":
        self_test()
        return 0
    if args.firmware is None or args.kernel is None:
        parser.error("real boot requires --firmware and --kernel")
    if args.mode == "u-boot" and args.uboot is None:
        parser.error("U-Boot boot requires --uboot")
    return run(args.mode, args.firmware, args.kernel, args.uboot, args.logs, args.timeout)


if __name__ == "__main__":
    sys.exit(main())
