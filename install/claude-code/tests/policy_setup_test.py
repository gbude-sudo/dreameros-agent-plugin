"""End-to-end test for dreameros-policy-setup.ps1 and validate_claude_settings.py.

Runs the installer against a temporary target directory (no admin needed),
twice, and checks:
  1. install writes the policy, hooks and schema, and the policy validates
  2. a second run merges: no duplicate deny rules, no duplicate hooks
  3. a pre-existing managed file with a file-level type error is refused
     and left untouched
  4. the validator flags a wrong-typed fallbackModel (the 2026-09-16 defect)
     and passes a correct file

Run: python install/claude-code/tests/policy_setup_test.py
Exit 0 on success.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SCRIPT = os.path.join(ROOT, "dreameros-policy-setup.ps1")
VALIDATOR = os.path.join(ROOT, "payload", "hooks", "validate_claude_settings.py")


def run_installer(target):
    return subprocess.run(
        ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", SCRIPT,
         "-TargetDir", target, "-PythonPath", sys.executable],
        capture_output=True, text=True, timeout=180,
    )


def validate(path):
    return subprocess.run([sys.executable, VALIDATOR, path], capture_output=True, text=True).returncode


def main():
    failures = []
    tmp = tempfile.mkdtemp(prefix="dreameros-policy-test-")
    try:
        managed = os.path.join(tmp, "managed-settings.json")

        r1 = run_installer(tmp)
        if r1.returncode != 0 or not os.path.exists(managed):
            failures.append(f"first install failed: {r1.stdout[-400:]} {r1.stderr[-400:]}")
        else:
            for rel in ("dreameros/hooks/validate_claude_settings.py",
                        "dreameros/hooks/gate_live_canon.py",
                        "dreameros/claude-code-settings.schema.json"):
                if not os.path.exists(os.path.join(tmp, rel)):
                    failures.append(f"missing installed file {rel}")
            if validate(managed) != 0:
                failures.append("installed policy does not validate")
            first = json.load(open(managed, encoding="utf-8"))

            r2 = run_installer(tmp)
            second = json.load(open(managed, encoding="utf-8"))
            if r2.returncode != 0:
                failures.append(f"second install failed: {r2.stderr[-400:]}")
            deny = second["permissions"]["deny"]
            if len(deny) != len(set(deny)) or len(deny) != len(first["permissions"]["deny"]):
                failures.append("deny list duplicated on second run")
            cmds = [h["command"] for g in second["hooks"]["SessionStart"] for h in g["hooks"]]
            if len(cmds) != len(set(cmds)) or len(cmds) != 2:
                failures.append(f"SessionStart hooks not idempotent: {cmds}")

        with open(managed, "w", encoding="utf-8") as fh:
            json.dump({"fallbackModel": "claude-sonnet-5"}, fh)
        before = open(managed, encoding="utf-8").read()
        r3 = run_installer(tmp)
        if r3.returncode == 0:
            failures.append("installer accepted a merge on top of a broken managed file")
        if open(managed, encoding="utf-8").read() != before:
            failures.append("installer changed the file it refused")

        good = os.path.join(tmp, "good.json")
        with open(good, "w", encoding="utf-8") as fh:
            json.dump({"fallbackModel": ["claude-sonnet-5"]}, fh)
        if validate(good) != 0:
            failures.append("validator rejected a correct fallbackModel")
        if validate(managed) != 1:
            failures.append("validator passed a string fallbackModel")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if failures:
        print("FAIL")
        for f in failures:
            print("  " + f)
        return 1
    print("PASS policy installer and settings validator (4 checks)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
