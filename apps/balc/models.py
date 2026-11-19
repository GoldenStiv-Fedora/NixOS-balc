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
    def synced_commit(self) -> str:
        return str(self.status.get("last_synced_commit") or "")

    @property
    def stale(self) -> bool:
        """Требуется ли пересборка относительно известного этому ПК remote."""
        if not self.online:
            return False
        if not self.remote_commit:
            return False
        if self.success_commit == self.remote_commit:
            return False
        # Изменения уже подтянуты, но пересборка не нужна (инвентарь/картинки).
        if self.last_result == "assets-only" and self.synced_commit == self.remote_commit:
            return False
        if not self.success_commit:
            return True
        return True

    def is_syncing(self) -> bool:
        active = {"active", "activating", "reloading"}
        if self.rebuild_active in active or self.sync_active in active:
            return True
        if self.last_result in {"building", "built", "switching"}:
            return True
        return False

    def needs_fleet_update(self, target: str = "") -> bool:
        """Нужно ли действие, чтобы привести ПК к целевому коммиту парка."""
        if not target:
            target = self.remote_commit
        if not target:
            return False
        if self.is_syncing():
            return False
        if self.has_error:
            return True
        if self.remote_commit != target or self.synced_commit != target:
            return True
        if self.success_commit == target:
            return False
        if self.last_result == "assets-only" and self.synced_commit == target:
            return False
        return True

    def fleet_state(self, target: str = "") -> str:
        """Понятное состояние ПК относительно целевого коммита парка."""
        if not self.online:
            if target and self.needs_fleet_update_offline(target):
                return "оффлайн, требуется обновление"
            return "оффлайн"
        if self.is_syncing():
            return "обновляется"
        if self.has_error:
            return "ошибка"
        if not target:
            target = self.remote_commit
        if not target:
            return "в сети"
        if not self.needs_fleet_update(target):
            return "актуален"
        return "требуется обновление"

    def needs_fleet_update_offline(self, target: str = "") -> bool:
        """Был ли ПК неактуален на момент последней известной проверки."""
        if not target:
            return False
        known_remote = self.remote_commit
        known_synced = self.synced_commit
        known_success = self.success_commit
        if known_remote != target or known_synced != target:
            return True
        if known_success == target:
            return False
        if self.last_result == "assets-only" and known_synced == target:
            return False
        if self.last_result in {
            "build-failed",
            "switch-failed",
            "fetch-failed",
            "git-failed",
            "copy-failed",
            "app-failed",
        }:
            return True
        return False

    def update_hint(self, target: str = "") -> str:
        """Короткая причина, почему ПК неактуален."""
        if not target:
            target = self.remote_commit
        if not target:
            return ""
        if self.is_syncing():
            return "идёт синхронизация/сборка"
        if self.has_error:
            return self.last_error or self.error or "ошибка обновления"
        if self.remote_commit != target or self.synced_commit != target:
            return "не подтянул целевой коммит"
        if self.success_commit == target:
            return ""
        if self.last_result == "assets-only" and self.synced_commit == target:
            return "данные синхронизированы, пересборка не нужна"
        if self.success_commit != target:
            return "ожидает пересборки"
        return ""

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
