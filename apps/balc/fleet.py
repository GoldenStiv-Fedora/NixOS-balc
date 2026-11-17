"""Управление парком: опрос, обнаружение, пересборка."""

import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Callable, Dict, List, Optional, Tuple

from config import PROBE_WORKERS
from inventory import Inventory
from models import PcStatus
from notify import Notifier
from probe import probe_host
from rebuild import request_rebuild as ssh_request_rebuild
from rebuild import wait_for_rebuild
from scanner import local_subnets, scan_many
from store import History


class FleetManager:
    def __init__(self, inventory: Inventory, history: History, notifier: Notifier):
        self.inventory = inventory
        self.history = history
        self.notifier = notifier
        self.statuses: Dict[str, PcStatus] = {}
        self._last_discover = 0.0

    def rows(self) -> List[Tuple[str, Dict, PcStatus]]:
        records = self.inventory.all()
        keys = set(records) | set(self.statuses)
        result: List[Tuple[str, Dict, PcStatus]] = []
        for mac in keys:
            record = records.get(mac, {})
            status = self.statuses.get(mac)
            if status is None:
                status = self.history.last(mac)
                if status is not None:
                    status.online = False
                    status.error = status.error or "нет связи"
                else:
                    ip = str(record.get("ip") or "")
                    error = "ожидание проверки" if ip else "IP неизвестен — выполните поиск"
                    status = PcStatus(mac=mac, ip=ip, error=error)
            if not status.ip:
                status.ip = str(record.get("ip") or "")
            result.append((mac, record, status))
        return result

    def _targets(self) -> Dict[str, str]:
        targets: Dict[str, str] = {}
        for mac, record in self.inventory.all().items():
            ip = str(record.get("ip") or "")
            if ip:
                targets[mac] = ip
        for mac, status in self.statuses.items():
            if mac not in targets and status.ip:
                targets[mac] = status.ip
        return targets

    def _probe_many(
        self,
        targets: Dict[str, str],
        progress: Optional[Callable[[str], None]] = None,
    ) -> Dict[str, PcStatus]:
        results: Dict[str, PcStatus] = {}
        if not targets:
            return results

        if progress:
            progress(f"Опрос ПК: {len(targets)}")

        with ThreadPoolExecutor(max_workers=PROBE_WORKERS) as pool:
            futures = {
                pool.submit(probe_host, ip): (mac, ip)
                for mac, ip in targets.items()
            }
            for future in as_completed(futures):
                mac, ip = futures[future]
                try:
                    status = future.result()
                except Exception as exc:  # защита от неожиданной ошибки потока
                    status = PcStatus(
                        mac=mac,
                        ip=ip,
                        online=False,
                        error=str(exc),
                        checked_at=time.time(),
                    )
                if not status.mac:
                    status.mac = mac
                results[status.mac] = status
                if progress and status.online:
                    progress(f"В сети: {status.ip} ({status.mac})")
        return results

    def _discover(self, progress: Optional[Callable[[str], None]] = None) -> Dict[str, PcStatus]:
        subnets = self.inventory.scan_subnets or local_subnets()
        if not subnets:
            if progress:
                progress("Не удалось определить подсети для поиска")
            return {}

        if progress:
            progress(f"Поиск ПК: {', '.join(subnets)}")
        addresses = scan_many(subnets)
        self._last_discover = time.time()
        if progress:
            progress(f"SSH открыт на {len(addresses)} адресах")

        found: Dict[str, PcStatus] = {}
        if not addresses:
            return found

        with ThreadPoolExecutor(max_workers=PROBE_WORKERS) as pool:
            futures = {pool.submit(probe_host, ip): ip for ip in addresses}
            for future in as_completed(futures):
                ip = futures[future]
                try:
                    status = future.result()
                except Exception:
                    continue
                if not status.online or not status.mac:
                    continue
                found[status.mac] = status
                self.statuses[status.mac] = status
                self.history.remember(status)
                self.inventory.add_discovered(status.mac, ip)
                if progress:
                    progress(f"Найден: {ip} ({status.mac})")
        return found

    def refresh(
        self,
        discover: bool = False,
        progress: Optional[Callable[[str], None]] = None,
    ) -> Dict[str, PcStatus]:
        self.inventory.reload()
        targets = self._targets()

        found: Dict[str, PcStatus] = {}
        if discover or not targets:
            found = self._discover(progress)
            targets = self._targets()
            for mac in found:
                targets.pop(mac, None)

        results: Dict[str, PcStatus] = dict(found)
        results.update(self._probe_many(targets, progress))

        now = time.time()
        for mac, status in results.items():
            self.statuses[mac] = status
            self.history.remember(status)
            if status.online and status.ip:
                self.inventory.set_ip(mac, status.ip)

        for mac, ip in targets.items():
            if mac in results:
                continue
            previous = self.statuses.get(mac) or PcStatus(mac=mac, ip=ip)
            previous.online = False
            previous.error = "нет связи"
            previous.checked_at = now
            self.statuses[mac] = previous
            self.history.remember(previous)

        for mac, record in self.inventory.all().items():
            if mac in self.statuses:
                continue
            ip = str(record.get("ip") or "")
            error = "ожидание проверки" if ip else "IP неизвестен — выполните поиск"
            self.statuses[mac] = PcStatus(mac=mac, ip=ip, error=error)

        return self.statuses

    def display_name(self, mac: str) -> str:
        name = self.inventory.name_for(mac)
        if name:
            return name
        status = self.statuses.get(mac)
        if status and status.ip:
            return status.ip
        return mac

    def request_rebuild(self, mac: str) -> Tuple[bool, str]:
        status = self.statuses.get(mac)
        if status is None or not status.ip:
            return False, "неизвестен IP"
        if not status.online:
            return False, "ПК не в сети"
        ok, message = ssh_request_rebuild(status.ip)
        if ok:
            self.notifier.info(f"{self.display_name(mac)}: {message}")
            self.history.event("rebuild", message, mac)
        else:
            self.notifier.error(f"{self.display_name(mac)}: {message}")
            self.history.event("error", message, mac)
        return ok, message

    def wait_rebuild(
        self,
        mac: str,
        old_attempt: str,
        progress: Optional[Callable[[str], None]] = None,
    ) -> Tuple[bool, str, Optional[PcStatus]]:
        status = self.statuses.get(mac)
        if status is None or not status.ip:
            return False, "неизвестен IP", None
        return wait_for_rebuild(status.ip, old_attempt, progress=progress)

    def summary(self) -> Tuple[int, int, int, int]:
        rows = self.rows()
        total = len(rows)
        online = sum(1 for _, _, status in rows if status.online)
        stale = sum(1 for _, _, status in rows if status.online and status.stale)
        errors = sum(1 for _, _, status in rows if status.online and status.has_error)
        return total, online, stale, errors
