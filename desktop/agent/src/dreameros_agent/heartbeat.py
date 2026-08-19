"""Privacy-bounded heartbeat payloads."""
from __future__ import annotations

from dataclasses import asdict, dataclass


@dataclass(frozen=True)
class ClientHeartbeat:
    id: str
    detected: bool
    adapter_version: str
    config_state: str
    mcp_state: str


def build_heartbeat(
    *,
    installation_id: str,
    agent_version: str,
    architecture: str,
    manifest_sha256: str,
    bootpack_sha256: str,
    clients: list[ClientHeartbeat],
    event: str,
    repair_result: str,
) -> dict:
    if event not in {"start", "scheduled", "repair", "update"}:
        raise ValueError("unsupported heartbeat event")
    if repair_result not in {"unchanged", "repaired", "refused"}:
        raise ValueError("unsupported repair result")
    return {
        "installation_id": installation_id,
        "agent_version": agent_version,
        "channel": "stable",
        "os_family": "windows",
        "architecture": architecture,
        "manifest_sha256": manifest_sha256,
        "bootpack_sha256": bootpack_sha256,
        "clients": [asdict(client) for client in clients],
        "event": event,
        "repair_result": repair_result,
    }
