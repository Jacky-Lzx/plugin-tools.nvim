"""Fresh Neovim processes, existing packages, warm OS filesystem cache."""
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
samples = int(os.environ.get("BENCH_SAMPLES", "15"))
results = {"environment": subprocess.check_output(["nvim", "--version"], text=True).splitlines()[0],
           "samples": samples, "cache": "warm OS cache; fresh Neovim process per sample", "results": []}
with tempfile.TemporaryDirectory(prefix="plugin-tools-bench-") as temporary:
    root = Path(temporary)
    for i in range(1, 501):
        (root / f"p{i}").mkdir()
    for count in (10, 100, 500):
        measured = []
        for _ in range(samples + 1):
            env = dict(os.environ, PLUGIN_TOOLS_BENCH_ROOT=str(root), PLUGIN_TOOLS_BENCH_COUNT=str(count),
                       NVIM_LOG_FILE=str(root / "nvim.log"))
            result = subprocess.run(["nvim", "--headless", "-u", "NONE", "-i", "NONE", "--noplugin", "-l", "tests/benchmark.lua"],
                                    cwd=repo, env=env, capture_output=True, text=True, check=True)
            measured.append(json.loads((result.stdout + result.stderr).strip()))
        measured = measured[1:]
        record = {"plugins": count}
        for key in ("setup_ms", "memory_kib", "ready_call_ns"):
            values = sorted(sample[key] for sample in measured)
            record[key] = {"median": statistics.median(values), "p95": values[min(len(values)-1, int(len(values)*0.95))]}
        results["results"].append(record)
path = Path(os.environ.get("BENCH_OUTPUT", str(repo / "benchmark-results.json")))
path.write_text(json.dumps(results, indent=2) + "\n")
print(path)
print(json.dumps(results, indent=2))
