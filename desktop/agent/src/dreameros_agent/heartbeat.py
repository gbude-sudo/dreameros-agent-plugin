"""Privacy-bounded heartbeat payloads."""
from __future__ import annotations

from dataclasses import asdict, dataclass


@dataclass(frozen=True)
class ClientHeartbeat:
    vendor: str
    detected: bool
    config_state: str
    mcp_state: str
    managed_artifact_sha256: str | None


def build_heartbeat(
    *,
    installation_id: str,
    agent_version: str,
    architecture: str,
    os_family: str,
    boot_contract_version: str,
    manifest_schema_version: str,
    boot_pack_version: str,
    bootpack_sha256: str,
    adapters: list[ClientHeartbeat],
    event: str,
    repair_result: str,
) -> dict:
    if event not in {"start", "scheduled", "repair", "update"}:
        raise ValueError("unsupported heartbeat event")
    if repair_result not in {"unchanged", "repaired", "refused"}:
        raise ValueError("unsupported repair result")
    vendors = {adapter.vendor for adapter in adapters}
    if vendors != {"claude", "codex", "cursor"} or len(adapters) != 3:
        raise ValueError("heartbeat requires one Claude, Codex, and Cursor observation")
    if not any(adapter.detected for adapter in adapters):
        raise ValueError("heartbeat requires at least one detected adapter")
    return {
        "installation_id": installation_id,
        "agent_version": agent_version,
        "channel": "stable",
        "os_family": os_family,
        "architecture": architecture,
        "boot_contract_version": boot_contract_version,
        "manifest_schema_version": manifest_schema_version,
        "boot_pack_version": boot_pack_version,
        "boot_pack_sha256": bootpack_sha256,
        "adapters": [asdict(adapter) for adapter in adapters],
        "event": event,
        "repair_result": repair_result,
    }
