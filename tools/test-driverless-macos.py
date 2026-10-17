#!/usr/bin/env python3
"""Exercise the packaged service through real macOS CUPS. No enterprise traffic."""
import json
import os
from pathlib import Path
import platform
import socket
import subprocess
import sys
import tempfile
import time
import uuid

URI = "ipp://127.0.0.1:19963/ipp/print"
ROOT = Path(__file__).resolve().parent.parent


def run(*args, check=True):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=45)
    if result.stdout.strip():
        print(result.stdout.strip(), flush=True)
    if check and result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {' '.join(map(str, args))}")
    return result.stdout


def pdf(path):
    """Two distinct, valid A4 pages, without third-party dependencies."""
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>",
               b"<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>"]
    for content in [5, 6]:
        objects.append(("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] "
                        f"/Resources << >> /Contents {content} 0 R >>").encode())
    for drawing in [b"0 0 1 rg 72 72 144 144 re f\n", b"1 0 0 rg 144 144 72 72 re f\n"]:
        objects.append(f"<< /Length {len(drawing)} >>\nstream\n".encode() + drawing + b"endstream")
    data = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = [0]
    for number, body in enumerate(objects, 1):
        offsets.append(len(data))
        data += f"{number} 0 obj\n".encode() + body + b"\nendobj\n"
    xref = len(data)
    data += f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode()
    for offset in offsets[1:]:
        data += f"{offset:010d} 00000 n \n".encode()
    data += (f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\n"
             f"startxref\n{xref}\n%%EOF\n").encode()
    path.write_bytes(data)


def captured(root, title, process, expected):
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("Capture service exited")
        jobs = [json.loads(p.read_text()) for p in root.glob("*/job.json")]
        matches = [job for job in jobs if job["document"]["title"] == title]
        if matches:
            assert len(matches) == 1, f"Duplicate captures: {title}"
            job = matches[0]
            assert job["state"] == "queued" and not job.get("serverJobID"), job
            actual = {**job["settings"], "pages": job["document"]["pageCount"]}
            for key, value in expected.items():
                assert actual[key] == value, f"{title}: expected {key}={value}, got {actual}"
            print(f"PASS {title}: {actual}; local only", flush=True)
            return
        time.sleep(0.25)
    raise RuntimeError(f"No local capture for {title}")


def driverless(queue):
    output = run("sudo", "-n", "/usr/sbin/lpadmin", "-p", queue, "-E",
                 "-D", "ZGCAxZGCI printer", "-L", "Local capture test",
                 "-v", URI, "-m", "everywhere", "-o", "printer-is-shared=false")
    assert "deprecated" not in output.lower(), output
    options = run("/usr/bin/lpoptions", "-p", queue, "-l")
    for option in ["A4", "A3", "A5", "Letter", "Legal", "Gray", "RGB", "DuplexNoTumble", "DuplexTumble"]:
        assert option in options, f"Missing driverless capability: {option}"


def main():
    assert platform.system() == "Darwin" and os.geteuid() != 0
    app = Path(sys.argv[1]).resolve()
    assert not (app / "Contents/Resources/RoamPrint.ppd").exists(), "App still bundles a PPD"
    service = app / "Contents/Resources/bin/roamprint-service"
    queues = ["RoamPrintTest_" + uuid.uuid4().hex[:12] for _ in range(2)]
    with tempfile.TemporaryDirectory(prefix="roamprint-ipp-") as temp:
        temp = Path(temp)
        job_root = temp / "jobs"
        source = temp / "two-pages.pdf"
        pdf(source)
        # Refuse to touch an existing service, including on a developer's Mac.
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 19963))
        with (temp / "service.log").open("w+") as log:
            process = subprocess.Popen([str(service), "--test-job-root", str(job_root)], stdout=log, stderr=log)
            try:
                for _ in range(40):
                    try:
                        with socket.create_connection(("127.0.0.1", 19963), timeout=0.25):
                            break
                    except OSError:
                        time.sleep(0.25)
                else:
                    raise RuntimeError("Service did not start")

                fresh, legacy = queues
                driverless(fresh)
                cases = [
                    ("default", [], {"pages": 2, "copies": 1, "color": 1, "duplex": 1, "paperName": "A4"}),
                    ("settings", ["-n", "3", "-o", "media=iso_a3_297x420mm", "-o", "print-color-mode=color",
                                  "-o", "sides=two-sided-long-edge"],
                     {"pages": 2, "copies": 3, "color": 2, "duplex": 2, "paperName": "A3"}),
                    ("page-range", ["-o", "page-ranges=2"], {"pages": 1, "copies": 1}),
                    ("two-up", ["-o", "number-up=2"], {"pages": 1, "copies": 1}),
                ]
                for title, options, expected in cases:
                    run("/usr/bin/lp", "-d", fresh, "-t", title, *options, str(source))
                    captured(job_root, title, process, expected)

                # A held job must survive upgrading a custom-PPD queue in place.
                run("sudo", "-n", "/usr/sbin/lpadmin", "-p", legacy, "-E", "-v", URI,
                    "-P", str(ROOT / "tools/fixtures/legacy-capture.ppd"), "-o", "printer-is-shared=false")
                run("/usr/bin/lp", "-d", legacy, "-H", "hold", "-t", "migration", str(source))
                before = run("/usr/bin/lpstat", "-o", legacy).split()[0]
                driverless(legacy)
                assert before in run("/usr/bin/lpstat", "-o", legacy), "Upgrade discarded a held job"
                run("/usr/bin/lp", "-i", before, "-H", "resume")
                captured(job_root, "migration", process, {"pages": 2, "paperName": "A4"})
                print("PASS driverless discovery, printing, local layout and legacy migration", flush=True)
            except Exception:
                for queue in queues:
                    run("/usr/bin/lpstat", "-l", "-p", queue, check=False)
                    run("/usr/bin/lpstat", "-o", queue, check=False)
                run("sudo", "-n", "/usr/bin/tail", "-n", "50", "/var/log/cups/error_log", check=False)
                raise
            finally:
                for queue in queues:
                    run("sudo", "-n", "/usr/sbin/lpadmin", "-x", queue, check=False)
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                log.seek(0)
                print(log.read(), flush=True)


if __name__ == "__main__":
    main()
