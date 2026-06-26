#!/usr/bin/env python3
# NONOS Operating System
# Copyright (C) 2026 NONOS Contributors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
import json, os, shlex, subprocess, sys, time
def main() -> int:
    stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
    out = os.environ.get("NONOS_BENCH_OUT") or f"target/bench/{stamp}"
    os.makedirs(out, exist_ok=True)
    py = sys.executable
    failures = []
    subprocess.check_call([py, "nonos-ci/bench_host.py", out])
    if os.environ.get("NONOS_BENCH_SKIP_BUILD") != "1":
        raw = os.environ.get("NONOS_BENCH_BUILD_CMD", "make nonos-mk-verify-fast")
        build_cmd = shlex.split(raw)
        rc = subprocess.call([py, "nonos-ci/bench_time.py", "build-verify-fast", out, "--", *build_cmd])
        if rc != 0: failures.append("build-verify-fast")
    if os.environ.get("NONOS_BENCH_SKIP_BOOT") != "1":
        boot_dir = os.path.join(out, "boot")
        boot_log = os.path.join(boot_dir, "qemu-serial.log")
        boot_cmd = ["env", "NONOS_DEV=1", f"NONOS_BOOT_EVIDENCE_OUT={boot_dir}",
                    f"NONOS_BOOT_EVIDENCE_LOG={boot_log}",
                    f"NONOS_BOOT_EVIDENCE_TIMEOUT={os.environ.get('NONOS_BENCH_BOOT_TIMEOUT', '360')}",
                    f"NONOS_BOOT_EVIDENCE_CMD={os.environ.get('NONOS_BENCH_BOOT_CMD', '')}",
                    "make", "nonos-mk-boot-evidence"]
        timed = [py, "nonos-ci/bench_time.py", "boot-evidence", out, "--", *boot_cmd]
        rc = subprocess.call(timed)
        if rc != 0: failures.append("boot-evidence")
        parsed = [py, "nonos-ci/bench_boot_log.py", boot_log, os.path.join(out, "boot-log.json")]
        rc = subprocess.call(parsed)
        if rc != 0: failures.append("boot-log")
    records = []
    for name in ("host", "build-verify-fast", "boot-evidence", "boot-log"):
        path = os.path.join(out, f"{name}.json")
        if os.path.exists(path):
            with open(path, encoding="utf-8") as src:
                records.append(json.load(src))
    summary = os.path.join(out, "summary.md")
    with open(summary, "w", encoding="utf-8") as dst:
        dst.write("# NØNOS Benchmark Run\n\n")
        dst.write(f"Output: `{out}`\n\n")
        for rec in records:
            name = rec.get("name", rec.get("schema", "record"))
            status = rec.get("status", "recorded")
            elapsed = rec.get("elapsed_ms", "")
            dst.write(f"- `{name}` status `{status}` elapsed `{elapsed}` ms\n")
        for rec in records:
            phases = rec.get("phase_ms", {})
            if not phases: continue
            dst.write("\nBoot phases:\n")
            for key, value in sorted(phases.items()):
                dst.write(f"- `{key}` `{value}` ms\n")
            samples = rec.get("phase_samples_ms", {})
            if not samples: continue
            dst.write("\nSample aggregates:\n")
            for key, values in sorted(samples.items()):
                avg = round(sum(values) / len(values), 3)
                dst.write(f"- `{key}` count `{len(values)}` min `{min(values)}` avg `{avg}` max `{max(values)}` ms\n")
        if failures: dst.write("\nFailures:\n" + "".join(f"- `{item}`\n" for item in failures))
    subprocess.check_call([py, "nonos-ci/bench_collect.py", out])
    print(summary)
    return 1 if failures and os.environ.get("NONOS_BENCH_STRICT") == "1" else 0
if __name__ == "__main__": raise SystemExit(main())
