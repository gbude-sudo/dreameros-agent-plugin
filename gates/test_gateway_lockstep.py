import hashlib,json,unittest
from gates.gateway_lockstep import extract_from_host_payload,verify_record
def build(content="x"):
 tool={"skill":"auto","content":content}; receipt={"schema_version":"dreameros-receipt-event-v1","id":"receipt-12345678","intent_anchor":"anchor-12345678","terminal_state":"SUCCESS","request_sha256":hashlib.sha256(json.dumps(tool,sort_keys=True,separators=(",", ":")).encode()).hexdigest()}; record={"schema_version":"dreameros-gateway-lockstep-v3","intent_envelope_schema":"dreameros-intent-envelope-v1","receipt":receipt,"receipt_verify_url":"https://mcp.dreameros.app/api/v1/receipts/receipt-12345678/verify"}; verified={"id":receipt["id"],"intent_anchor":receipt["intent_anchor"],"terminal_state":receipt["terminal_state"],"request_sha256":receipt["request_sha256"],"verified":True};return tool,record,verified
class TestLockstep(unittest.TestCase):
 def test_clean_machine_stdlib_only(self): tool,r,v=build();self.assertEqual(verify_record(r,tool,lambda _:v).status,"TERMINAL")
 def test_missing_receipt(self):tool,r,v=build();r["receipt"]={};self.assertEqual(verify_record(r,tool,lambda _:v).status,"INVOKED")
 def test_fabricated_input_anchor(self):tool,r,v=build();tool["intent_key"]="fake";self.assertEqual(verify_record(r,tool,lambda _:v).status,"CONFIGURED")
 def test_wrong_input_hash(self):tool,r,v=build();self.assertEqual(verify_record(r,{"skill":"auto","content":"other"},lambda _:v).status,"INVOKED")
 def test_offline(self):tool,r,v=build();self.assertEqual(verify_record(r,tool,lambda _:(_ for _ in ()).throw(OSError())).status,"OFFLINE")
 def test_unsupported_host(self):self.assertEqual(extract_from_host_payload({},lambda _:{}).status,"UNSUPPORTED")
