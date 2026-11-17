"""Шифрование токена GitHub мастер-паролем.

Файл `token.enc` лежит рядом с приложением и хранится в Git в зашифрованном
виде. Ключ выводится scrypt, шифрование — HMAC-SHA256 в режиме счётчика,
целостность — HMAC-SHA256 (encrypt-then-MAC). Используется только стандартная
библиотека Python, поэтому файл можно создать на любом ПК без сборки.

Защита держится на мастер-пароле: репозиторий публичный, значит `token.enc`
может скачать кто угодно. Пароль должен быть длинным и случайным.
"""

import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
from typing import Any

MAGIC = "balc-token-vault"
VERSION = 1
KDF_NAME = "scrypt"

# Параметры KDF. Менять только вместе с VERSION: старые файлы должны
# продолжать расшифровываться.
KDF_N = 2 ** 16
KDF_R = 8
KDF_P = 1

SALT_SIZE = 16
NONCE_SIZE = 16
KEY_SIZE = 32
TAG_SIZE = 32


class VaultError(Exception):
    """Ошибка чтения, расшифровки или проверки файла токена."""


def _b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def _unb64(value: Any, expected: int | None = None) -> bytes:
    if not isinstance(value, str):
        raise VaultError("повреждённый файл токена")
    try:
        data = base64.b64decode(value, validate=True)
    except (ValueError, TypeError) as exc:
        raise VaultError("повреждённый файл токена") from exc
    if expected is not None and len(data) != expected:
        raise VaultError("повреждённый файл токена")
    return data


def _header(version: int, n: int, r: int, p: int, salt: bytes, nonce: bytes) -> bytes:
    """Каноническое описание параметров, защищённое MAC."""
    return json.dumps(
        {
            "magic": MAGIC,
            "version": version,
            "kdf": KDF_NAME,
            "n": n,
            "r": r,
            "p": p,
            "salt": _b64(salt),
            "nonce": _b64(nonce),
        },
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def _derive(password: str, salt: bytes) -> bytes:
    maxmem = 128 * KDF_R * (KDF_N + KDF_P + 2) * 2
    try:
        return hashlib.scrypt(
            password.encode("utf-8"),
            salt=salt,
            n=KDF_N,
            r=KDF_R,
            p=KDF_P,
            maxmem=maxmem,
            dklen=2 * KEY_SIZE,
        )
    except (ValueError, MemoryError, UnicodeEncodeError) as exc:
        raise VaultError("не удалось вывести ключ из мастер-пароля") from exc


def _xor_keystream(key: bytes, nonce: bytes, data: bytes) -> bytes:
    result = bytearray(len(data))
    for offset in range(0, len(data), 32):
        counter = (offset // 32).to_bytes(8, "big")
        block = hmac.new(key, nonce + counter, hashlib.sha256).digest()
        chunk = data[offset:offset + 32]
        for index, value in enumerate(chunk):
            result[offset + index] = value ^ block[index]
    return bytes(result)


def _tag(mac_key: bytes, header: bytes, ciphertext: bytes) -> bytes:
    return hmac.new(mac_key, header + ciphertext, hashlib.sha256).digest()


def encrypt_token(token: str, password: str, path: Path) -> None:
    token = token.strip()
    if not token:
        raise VaultError("токен пуст")
    if not password:
        raise VaultError("мастер-пароль пуст")

    salt = os.urandom(SALT_SIZE)
    nonce = os.urandom(NONCE_SIZE)
    key = _derive(password, salt)
    enc_key, mac_key = key[:KEY_SIZE], key[KEY_SIZE:]
    ciphertext = _xor_keystream(enc_key, nonce, token.encode("utf-8"))
    header = _header(VERSION, KDF_N, KDF_R, KDF_P, salt, nonce)

    payload = {
        "magic": MAGIC,
        "version": VERSION,
        "kdf": KDF_NAME,
        "n": KDF_N,
        "r": KDF_R,
        "p": KDF_P,
        "salt": _b64(salt),
        "nonce": _b64(nonce),
        "ciphertext": _b64(ciphertext),
        "tag": _b64(_tag(mac_key, header, ciphertext)),
    }

    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    os.chmod(tmp, 0o644)
    tmp.replace(path)


def decrypt_token(password: str, path: Path) -> str:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise VaultError("не удалось прочитать файл токена") from exc

    if not isinstance(payload, dict) or payload.get("magic") != MAGIC:
        raise VaultError("это не файл токена balc")
    if payload.get("version") != VERSION or payload.get("kdf") != KDF_NAME:
        raise VaultError("неподдерживаемая версия файла токена")

    # Принимаем только те параметры, с которыми файл создан. Это не даёт
    # подменённому файлу заставить приложение считать scrypt с огромной памятью.
    try:
        params = (int(payload.get("n")), int(payload.get("r")), int(payload.get("p")))
    except (TypeError, ValueError) as exc:
        raise VaultError("повреждённые параметры шифрования") from exc
    if params != (KDF_N, KDF_R, KDF_P):
        raise VaultError("неподдерживаемые параметры шифрования")

    salt = _unb64(payload.get("salt"), SALT_SIZE)
    nonce = _unb64(payload.get("nonce"), NONCE_SIZE)
    ciphertext = _unb64(payload.get("ciphertext"))
    tag = _unb64(payload.get("tag"), TAG_SIZE)
    if not ciphertext:
        raise VaultError("файл токена пуст")

    key = _derive(password, salt)
    enc_key, mac_key = key[:KEY_SIZE], key[KEY_SIZE:]
    header = _header(VERSION, KDF_N, KDF_R, KDF_P, salt, nonce)
    if not hmac.compare_digest(_tag(mac_key, header, ciphertext), tag):
        raise VaultError("неверный мастер-пароль или повреждённый файл")

    try:
        token = _xor_keystream(enc_key, nonce, ciphertext).decode("utf-8").strip()
    except UnicodeDecodeError as exc:
        raise VaultError("повреждённый файл токена") from exc
    if not token:
        raise VaultError("токен пуст")
    return token


def default_vault_path() -> Path:
    """Путь файла в проекте/пакете — рядом с приложением."""
    return Path(__file__).with_name("token.enc")


def vault_path() -> Path:
    """Путь для чтения: переменная, системная копия, затем папка приложения."""
    env = os.environ.get("BALC_TOKEN_VAULT", "").strip()
    if env:
        return Path(env)
    system = Path("/etc/nixos/apps/balc/token.enc")
    if system.is_file():
        return system
    return default_vault_path()


def vault_exists() -> bool:
    try:
        return vault_path().is_file()
    except OSError:
        return False
