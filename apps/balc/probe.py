"""Сбор состояния одного ПК по SSH."""

import json
import time
from typing import Dict

from config import STATUS_FILE
from models import PcStatus
from ssh_client import SshClient, SshError

MARK = "==="

PROBE_SCRIPT = f"""
echo "{MARK}MAC{MARK}"
IFACE=$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \\([^ ]*\\).*/\\1/p' | head -n1)
if [ -n "$IFACE" ] && [ -r "/sys/class/net/$IFACE/address" ]; then
  cat "/sys/class/net/$IFACE/address"
else
  cat /sys/class/net/*/address 2>/dev/null | grep -v '^00:00:00:00:00:00$' | head -n1
fi
echo "{MARK}HOSTNAME{MARK}"
hostname 2>/dev/null || true
echo "{MARK}MACHINE_ID{MARK}"
cat /etc/machine-id 2>/dev/null || true
echo "{MARK}NIXOS_VERSION{MARK}"
nixos-version 2>/dev/null || true
echo "{MARK}REVISION{MARK}"
nixos-version --configuration-revision 2>/dev/null || cat /run/current-system/configurationRevision 2>/dev/null || true
echo "{MARK}GENERATION{MARK}"
readlink -f /run/current-system 2>/dev/null || true
echo "{MARK}UPTIME{MARK}"
uptime -p 2>/dev/null || true
echo "{MARK}DISK{MARK}"
df -h / 2>/dev/null | tail -n1 || true
echo "{MARK}STORE{MARK}"
timeout 5 du -sh /nix/store 2>/dev/null || true
echo "{MARK}SYNC_ACTIVE{MARK}"
systemctl is-active nixos-git-sync.service 2>/dev/null || true
echo "{MARK}REBUILD_ACTIVE{MARK}"
systemctl is-active nixos-fleet-rebuild.service 2>/dev/null || true
echo "{MARK}STATUS{MARK}"
cat {STATUS_FILE} 2>/dev/null || true
echo "{MARK}END{MARK}"
"""


def normalize_mac(value: str) -> str:
    text = (value or "").strip().upper().replace("-", ":")
    if text.count(":") != 5:
        return ""
    return text


def parse_sections(text: str) -> Dict[str, str]:
    sections: Dict[str, str] = {}
    current = None
    lines = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith(MARK) and stripped.endswith(MARK) and len(stripped) > len(MARK) * 2:
            if current is not None:
                sections[current] = "\n".join(lines).strip()
            current = stripped.strip("=")
            lines = []
        elif current is not None:
            lines.append(line)
    if current is not None:
        sections[current] = "\n".join(lines).strip()
    return sections


def probe_host(ip: str) -> PcStatus:
    status = PcStatus(ip=ip, checked_at=time.time())
    try:
        with SshClient(ip) as ssh:
            code, out, err = ssh.run(PROBE_SCRIPT, timeout=30)
    except SshError as exc:
        status.online = False
        status.error = str(exc)
        return status

    if code != 0 and not out:
        status.error = err.strip() or f"код {code}"
        return status

    data = parse_sections(out)
    status.online = True
    status.mac = normalize_mac(data.get("MAC", ""))
    status.hostname = data.get("HOSTNAME", "").strip()
    status.machine_id = data.get("MACHINE_ID", "").strip()
    status.nixos_version = " ".join(data.get("NIXOS_VERSION", "").split())
    status.generation = data.get("GENERATION", "").strip()
    status.revision = data.get("REVISION", "").strip()
    status.uptime = data.get("UPTIME", "").strip()
    status.disk = " ".join(data.get("DISK", "").split())
    status.store_size = data.get("STORE", "").strip()
    status.sync_active = data.get("SYNC_ACTIVE", "").strip()
    status.rebuild_active = data.get("REBUILD_ACTIVE", "").strip()

    raw_status = data.get("STATUS", "").strip()
    if raw_status:
        try:
            parsed = json.loads(raw_status)
            if isinstance(parsed, dict):
                status.status = parsed
        except json.JSONDecodeError:
            status.status = {"last_error": "не удалось прочитать status.json"}

    if not status.mac:
        machine_id = status.machine_id or ip
        status.mac = f"id:{machine_id}"
    return status
