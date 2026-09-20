import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("release_tool", Path(__file__).with_name("prepare_jms_release.py"))
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)

class ReleaseToolTests(unittest.TestCase):
    def test_private_material_refused(self):
        for name in ["android/app/key.properties", "android/app/private.jks", ".env", "docs/private.pem", "../escape"]:
            with self.assertRaises(ValueError):
                tool.validate_source_name(name)

    def test_scope_is_allowlisted(self):
        self.assertTrue(tool.validate_source_name("pubspec.lock"))
        self.assertTrue(tool.validate_source_name("lib/main.dart"))
        self.assertFalse(tool.validate_source_name("artifacts/private.apk.txt"))
        self.assertFalse(tool.validate_source_name(".codex/private.json"))

    def test_secret_scan(self):
        self.assertIsNotNone(tool.SECRET.search(b"-----BEGIN " + b"PRIVATE KEY-----"))
        self.assertIsNone(tool.SECRET.search(b"public source without credentials"))

    def test_publication_guard(self):
        record = {"signerSha256": tool.TEST_CERT, "testSigning": True, "repository": "", "nativeSourceAudit": "BLOCKED"}
        with self.assertRaises(ValueError):
            tool.validate_publication(record)
        record.update(repository="jim608/JMS-Android")
        with self.assertRaises(ValueError):
            tool.validate_publication(record)
        record["signingCustodyAudit"] = "PASS"
        with self.assertRaises(ValueError):
            tool.validate_publication(record)
        record["nativeSourceAudit"] = "PASS"
        tool.validate_publication(record)
        record["signerSha256"] = "untrusted"
        with self.assertRaises(ValueError):
            tool.validate_publication(record)

    def test_source_binding_refuses_drift_or_missing_file(self):
        original = tool.ROOT
        with tempfile.TemporaryDirectory() as directory:
            tool.ROOT = Path(directory)
            source = tool.ROOT / "source.dart"
            source.write_text("original", encoding="utf-8")
            record = {"inputs": [{"path": "source.dart", "sha256": tool.sha256(source)}]}
            tool.require_bound_sources(record)
            source.write_text("changed", encoding="utf-8")
            with self.assertRaises(ValueError):
                tool.require_bound_sources(record)
        tool.ROOT = original

if __name__ == "__main__":
    unittest.main()
