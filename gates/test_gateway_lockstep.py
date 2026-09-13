import hashlib,json,unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError

from gates.gateway_lockstep import MAX_RECORD_BYTES, extract_from_host_payload, https_transport, verify_record
def build(content="x"):
 tool={"skill":"auto","content":content}; receipt={"schema_version":"dreameros-receipt-event-v1","id":"receipt-12345678","intent_anchor":"anchor-12345678","terminal_state":"SUCCESS","request_sha256":hashlib.sha256(json.dumps(tool,sort_keys=True,separators=(",", ":")).encode()).hexdigest()}; record={"schema_version":"dreameros-gateway-lockstep-v3","intent_envelope_schema":"dreameros-intent-envelope-v1","receipt":receipt,"receipt_verify_url":"https://mcp.dreameros.app/api/v1/receipts/receipt-12345678/verify"}; verified={"id":receipt["id"],"intent_anchor":receipt["intent_anchor"],"terminal_state":receipt["terminal_state"],"request_sha256":receipt["request_sha256"],"verified":True};return tool,record,verified
class TestLockstep(unittest.TestCase):
 def test_clean_machine_stdlib_only(self): tool,r,v=build();self.assertEqual(verify_record(r,tool,lambda _:v).status,"TERMINAL")
 def test_missing_receipt(self):tool,r,v=build();r["receipt"]={};self.assertEqual(verify_record(r,tool,lambda _:v).status,"INVOKED")
 def test_fabricated_input_anchor(self):tool,r,v=build();tool["intent_key"]="fake";self.assertEqual(verify_record(r,tool,lambda _:v).status,"CONFIGURED")
 def test_wrong_input_hash(self):tool,r,v=build();self.assertEqual(verify_record(r,{"skill":"auto","content":"other"},lambda _:v).status,"INVOKED")
 def test_offline(self):tool,r,v=build();self.assertEqual(verify_record(r,tool,lambda _:(_ for _ in ()).throw(OSError())).status,"OFFLINE")
 def test_unsupported_host(self):self.assertEqual(extract_from_host_payload({},lambda _:{}).status,"UNSUPPORTED")
 def test_wrong_host_is_rejected_before_transport(self):
  tool,r,_=build();r["receipt_verify_url"]="https://evil.example/api/v1/receipts/receipt-12345678/verify";self.assertEqual(verify_record(r,tool,lambda _:self.fail("transport called")).status,"INVOKED")
 def test_wrong_host_transport_rejects_url(self):
  with self.assertRaises(ValueError): https_transport("https://evil.example/api/v1/receipts/receipt-12345678/verify")
 def test_redirect_is_unsupported(self):
  tool,r,_=build();self.assertEqual(verify_record(r,tool,lambda url:(_ for _ in ()).throw(HTTPError(url,302,"redirect",None,None))).status,"UNSUPPORTED")
 def test_oversized_transport_response_is_offline(self):
  class Response:
   def __enter__(self):return self
   def __exit__(self,*_):return False
   def read(self,_):return b"x"*(MAX_RECORD_BYTES+1)
  class Opener:
   def open(self,*_,**__):return Response()
  with patch("gates.gateway_lockstep.build_opener",return_value=Opener()):
   with self.assertRaises(ValueError): https_transport("https://mcp.dreameros.app/api/v1/receipts/receipt-12345678/verify")
  tool,r,_=build();self.assertEqual(verify_record(r,tool,lambda _:(_ for _ in ()).throw(ValueError("oversized"))).status,"OFFLINE")
 def test_404_is_unsupported(self):
  tool,r,_=build();self.assertEqual(verify_record(r,tool,lambda url:(_ for _ in ()).throw(HTTPError(url,404,"missing",None,None))).status,"UNSUPPORTED")
 def test_network_failure_is_offline(self):
  tool,r,_=build();self.assertEqual(verify_record(r,tool,lambda _:(_ for _ in ()).throw(URLError("network"))).status,"OFFLINE")
 def test_non_string_receipt_id_is_rejected(self):
  tool,r,_=build();r["receipt"]["id"]=123;self.assertEqual(verify_record(r,tool,lambda _:self.fail("transport called")).status,"INVOKED")
