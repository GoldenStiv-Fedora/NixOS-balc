"""Настройки приложения balc."""

import os
from pathlib import Path

APP_NAME = "balc"
APP_TITLE = "balc — управление парком"
APP_VERSION = "0.1.0"

HOME = Path.home()
CONFIG_DIR = HOME / ".config" / "balc"
LOCAL_INVENTORY = CONFIG_DIR / "inventory.json"
LOCAL_HISTORY = CONFIG_DIR / "history.json"
GITHUB_TOKEN_FILE = CONFIG_DIR / "github_token"

REPO_OWNER = "GoldenStiv-Fedora"
REPO_NAME = "NixOS-balc"
REPO_BRANCH = "main"
INVENTORY_RAW_URL = (
    f"https://raw.githubusercontent.com/{REPO_OWNER}/{REPO_NAME}/{REPO_BRANCH}/inventory.json"
)
INVENTORY_API_URL = (
    f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}/contents/inventory.json"
)
SYSTEM_INVENTORY = Path("/etc/nixos/apps/inventory.json")

SSH_USER = "balc"
SSH_PASSWORD = os.environ.get("BALC_SSH_PASSWORD", "13579")
SSH_PORT = 22
SSH_CONNECT_TIMEOUT = 4
SSH_COMMAND_TIMEOUT = 25

REBUILD_TRIGGER = "/run/current-system/sw/bin/nixos-fleet-rebuild"
REBUILD_SERVICE = "nixos-fleet-rebuild.service"
STATUS_FILE = "/var/lib/nixos-git-sync/status.json"

REFRESH_SECONDS = 60
DISCOVERY_CACHE_SECONDS = 300
PROBE_WORKERS = 16
SCAN_WORKERS = 64
SCAN_TIMEOUT = 2.0
MAX_SCAN_HOSTS = 4096
