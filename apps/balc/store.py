"""Локальная история и последние известные состояния."""

import json
import time
from typing import Any, Dict, List, Optional

from config import LOCAL_HISTORY
from models import PcStatus


class History:
    def __init__(self):
        self.last_status: Dict[str, Dict[str, Any]] = {}
        self.events: List[Dict[str, Any]] = []
        self._last_save = 0.0
        self._load()

    def _load(self) -> None:
        try:
            data = json.loads(LOCAL_HISTORY.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                self.last_status = data.get("last_status") or {}
                self.events = data.get("events") or []
        except (OSError, json.JSONDecodeError):
            pass

    def _save(self, force: bool = False) -> None:
        now = time.time()
        if not force and now - self._last_save < 10:
            return
        LOCAL_HISTORY.parent.mkdir(parents=True, exist_ok=True)
        data = {
            "last_status": self.last_status,
            "events": self.events[-200:],
        }
        tmp = LOCAL_HISTORY.with_suffix(".tmp")
        tmp.write_text(
            json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        tmp.replace(LOCAL_HISTORY)
        self._last_save = now

    def remember(self, status: PcStatus) -> None:
        if status.mac:
            self.last_status[status.mac] = status.to_dict()
        self._save()

    def last(self, mac: str) -> Optional[PcStatus]:
        data = self.last_status.get(mac)
        return PcStatus.from_dict(data) if data else None

    def event(self, kind: str, message: str, mac: str = "") -> None:
        self.events.append(
            {
                "at": time.time(),
                "kind": kind,
                "message": message,
                "mac": mac,
            }
        )
        self.events = self.events[-200:]
        self._save(force=True)
