import base64, hashlib, json, unittest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from gates.gateway_lockstep import extract_from_host_payload, verify_record

def build(content="x", state="SUCCESS"):
    tool = {"skill":"auto","content":content}; key = Ed25519PrivateKey.generate()
    signed = {"id":"receipt-12345678","intent_anchor":"anchor-12345678","terminal_state":state,"request_sha256":hashlib.sha256(json.dumps(tool,sort_keys=True,separators=(",", ":")).encode()).hexdigest()}
    raw = json.dumps(signed,sort_keys=True,separators=(",", ":")).encode(); public = key.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw)
    return tool, {"schema_version":"dreameros-gateway-lockstep-v2","intent_envelope_schema":"dreameros-intent-envelope-v1","receipt":{"schema_version":"dreameros-receipt-event-v1",**signed,"signed_payload_b64":base64.b64encode(raw).decode(),"signature_b64":base64.b64encode(key.sign(raw)).decode(),"key_id":"test-key"},"public_key_lookup":{"schema_version":"dreameros-receipt-key-v1","key_id":"test-key","public_key_b64":base64.b64encode(public).decode(),"source_url":"https://mcp.dreameros.app/.well-known/ctci-keys.json"}}

class TestLockstep(unittest.TestCase):
 def test_valid_terminal(self): tool, record=build(); self.assertEqual((verify_record(record,tool).status,verify_record(record,tool).ok),("TERMINAL",True))
 def test_missing_receipt(self): tool, record=build(); record["receipt"]={}; self.assertEqual(verify_record(record,tool).status,"INVOKED")
 def test_fabricated_input_anchor_rejected(self): tool, record=build(); tool["intent_key"]="fake"; self.assertEqual(verify_record(record,tool).status,"CONFIGURED")
 def test_wrong_input_hash_rejected(self): tool, record=build(); self.assertEqual(verify_record(record,{"skill":"auto","content":"other"}).status,"INVOKED")
 def test_tampered_signature_rejected(self): tool, record=build(); record["receipt"]["signature_b64"]="AAAA"; self.assertEqual(verify_record(record,tool).status,"INVOKED")
 def test_unsupported_host(self): self.assertEqual(extract_from_host_payload({}).status,"UNSUPPORTED")
