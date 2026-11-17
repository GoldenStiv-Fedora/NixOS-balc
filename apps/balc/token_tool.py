"""Создание зашифрованного файла токена GitHub.

Запуск (токен и пароль вводятся скрыто, в историю команд не попадают):

    python3 apps/balc/token_tool.py apps/balc/token.enc

Готовый `token.enc` коммитится в GitHub. Приложению мастер-пароль нужен
только при сохранении имени или подсетей.
"""

import getpass
import sys
from pathlib import Path
from typing import List, Tuple

import vault

MIN_PASSWORD_LENGTH = 16


def clean_token(raw: str) -> Tuple[str, List[str], int]:
    """Убрать невидимые символы; заметить видимую кириллицу.

    Возвращает (токен, список видимых недопустимых символов, число
    удалённых невидимых).
    """
    token = raw.strip()
    cleaned: List[str] = []
    visible_bad: List[str] = []
    invisible = 0
    for index, ch in enumerate(token):
        if ch.isascii():
            cleaned.append(ch)
        elif ch.isprintable():
            visible_bad.append(f"'{ch}' на позиции {index + 1}")
        else:
            invisible += 1
    return "".join(cleaned), visible_bad, invisible


def main() -> int:
    if len(sys.argv) != 2:
        print("Использование: token_tool.py ПУТЬ/token.enc")
        return 2
    path = Path(sys.argv[1])

    raw = getpass.getpass("Токен GitHub (ввод скрыт): ")
    token, visible_bad, invisible = clean_token(raw)
    if visible_bad:
        print("В токене есть недопустимые символы:", ", ".join(visible_bad))
        print(
            "Токен GitHub состоит только из латинских букв и цифр: "
            "ghp_... (classic) или github_pat_... (fine-grained). "
            "Проверьте раскладку и вставьте заново."
        )
        return 1
    if invisible:
        print(f"Удалено невидимых символов: {invisible} (попали при копировании).")
    if not token:
        print("Токен пуст, ничего не сохранено.")
        return 1
    if not token.startswith(("ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_")):
        print(
            "Внимание: это не похоже на токен GitHub (ожидается ghp_... или "
            "github_pat_...). Сохраняю как есть, но запись в GitHub может не работать."
        )

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
