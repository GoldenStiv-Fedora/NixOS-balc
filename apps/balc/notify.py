"""Внутренние уведомления приложения."""

import time
from typing import List, Tuple


class Notifier:
    def __init__(self):
        self.messages: List[Tuple[float, str, str]] = []

    def add(self, level: str, message: str) -> None:
        self.messages.append((time.time(), level, message))
        self.messages = self.messages[-200:]

    def info(self, message: str) -> None:
        self.add("info", message)

    def warn(self, message: str) -> None:
        self.add("warn", message)

    def error(self, message: str) -> None:
        self.add("error", message)
