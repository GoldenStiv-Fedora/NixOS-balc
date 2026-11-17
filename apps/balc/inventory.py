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

import vault
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


def parse_time(value: Any) -> datetime:
    """Разобрать ISO-время; некорректное значение считается самым старым."""
    if not isinstance(value, str) or not value:
        return datetime.min.replace(tzinfo=timezone.utc)
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return datetime.min.replace(tzinfo=timezone.utc)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def normalized_pcs(source: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    result: Dict[str, Dict[str, Any]] = {}
    for mac, record in (source.get("pcs") or {}).items():
        if isinstance(record, dict):
            result[str(mac).upper()] = record
    return result


def merge_records(*records: Dict[str, Any]) -> Dict[str, Any]:
    """Слить записи об одном ПК, не теряя изменений с других машин.

    Имя берётся из записи с самым свежим updated_at, IP — с самым свежим
    last_seen. Остальные поля объединяются, побеждает более поздняя запись.
    """
    items = [record for record in records if isinstance(record, dict)]
    if not items:
        return {}

    merged: Dict[str, Any] = {}
    for item in items:
        merged.update(item)

    named = [item for item in items if str(item.get("name") or "").strip()]
    if named:
        merged["name"] = max(
            enumerate(named),
            key=lambda pair: (parse_time(pair[1].get("updated_at")), pair[0]),
        )[1]["name"]

    addressed = [item for item in items if str(item.get("ip") or "").strip()]
    if addressed:
        merged["ip"] = max(
            enumerate(addressed),
            key=lambda pair: (parse_time(pair[1].get("last_seen")), pair[0]),
        )[1]["ip"]

    for key in ("last_seen", "updated_at"):
        values = [item.get(key) for item in items if item.get(key)]
        if values:
            merged[key] = max(values, key=parse_time)
    return merged


class Inventory:
    def __init__(self):
        self.pcs: Dict[str, Dict[str, Any]] = {}
        self.scan_subnets: List[str] = []
        self.source = "пусто"
        self.last_error = ""
        self.session_token = ""
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

    def _fetch_remote_api(self, token: str) -> Tuple[Dict[str, Any], str]:
        """Прочитать inventory.json через API вместе с текущим sha."""
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
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return {}, ""
            raise

        sha = str(current.get("sha") or "")
        content = current.get("content") or ""
        if not content:
            return {}, sha
        try:
            decoded = base64.b64decode(content).decode("utf-8")
            data = json.loads(decoded)
        except (ValueError, json.JSONDecodeError, UnicodeDecodeError):
            return {}, sha
        return (data if isinstance(data, dict) else {}), sha

    def _load_sources(self, remote: Dict[str, Any]) -> None:
        system = read_json(SYSTEM_INVENTORY)
        local = read_json(LOCAL_INVENTORY)
        merged: Dict[str, Dict[str, Any]] = {}
        for source in (system, remote, local):
            for mac, record in normalized_pcs(source).items():
                merged[mac] = merge_records(merged.get(mac, {}), record)

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

    def _merge_data(self, remote: Dict[str, Any]) -> Dict[str, Any]:
        """Слить текущее состояние с GitHub и локальными изменениями."""
        merged_pcs = normalized_pcs(remote)
        for mac, record in self.pcs.items():
            key = str(mac).upper()
            merged_pcs[key] = merge_records(merged_pcs.get(key, {}), record)

        subnets: List[str] = []
        for source in (remote, {"scan_subnets": self.scan_subnets}):
            for subnet in source.get("scan_subnets") or []:
                if isinstance(subnet, str) and subnet not in subnets:
                    subnets.append(subnet)

        return {
            "pcs": merged_pcs,
            "scan_subnets": subnets,
            "updated_at": utc_now(),
        }

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
        """Сохранить имя локально. Отправка в GitHub — отдельным push()."""
        key = mac.upper()
        record = self.pcs.setdefault(key, {})
        record["name"] = name.strip()
        record["updated_at"] = utc_now()
        self._save_local()
        return True, "имя сохранено локально"

    def set_scan_subnets(self, subnets: List[str]) -> Tuple[bool, str]:
        """Сохранить подсети локально. Отправка в GitHub — отдельным push()."""
        self.scan_subnets = [subnet.strip() for subnet in subnets if subnet.strip()]
        self._save_local()
        return True, "подсети сохранены локально"

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

    def vault_available(self) -> bool:
        """Есть ли зашифрованный файл токена."""
        return vault.vault_exists()

    def has_token(self) -> bool:
        return bool(self._token())

    def unlock(self, password: str) -> Tuple[bool, str]:
        """Расшифровать token.enc и держать токен в памяти до выхода."""
        path = vault.vault_path()
        try:
            token = vault.decrypt_token(password, path)
        except vault.VaultError as exc:
            return False, str(exc)
        self.session_token = token
        return True, "токен расшифрован"

    def forget_token(self) -> None:
        self.session_token = ""

    def _token(self) -> str:
        # Приоритет: переменная окружения, расшифрованный токен, старый
        # открытый файл (на случай, если владелец ещё не перешёл на token.enc).
        token = os.environ.get("BALC_GITHUB_TOKEN", "").strip()
        if token:
            return token
        if self.session_token:
            return self.session_token
        try:
            return GITHUB_TOKEN_FILE.read_text(encoding="utf-8").strip()
        except OSError:
            return ""

    def push(self) -> Tuple[bool, str]:
        token = self._token()
        if not token:
            if self.vault_available():
                return False, "токен заблокирован; введите мастер-пароль"
            return False, "токен GitHub не задан; имена сохранены локально"

        last_error = ""
        for _ in range(3):
            try:
                remote, sha = self._fetch_remote_api(token)
            except urllib.error.HTTPError as exc:
                return False, f"GitHub API: {exc.code}"
            except (urllib.error.URLError, OSError, json.JSONDecodeError) as exc:
                return False, f"GitHub API: {exc}"

            # Перед записью обязательно перечитываем GitHub и сливаем данные:
            # иначе ПК с устаревшей копией затрёт имена, сохранённые другими.
            merged = self._merge_data(remote)
            self.pcs = merged["pcs"]
            self.scan_subnets = merged["scan_subnets"]
            self._save_local()

            content = json.dumps(
                merged,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            ) + "\n"
            encoded = base64.b64encode(content.encode("utf-8")).decode("ascii")

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
                self.source = "GitHub"
                return True, "инвентарь отправлен в GitHub"
            except urllib.error.HTTPError as exc:
                if exc.code in (409, 422):
                    last_error = str(exc.code)
                    continue
                return False, f"GitHub API: {exc.code}"
            except (urllib.error.URLError, OSError) as exc:
                return False, f"GitHub API: {exc}"
        return False, f"GitHub API: конфликт версий ({last_error}), повторите позже"
