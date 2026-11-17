"""Запуск и ожидание пересборки на удалённом ПК."""

import shlex
import time
from typing import Callable, Optional, Tuple

from config import REBUILD_TRIGGER, SSH_PASSWORD
from models import PcStatus
from probe import probe_host
from ssh_client import SshClient, SshError


def request_rebuild(ip: str) -> Tuple[bool, str]:
    command = f"sudo -n {REBUILD_TRIGGER}"
    try:
        with SshClient(ip) as ssh:
            code, out, err = ssh.run(command, timeout=20)
            if code != 0 and "password is required" in (err + out).lower():
                password = shlex.quote(SSH_PASSWORD)
                fallback = f"printf '%s\\n' {password} | sudo -S {REBUILD_TRIGGER}"
                code, out, err = ssh.run(fallback, timeout=20)
    except SshError as exc:
        return False, str(exc)

    if code != 0:
        return False, (err or out).strip() or f"код {code}"
    return True, "пересборка запущена"


def wait_for_rebuild(
    ip: str,
    old_attempt: str,
    timeout: int = 1800,
    progress: Optional[Callable[[str], None]] = None,
) -> Tuple[bool, str, Optional[PcStatus]]:
    deadline = time.time() + timeout
    last: Optional[PcStatus] = None
    last_progress = 0.0
    terminal = {
        "success",
        "build-failed",
        "switch-failed",
        "fetch-failed",
        "git-failed",
        "busy",
    }

    while time.time() < deadline:
        last = probe_host(ip)
        if last.online:
            attempt = last.last_attempt_at
            result = last.last_result
            if progress and time.time() - last_progress > 30:
                progress(f"состояние: {result or 'ожидание'}")
                last_progress = time.time()
            if attempt and attempt != old_attempt and result in terminal:
                if result == "success":
                    return True, "пересборка завершена успешно", last
                if result == "busy":
                    return False, "обновление уже выполняется, повторите позже", last
                return False, last.last_error or f"результат: {result}", last
        elif last.error and progress and time.time() - last_progress > 60:
            progress(f"нет связи: {last.error}")
            last_progress = time.time()
        time.sleep(10)
    return False, "таймаут ожидания пересборки", last
