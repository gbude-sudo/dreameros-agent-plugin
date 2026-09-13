#!/usr/bin/env python3
"""Bounded standard-library Gateway receipt verification for client adapters."""
from __future__ import annotations
import hashlib, json, re, sys
from dataclasses import asdict, dataclass
from typing import Any, Callable
from urllib.error import URLError
from urllib.request import Request, urlopen

SCHEMA_VERSION = "dreameros-gateway-lockstep-v3"
INTENT_ENVELOPE_SCHEMA = "dreameros-intent-envelope-v1"
RECEIPT_EVENT_SCHEMA = "dreameros-receipt-event-v1"
MAX_RECORD_BYTES = 8192
TERMINAL_STATES = frozenset({"SUCCESS", "NO-OP", "BLOCKED", "STALLED", "EXHAUSTED"})
CLIENT_CAPABILITY_MATRIX = {"claude_stop":{"event":"Stop","enforce":False},"cursor_after_mcp":{"event":"afterMCPExecution","enforce":False}}
MANAGED_ARTIFACTS = {"shared_verifier":"gates/gateway_lockstep.py","claude_stop_adapter":"install/claude-code/payload/settings.fragment.json","cursor_mcp_adapter":"cursor/hooks/dreameros_cursor_hook.py"}
HOOK_EVENT_ADAPTERS = {"claude_stop":{"evidence_field":None},"cursor_after_mcp":{"evidence_field":"gateway_lockstep_evidence"}}
_ANCHOR = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{7,127}\Z")
Transport = Callable[[str], Any]
@dataclass(frozen=True)
class Verdict:
 status: str; ok: bool; reason: str
 def to_dict(self)->dict[str,Any]: return asdict(self)
def _load(v:Any)->Any: return json.loads(v) if isinstance(v,str) else v
def _canon(v:Any)->bytes: return json.dumps(v,sort_keys=True,separators=(",", ":")).encode()
def _v(s:str,r:str,ok:bool=False)->Verdict: return Verdict(s,ok,r)
def https_transport(url:str)->Any:
 if not url.startswith("https://"): raise ValueError("receipt verify URL must use HTTPS")
 with urlopen(Request(url,headers={"Accept":"application/json"}),timeout=3) as response:
  if response.status != 200: raise URLError("non-200 receipt verify response")
  return json.loads(response.read().decode("utf-8"))
def verify_record(record:Any,tool_input:Any,transport:Transport= https_transport)->Verdict:
 try: record,tool_input=_load(record),_load(tool_input)
 except Exception: return _v("CONFIGURED","record or tool input is malformed")
 if not isinstance(tool_input,dict) or set(tool_input)!={"skill","content"} or tool_input.get("skill")!="auto" or not isinstance(tool_input.get("content"),str) or not tool_input["content"].strip(): return _v("CONFIGURED","actual dreameros_skill input is not the portable auto path")
 if not isinstance(record,dict) or len(_canon(record))>MAX_RECORD_BYTES or set(record)!={"schema_version","intent_envelope_schema","receipt","receipt_verify_url"} or record.get("schema_version")!=SCHEMA_VERSION or record.get("intent_envelope_schema")!=INTENT_ENVELOPE_SCHEMA: return _v("CONFIGURED","record schema is missing or unsupported")
 receipt=record["receipt"]; keys={"schema_version","id","intent_anchor","terminal_state","request_sha256"}
 if not isinstance(receipt,dict) or set(receipt)!=keys or receipt.get("schema_version")!=RECEIPT_EVENT_SCHEMA: return _v("INVOKED","receipt is missing or malformed")
 url=record.get("receipt_verify_url")
 if not isinstance(url,str) or not url.startswith("https://") or "/receipts/" not in url or receipt["id"] not in url: return _v("INVOKED","Gateway receipt verify URL is missing or malformed")
 if not isinstance(receipt.get("intent_anchor"),str) or _ANCHOR.fullmatch(receipt["intent_anchor"]) is None or receipt.get("terminal_state") not in TERMINAL_STATES or receipt.get("request_sha256")!=hashlib.sha256(_canon(tool_input)).hexdigest(): return _v("INVOKED","receipt does not bind actual input and signed intent anchor")
 try: verified=transport(url)
 except (OSError, URLError, TimeoutError, ValueError): return _v("OFFLINE","Gateway receipt verification is unavailable")
 if not isinstance(verified,dict): return _v("UNSUPPORTED","Gateway receipt verify response is malformed")
 expected={"id":receipt["id"],"intent_anchor":receipt["intent_anchor"],"terminal_state":receipt["terminal_state"],"request_sha256":receipt["request_sha256"],"verified":True}
 if verified!=expected: return _v("INVOKED","Gateway receipt verification did not match this input")
 return _v("TERMINAL","Gateway verified this input and terminal receipt",True)
def extract_from_host_payload(payload:dict[str,Any],transport:Transport=https_transport)->Verdict:
 try: result,tool_input=_load(payload.get("result_json",payload.get("tool_output"))),_load(payload.get("tool_input"))
 except Exception: return _v("UNSUPPORTED","host event lacks readable tool input or result")
 if not isinstance(result,dict) or "gateway_lockstep_evidence" not in result:return _v("UNSUPPORTED","host event does not supply Gateway Lockstep evidence")
 return verify_record(result["gateway_lockstep_evidence"],tool_input,transport)
def main()->int:
 try: payload=_load(sys.stdin.read())
 except Exception:return 0
 if not isinstance(payload,dict) or payload.get("stop_hook_active") is True:return 0
 print(json.dumps({"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"GATEWAY LOCKSTEP: UNSUPPORTED. Claude Stop lacks signed MCP input and receipt evidence. This is advisory only."}},separators=(",", ":")));return 0
if __name__=="__main__":raise SystemExit(main())
