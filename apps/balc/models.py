"""Модели данных приложения balc."""

from dataclasses import asdict, dataclass, field
from typing import Any, Dict


@dataclass
class PcStatus:
    mac: str = ""
    ip: str = ""
    hostname: str = ""
    machine_id: str = ""
    nixos_version: str = ""
    generation: str = ""
    revision: str = ""
    uptime: str = ""
    disk: str = ""
    store_size: str = ""
    rebuild_active: str = ""
    sync_active: str = ""
    status: Dict[str, Any] = field(default_factory=dict)
    online: bool = False
    error: str = ""
    checked_at: float = 0.0

    @property
    def last_result(self) -> str:
        return str(self.status.get("last_result") or "")

    @property
    def last_error(self) -> str:
        return str(self.status.get("last_error") or "")

    @property
    def success_commit(self) -> str:
        return str(self.status.get("last_success_commit") or "")

    @property
    def remote_commit(self) -> str:
        return str(self.status.get("remote_commit") or "")

    @property
    def last_success_at(self) -> str:
        return str(self.status.get("last_success_at") or "")

    @property
    def last_attempt_at(self) -> str:
        return str(self.status.get("last_attempt_at") or "")

    @property
    def stale(self) -> bool:
        if not self.online:
            return False
        if not self.remote_commit:
            return False
        return self.success_commit != self.remote_commit

    @property
    def has_error(self) -> bool:
        if not self.online:
            return bool(self.error)
        if self.last_error:
            return True
        return self.last_result in {
            "build-failed",
            "switch-failed",
            "fetch-failed",
            "git-failed",
            "copy-failed",
            "app-failed",
        }

    @property
    def state_label(self) -> str:
        if not self.online:
            return "офлайн"
        if self.rebuild_active in {"active", "activating", "reloading"}:
            return "сборка"
        if self.last_result in {"building", "built", "switching"} and self.sync_active in {
            "active",
            "activating",
            "reloading",
        }:
            return "сборка"
        if self.has_error:
            return "ошибка"
        if self.stale:
            return "не пересобран"
        return "в сети"

    @staticmethod
    def short_commit(value: str) -> str:
        return value[:7] if value else "—"

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "PcStatus":
        allowed = set(cls.__dataclass_fields__)
        clean = {key: value for key, value in data.items() if key in allowed}
        return cls(**clean)
