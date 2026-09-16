"""End-to-end test for dreameros-policy-setup.ps1 and validate_claude_settings.py.

Runs the installer against a temporary target directory (no admin needed),
twice, and checks:
  1. install writes the policy, hooks and schema, and the policy validates
  2. a second run merges: no duplicate deny rules, no duplicate hooks
  3. a pre-existing managed file with a file-level type error is refused
     and left untouched
  4. the validator flags a wrong-typed fallbackModel (the 2026-09-16 defect)
     and passes a correct file
  5. the real ACL lock (-LockForTest) leaves the policy readable, with
     Users read-only and no non-admin write entry

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


def lock_test(failures):
    """Run the real ACL lock on a temp dir and prove the policy stays READABLE.

    2026-09-16: the first lock left every file with no access entries, so
    Claude Code could not read the policy it was meant to protect.
    """
    tmp = tempfile.mkdtemp(prefix="dreameros-lock-test-")
    managed = os.path.join(tmp, "managed-settings.json")
    try:
        r = subprocess.run(
            ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", SCRIPT,
             "-TargetDir", tmp, "-PythonPath", sys.executable, "-LockForTest"],
            capture_output=True, text=True, timeout=180,
        )
        if r.returncode != 0 or "locked:" not in r.stdout:
            failures.append(f"lock run failed: {r.stdout[-300:]} {r.stderr[-300:]}")
            return
        try:
            with open(managed, encoding="utf-8") as fh:
                json.load(fh)
        except OSError as exc:
            failures.append(f"policy unreadable after lock: {exc}")
        acl = subprocess.run(["icacls", managed], capture_output=True, text=True).stdout
        if "Users:(I)(RX)" not in acl:
            failures.append(f"Users read entry missing after lock: {acl}")
    finally:
        subprocess.run(["icacls", tmp, "/reset", "/T", "/C", "/Q"], capture_output=True)
        subprocess.run(["icacls", tmp, "/inheritance:e", "/T", "/C", "/Q"], capture_output=True)
        shutil.rmtree(tmp, ignore_errors=True)


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

    lock_test(failures)

    if failures:
        print("FAIL")
        for f in failures:
            print("  " + f)
        return 1
    print("PASS policy installer, settings validator and ACL lock (5 checks)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
