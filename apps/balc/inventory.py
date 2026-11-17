"""Инвентарь парка: MAC -> имя, IP, подсети."""

import base64
import json
import os
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Tuple

from config import (
    GITHUB_TOKEN_FILE,
    INVENTORY_API_URL,
    INVENTORY_RAW_URL,
    LOCAL_INVENTORY,
    SYSTEM_INVENTORY,
)


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def read_json(path: Path) -> Dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def write_json(path: Path, data: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
    tmp.replace(path)


class Inventory:
    def __init__(self):
        self.pcs: Dict[str, Dict[str, Any]] = {}
        self.scan_subnets: List[str] = []
        self.source = "пусто"
        self.last_error = ""
        self._remote_loaded_at = 0.0
        self._load_sources({})

    def _fetch_remote(self) -> Dict[str, Any]:
        request = urllib.request.Request(
            INVENTORY_RAW_URL,
            headers={"User-Agent": "balc/0.1"},
        )
        try:
            with urllib.request.urlopen(request, timeout=8) as response:
                data = json.loads(response.read().decode("utf-8"))
                return data if isinstance(data, dict) else {}
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as exc:
            self.last_error = f"GitHub: {exc}"
            return {}

    def _load_sources(self, remote: Dict[str, Any]) -> None:
        system = read_json(SYSTEM_INVENTORY)
        local = read_json(LOCAL_INVENTORY)
        merged: Dict[str, Dict[str, Any]] = {}
        for source in (system, remote, local):
            for mac, record in (source.get("pcs") or {}).items():
                if not isinstance(record, dict):
                    continue
                key = str(mac).upper()
                previous = merged.get(key, {})
                combined = dict(previous)
                combined.update(record)
                candidates = [
                    item
                    for item in (previous, record)
                    if str(item.get("name") or "").strip()
                ]
                if candidates:
                    combined["name"] = max(
                        candidates,
                        key=lambda item: str(item.get("updated_at") or ""),
                    ).get("name", "")
                merged[key] = combined

        self.pcs = merged
        subnets: List[str] = []
        for source in (system, remote, local):
            for subnet in source.get("scan_subnets") or []:
                if isinstance(subnet, str) and subnet not in subnets:
                    subnets.append(subnet)
        self.scan_subnets = subnets

        if remote:
            self.source = "GitHub + локально"
        elif local:
            self.source = "локально"
        elif system:
            self.source = "система"
        else:
            self.source = "пусто"

    def reload(self, force: bool = False) -> None:
        now = time.time()
        if not force and now - self._remote_loaded_at < 300:
            return
        remote = self._fetch_remote()
        self._load_sources(remote)
        self._remote_loaded_at = now

    def all(self) -> Dict[str, Dict[str, Any]]:
        return self.pcs

    def name_for(self, mac: str) -> str:
        return str(self.pcs.get(mac.upper(), {}).get("name") or "")

    def ip_for(self, mac: str) -> str:
        return str(self.pcs.get(mac.upper(), {}).get("ip") or "")

    def set_ip(self, mac: str, ip: str) -> None:
        if not mac:
            return
        key = mac.upper()
        record = self.pcs.setdefault(key, {})
        if record.get("ip") != ip:
            record["ip"] = ip
            record["last_seen"] = utc_now()
            self._save_local()

    def set_name(self, mac: str, name: str) -> Tuple[bool, str]:
        key = mac.upper()
        record = self.pcs.setdefault(key, {})
        record["name"] = name.strip()
        record["updated_at"] = utc_now()
        self._save_local()
        return self.push()

    def set_scan_subnets(self, subnets: List[str]) -> Tuple[bool, str]:
        self.scan_subnets = [subnet.strip() for subnet in subnets if subnet.strip()]
        self._save_local()
        return self.push()

    def add_discovered(self, mac: str, ip: str) -> None:
        key = mac.upper()
        record = self.pcs.setdefault(key, {})
        changed = False
        if not record.get("ip"):
            record["ip"] = ip
            changed = True
        if not record.get("last_seen"):
            record["last_seen"] = utc_now()
            changed = True
        if changed:
            self._save_local()

    def _local_data(self) -> Dict[str, Any]:
        return {
            "pcs": self.pcs,
            "scan_subnets": self.scan_subnets,
            "updated_at": utc_now(),
        }

    def _save_local(self) -> None:
        write_json(LOCAL_INVENTORY, self._local_data())

    def _token(self) -> str:
        token = os.environ.get("BALC_GITHUB_TOKEN", "").strip()
        if token:
            return token
        try:
            return GITHUB_TOKEN_FILE.read_text(encoding="utf-8").strip()
        except OSError:
            return ""

    def push(self) -> Tuple[bool, str]:
        token = self._token()
        if not token:
            return False, "токен GitHub не задан; имена сохранены локально"

        content = json.dumps(
            self._local_data(),
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        ) + "\n"
        encoded = base64.b64encode(content.encode("utf-8")).decode("ascii")

        for _ in range(2):
            sha = None
            request = urllib.request.Request(
                INVENTORY_API_URL,
                headers={
                    "Authorization": f"Bearer {token}",
                    "Accept": "application/vnd.github+json",
                    "User-Agent": "balc/0.1",
                },
            )
            try:
                with urllib.request.urlopen(request, timeout=10) as response:
                    current = json.loads(response.read().decode("utf-8"))
                    sha = current.get("sha")
            except urllib.error.HTTPError as exc:
                if exc.code != 404:
                    return False, f"GitHub API: {exc.code}"
            except (urllib.error.URLError, OSError, json.JSONDecodeError) as exc:
                return False, f"GitHub API: {exc}"

            payload = {
                "message": "balc: обновление инвентаря",
                "content": encoded,
                "branch": "main",
            }
            if sha:
                payload["sha"] = sha

            request = urllib.request.Request(
                INVENTORY_API_URL,
                data=json.dumps(payload).encode("utf-8"),
                method="PUT",
                headers={
                    "Authorization": f"Bearer {token}",
                    "Accept": "application/vnd.github+json",
                    "Content-Type": "application/json",
                    "User-Agent": "balc/0.1",
                },
            )
            try:
                with urllib.request.urlopen(request, timeout=15) as response:
                    response.read()
                return True, "инвентарь отправлен в GitHub"
            except urllib.error.HTTPError as exc:
                if exc.code == 409:
                    continue
                return False, f"GitHub API: {exc.code}"
            except (urllib.error.URLError, OSError) as exc:
                return False, f"GitHub API: {exc}"
        return False, "GitHub API: конфликт версий, повторите позже"
