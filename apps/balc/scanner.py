"""Поиск ПК в локальной сети."""

import ipaddress
import socket
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Iterable, List

from config import MAX_SCAN_HOSTS, SCAN_TIMEOUT, SCAN_WORKERS


def local_subnets() -> List[str]:
    subnets: List[str] = []
    try:
        result = subprocess.run(
            ["ip", "-4", "-o", "addr", "show", "scope", "global"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return subnets

    for line in result.stdout.splitlines():
        parts = line.split()
        if "inet" not in parts:
            continue
        index = parts.index("inet")
        if index + 1 >= len(parts):
            continue
        try:
            interface = ipaddress.ip_interface(parts[index + 1])
        except ValueError:
            continue
        network = interface.network
        if network.num_addresses <= 1024:
            subnets.append(str(network))
        else:
            subnets.append(str(ipaddress.ip_network(f"{interface.ip}/24", strict=False)))
    return sorted(set(subnets))


def _port_open(ip: str) -> bool:
    try:
        with socket.create_connection((ip, 22), timeout=SCAN_TIMEOUT):
            return True
    except OSError:
        return False


def scan_subnet(cidr: str) -> List[str]:
    network = ipaddress.ip_network(cidr, strict=False)
    hosts = list(network.hosts())
    if len(hosts) > MAX_SCAN_HOSTS:
        hosts = hosts[:MAX_SCAN_HOSTS]

    found: List[str] = []
    with ThreadPoolExecutor(max_workers=SCAN_WORKERS) as pool:
        futures = {pool.submit(_port_open, str(ip)): str(ip) for ip in hosts}
        for future in as_completed(futures):
            if future.result():
                found.append(futures[future])
    return sorted(found, key=ipaddress.ip_address)


def scan_many(subnets: Iterable[str]) -> List[str]:
    found: List[str] = []
    for cidr in subnets:
        try:
            found.extend(scan_subnet(cidr))
        except ValueError:
            continue
    return sorted(set(found), key=ipaddress.ip_address)
