#!/usr/bin/env python3
"""Boot the built ISO in a headless VM, walk the installer in Danish, and
record every screen to frames for a video.

Usage: record-danish.py <omarchy.iso> <workdir>
"""
import json, os, socket, subprocess, sys, threading, time
from pathlib import Path

iso, work = Path(sys.argv[1]), Path(sys.argv[2])
frames = work / "frames"
frames.mkdir(parents=True, exist_ok=True)
qmp_path = str(work / "qmp.sock")
disk = work / "disk.qcow2"
vars_fd = work / "OVMF_VARS.4m.fd"
log = open(work / "driver.log", "a")

def note(msg):
    line = f"{time.strftime('%H:%M:%S')} {msg}"
    print(line, flush=True); log.write(line + "\n"); log.flush()

subprocess.run(["qemu-img", "create", "-f", "qcow2", str(disk), "40G"], check=True, capture_output=True)
subprocess.run(["cp", "/usr/share/edk2/x64/OVMF_VARS.4m.fd", str(vars_fd)], check=True)
qemu = subprocess.Popen([
    "qemu-system-x86_64", "-cpu", "host", "-enable-kvm", "-machine", "q35,accel=kvm",
    "-smp", str(os.cpu_count()), "-m", "8192",
    "-drive", "if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd",
    "-drive", f"if=pflash,format=raw,file={vars_fd}",
    "-drive", f"file={disk},format=qcow2,if=none,id=drive0", "-device", "virtio-blk-pci,drive=drive0,bootindex=1",
    "-drive", f"file={iso},media=cdrom,if=none,id=cd0", "-device", "ide-cd,drive=cd0,bootindex=2",
    "-device", "virtio-vga", "-display", "none",
    "-netdev", "user,id=net0", "-device", "virtio-net-pci,netdev=net0",
    "-qmp", f"unix:{qmp_path},server,nowait", "-serial", f"file:{work / 'serial.log'}",
])

for _ in range(100):
    if os.path.exists(qmp_path): break
    time.sleep(0.1)
sock = socket.socket(socket.AF_UNIX); sock.connect(qmp_path)
reader = sock.makefile("r")
lock = threading.Lock()

def qmp(cmd, args=None):
    with lock:
        sock.sendall((json.dumps({"execute": cmd, **({"arguments": args} if args else {})}) + "\n").encode())
        while True:
            reply = json.loads(reader.readline())
            if "return" in reply or "error" in reply:
                return reply

reader.readline(); qmp("qmp_capabilities")

interval = [0.25]
stop = threading.Event()
latest = [None]

def capture():
    n = 0
    while not stop.is_set():
        path = frames / f"{n:06d}.ppm"
        if "return" in qmp("screendump", {"filename": str(path)}) and path.exists():
            latest[0] = path; n += 1
        time.sleep(interval[0])

threading.Thread(target=capture, daemon=True).start()

def ocr():
    shot = latest[0]
    if not shot: return ""
    png = work / "ocr.png"
    subprocess.run(["magick", str(shot), "-colorspace", "gray", "-negate", "-resize", "150%", str(png)], capture_output=True)
    return subprocess.run(["tesseract", str(png), "-", "--psm", "6"], capture_output=True, text=True).stdout

def wait_for(text, timeout):
    note(f"waiting for {text!r}")
    deadline = time.time() + timeout
    while time.time() < deadline:
        if qemu.poll() is not None: raise SystemExit("VM exited")
        if any(t.lower() in ocr().lower() for t in text.split("|")):
            time.sleep(1.2); return
        time.sleep(1.5)
    raise SystemExit(f"timed out waiting for {text!r}")

def press(chord, pause=0.35):
    qmp("send-key", {"keys": [{"type": "qcode", "data": k} for k in chord.split("-")]})
    time.sleep(pause)

def type_text(text):
    keys = {" ": "spc", ".": "dot", "-": "minus"}
    for ch in text:
        if ch.isupper(): press(f"shift-{ch.lower()}", 0.12)
        else: press(keys.get(ch, ch), 0.12)
    time.sleep(0.6)

try:
    wait_for("Linux by DHH", 400); time.sleep(2); press("ret")
    wait_for("language", 120); time.sleep(1.5)
    for _ in range(9): press("down", 0.3)
    time.sleep(1.5); press("ret")
    wait_for("tastaturlayout", 60); time.sleep(2.5); press("ret")
    wait_for("Brugernavn", 60); type_text("dhh"); press("ret")
    wait_for("Adgangskode", 60); type_text("omarchy"); press("ret")
    wait_for("Skal svare", 60); type_text("omarchy"); press("ret")
    wait_for("Fulde navn", 60); type_text("David Hansson"); press("ret")
    wait_for("mailadresse", 60); time.sleep(1); press("ret")
    wait_for("rtsnavn", 60); time.sleep(1); press("ret")
    wait_for("Tidszone", 180); time.sleep(2); press("ret")
    wait_for("rigtigt ud", 60); time.sleep(3); press("ret")
    wait_for("installationsdisk", 120); time.sleep(2); press("ret")
    wait_for("installationstilstand|gendannes", 60)
    if "installationstilstand" in ocr().lower():
        time.sleep(2); press("ret")
    wait_for("gendannes", 60); time.sleep(2.5)
    press("ctrl-c"); time.sleep(2.5); press("ret")
    note("install started; time-lapse")
    interval[0] = 3.0
    wait_for("Genstart nu|installeret", 3600)
    interval[0] = 0.25
    time.sleep(4); press("ret")
    note("rebooting into the installed system")
    interval[0] = 1.0
    time.sleep(75)                      # firmware, Limine, boot to SDDM
    interval[0] = 0.25
    type_text("omarchy"); press("ret")  # SDDM focuses the password field
    note("logging in")
    interval[0] = 1.0
    time.sleep(45)                      # first login settles the desktop
    interval[0] = 0.25
    press("meta_l-spc"); time.sleep(5)  # the Omarchy menu, in Danish
    press("esc"); time.sleep(1.5)
    press("meta_l-k"); time.sleep(6)    # keybindings, in Danish
    press("esc"); time.sleep(2)
    note("done")
finally:
    stop.set(); time.sleep(1)
    qemu.terminate()
