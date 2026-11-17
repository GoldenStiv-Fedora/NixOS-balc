"""Создание зашифрованного файла токена GitHub.

Запуск (токен и пароль вводятся скрыто, в историю команд не попадают):

    python3 apps/balc/token_tool.py apps/balc/token.enc

Готовый `token.enc` коммитится в GitHub. Приложению мастер-пароль нужен
только при сохранении имени или подсетей.
"""

import getpass
import sys
from pathlib import Path

import vault

MIN_PASSWORD_LENGTH = 16


def main() -> int:
    if len(sys.argv) != 2:
        print("Использование: token_tool.py ПУТЬ/token.enc")
        return 2
    path = Path(sys.argv[1])

    token = getpass.getpass("Токен GitHub (ввод скрыт): ").strip()
    if not token:
        print("Токен пуст, ничего не сохранено.")
        return 1

    password = getpass.getpass("Мастер-пароль: ")
    if len(password) < MIN_PASSWORD_LENGTH:
        print(
            f"Мастер-пароль слишком короткий: нужно не менее "
            f"{MIN_PASSWORD_LENGTH} символов."
        )
        print("Лучше использовать 5–6 случайных слов или длинную фразу.")
        return 1
    if password != getpass.getpass("Повторите мастер-пароль: "):
        print("Пароли не совпадают, ничего не сохранено.")
        return 1

    try:
        vault.encrypt_token(token, password, path)
        # Сразу проверяем, что файл читается тем же паролем.
        vault.decrypt_token(password, path)
    except (vault.VaultError, OSError) as exc:
        print(f"Ошибка: {exc}")
        return 1

    print(f"Готово: {path}")
    print("Файл зашифрован и проверен. Его можно коммитить в GitHub.")
    print("Не потеряйте мастер-пароль: без него токен не восстановить.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
