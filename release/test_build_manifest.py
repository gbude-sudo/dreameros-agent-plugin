from __future__ import annotations

import base64
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from jsonschema import validate


ROOT = Path(__file__).resolve().parents[1]


class BuildManifestTests(unittest.TestCase):
    def test_release_version_validation_fails_closed(self):
        path = ROOT / "release" / "validate_release_version.py"
        spec = importlib.util.spec_from_file_location("validate_release_version", path)
        module = importlib.util.module_from_spec(spec)
        assert spec and spec.loader
        spec.loader.exec_module(module)
        module.validate_release_version("0.2.0", ROOT)
        with self.assertRaises(ValueError):
            module.validate_release_version("0.2.1", ROOT)
        with self.assertRaises(ValueError):
            module.validate_release_version("0.2.0;echo-no", ROOT)

    def test_manifest_matches_schema_and_signature(self):
        with tempfile.TemporaryDirectory() as temp:
            assets = Path(temp)
            for name in (
                "DreamerOSAgentSetup.exe",
                "DreamerOSAgent.pkg",
                "dreameros-desktop-agent_0.2.0_amd64.deb",
                "dreameros-bootpack.zip",
                "source.md",
            ):
                (assets / name).write_bytes((name + "\n").encode("utf-8"))
            key = Ed25519PrivateKey.generate()
            raw_private = key.private_bytes(
                serialization.Encoding.Raw,
                serialization.PrivateFormat.Raw,
                serialization.NoEncryption(),
            )
            subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "release" / "build_manifest.py"),
                    "--asset-dir", str(assets),
                    "--version", "0.2.0",
                    "--tag", "desktop-v0.2.0",
                    "--repository", "gbude-sudo/dreameros-agent-plugin",
                    "--bootpack-source", str(assets / "source.md"),
                    "--key-id", "test-key",
                    "--private-key-env", "TEST_MANIFEST_PRIVATE_KEY_B64",
                    "--windows-subject", "DreamerOS Test",
                    "--linux-key-id", "test-linux-key",
                ],
                check=True,
                env={**os.environ, "TEST_MANIFEST_PRIVATE_KEY_B64": base64.b64encode(raw_private).decode("ascii")},
            )
            manifest_bytes = (assets / "release-manifest.json").read_bytes()
            manifest = json.loads(manifest_bytes)
            schema = json.loads((ROOT / "release" / "release-manifest.schema.json").read_text(encoding="utf-8"))
            validate(manifest, schema)
            signature = base64.b64decode((assets / "release-manifest.sig").read_text(encoding="ascii"), validate=True)
            key.public_key().verify(signature, manifest_bytes)


if __name__ == "__main__":
    unittest.main()
