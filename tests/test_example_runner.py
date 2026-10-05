"""Exercise real runner invocations without Docker, docking or existing campaigns.

Run with: python3 -m unittest discover -s tests -p 'test_example_runner.py'
"""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
ACCURATE = "analog_harvest_accurate"
FAST = "analog_harvest_fast"

# A completed campaign needs only init/status. Fail if the runner tries to dock
# or ingest: these tests must never advance an existing campaign.
FAKE_NAVIGATOR = '''\
import json
from pathlib import Path
import shutil
import sys

args = sys.argv[1:]
with Path("calls.jsonl").open("a") as log:
    log.write(json.dumps(args) + "\\n")
run = Path(args[args.index("--run-dir") + 1])
if args[0] == "init":
    config = Path(args[args.index("--config-json") + 1])
    shutil.copyfile(config, run / "config.json")
elif args[0] == "status":
    config = json.loads((run / "config.json").read_text())
    if "--field" in args:
        field = args[args.index("--field") + 1]
        print({"pending_batch_id": "None", "can_propose": "False"}[field])
    else:
        print(json.dumps({"strategy": config["strategy"], "can_propose": False}))
else:
    sys.exit("unexpected campaign work: " + args[0])
'''


class ExampleRunnerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="navigator-runner-")
        self.addCleanup(temporary.cleanup)
        self.repo = Path(temporary.name)
        examples = self.repo / "examples"
        (examples / "configs").mkdir(parents=True)
        shutil.copyfile(ROOT / "examples/run_navigator.sh", examples / "run_navigator.sh")
        shutil.copyfile(ROOT / "examples/configs/TGFR1.json", examples / "configs/TGFR1.json")
        fake = self.repo / "fake_navigator.py"
        fake.write_text(FAKE_NAVIGATOR)
        launcher = self.repo / "navigator"
        launcher.write_text(
            f'#!/usr/bin/env bash\nexec {shlex.quote(sys.executable)} {shlex.quote(str(fake))} "$@"\n'
        )
        launcher.chmod(0o755)
        self.env = {**os.environ, "NAVIGATOR_BIN": str(launcher), "PYTHON_BIN": sys.executable,
                    "SCORER_CMD": "", "GPU": "0"}

    def run_example(self, method, *extra):
        return subprocess.run(
            ["bash", str(self.repo / "examples/run_navigator.sh"), "TGFR1",
             "--method", method, "--budget", "200", "--iters", "2",
             "--pool", "20000", "--scorer", "mock", *extra],
            env=self.env, capture_output=True, text=True, timeout=20,
        )

    def run_path(self, method):
        return self.repo / "runs" / f"tgfr1_{method}_200_mock"

    def seed_run(self, method, strategy):
        run = self.run_path(method)
        run.mkdir(parents=True)
        (run / "config.json").write_text(json.dumps({"strategy": strategy}) + "\n")
        (run / "state.json").write_text('{"status": "complete", "sentinel": "preserve"}\n')
        return run

    def calls(self, operation):
        log = self.repo / "calls.jsonl"
        if not log.exists():
            return []
        return [args for line in log.read_text().splitlines()
                if (args := json.loads(line))[0] == operation]

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_all_creates_four_distinct_runs_and_resumes_without_reinitializing(self):
        self.assert_success(self.run_example("all"))
        self.assertEqual(len(self.calls("init")), 4)
        expected = {"gamma": "gamma_diversity_screening", "ga": "ga_dcso_v14_screening",
                    "accurate": ACCURATE, "fast": FAST}
        for method, strategy in expected.items():
            config = json.loads((self.run_path(method) / "config.json").read_text())
            self.assertEqual(config["strategy"], strategy)
        self.assert_success(self.run_example("all"))
        self.assertEqual(len(self.calls("init")), 4)

    def test_legacy_accurate_run_is_preserved_when_running_all(self):
        legacy = self.seed_run("analog", ACCURATE)
        original = {name: (legacy / name).read_bytes() for name in ("config.json", "state.json")}
        self.assert_success(self.run_example("all"))
        self.assertEqual(len(self.calls("init")), 3)
        self.assertFalse(self.run_path("accurate").exists())
        self.assertEqual(json.loads((self.run_path("fast") / "config.json").read_text())["strategy"], FAST)
        for name, data in original.items():
            self.assertEqual((legacy / name).read_bytes(), data)

    def test_legacy_fast_run_is_preserved_when_running_all(self):
        legacy = self.seed_run("analog", FAST)
        original = (legacy / "config.json").read_bytes()
        self.assert_success(self.run_example("all"))
        self.assertEqual(len(self.calls("init")), 3)
        self.assertFalse(self.run_path("fast").exists())
        self.assertEqual(json.loads((self.run_path("accurate") / "config.json").read_text())["strategy"], ACCURATE)
        self.assertEqual((legacy / "config.json").read_bytes(), original)

    def test_deprecated_fast_preset_alias_reuses_legacy_run(self):
        self.seed_run("analog", "analog_harvest")
        self.assert_success(self.run_example("analog_harvest"))
        self.assertFalse(self.run_path("fast").exists())
        self.assertEqual(self.calls("init"), [])

    def test_existing_method_directory_takes_precedence(self):
        self.seed_run("analog", FAST)
        current = self.seed_run("fast", FAST)
        self.assert_success(self.run_example("fast", "--status"))
        calls = self.calls("status")
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][calls[0].index("--run-dir") + 1], current.relative_to(self.repo).as_posix())

    def test_strategy_mismatch_is_rejected_before_any_campaign_work(self):
        run = self.seed_run("fast", ACCURATE)
        before = {p.name: p.read_bytes() for p in run.iterdir()}
        result = self.run_example("fast")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"uses {ACCURATE}, but {FAST} was requested", result.stderr)
        self.assertEqual({p.name: p.read_bytes() for p in run.iterdir()}, before)
        self.assertFalse((self.repo / "calls.jsonl").exists())

    def test_unreadable_legacy_config_is_not_silently_abandoned(self):
        run = self.seed_run("analog", FAST)
        (run / "config.json").write_text("{broken json")
        result = self.run_example("fast")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot read strategy", result.stderr)
        self.assertFalse(self.run_path("fast").exists())
        self.assertFalse((self.repo / "calls.jsonl").exists())


if __name__ == "__main__":
    unittest.main()
