# 🚀 NixOS-balc — управление парком ПК по принципу GitOps

Централизованная конфигурация парка рабочих станций на **NixOS**.
Любое изменение в репозитории автоматически доезжает до всех ПК:
**GitHub → `/etc/nixos/.sync` → `/etc/nixos` → сборка → switch**.

## ✨ Ключевые возможности

- **Автообновление**: таймер каждые 20 минут проверяет GitHub, раскладывает файлы и пересобирает систему; при неудачной сборке — откат к последнему рабочему коммиту.
- **Приложение `balc`**: мониторинг парка, человекочитаемые имена ПК (по MAC), удалённая пересборка и SSH — на любом ПК под пользователем `balc`.
- **Рутокен**: пропатченный драйвер для HID-токенов, проброс в RDP.
- **VPN и RDP**: графический помощник `connect-rdp` (L2TP/IPSec + FreeRDP).
- **XFCE**: случайные обои из `imag/` при каждом входе, ярлыки RDP и принтеров.
- **Чистка**: еженедельный GC и оптимизация `/nix/store`.

## 📂 Структура репозитория

```text
├── .github/workflows/update.yml   # ежедневное обновление flake.lock (02:00)
├── configs/                       # конфигурация NixOS
│   ├── configuration.nix          # система, SSH, алиасы soberi/obnovi
│   ├── flake.nix + flake.lock     # nixos-26.05 + nixpkgs-unstable
│   ├── git-sync.nix               # служба синхронизации и пересборки
│   ├── users.nix                  # balc (админ), user; обои и ярлыки
│   ├── rutoken.nix                # драйверы Рутокена
│   ├── vpn.nix                    # L2TP-профиль и connect-rdp
│   ├── printers.nix               # CUPS и автообнаружение принтеров
│   └── заглушка                   # служебный скрипт очистки кэша
├── apps/balc/                     # приложение balc (вместе с balc.nix)
│   ├── balc.nix                   # модуль: ставится только в профиль balc
│   ├── *.py                       # GUI (Tkinter), SSH, сканер, инвентарь
│   ├── vault.py / token_tool.py   # шифрование токена GitHub мастер-паролем
│   ├── token.enc                  # зашифрованный токен (создаёт владелец)
│   └── shell.nix                  # тест приложения без установки: nix-shell
├── inventory.json                 # общий инвентарь: MAC → имя, IP, подсети
├── imag/                          # обои рабочего стола
└── README.md
```

`hardware-configuration.nix` в репозитории **не хранится**: он свой у каждого ПК
(синк его исключает, GitHub Actions создаёт заглушку для `nix flake update`).

## ⚙️ Как это работает

**Синк** (`git-sync.nix`): клон репозитория живёт в `/etc/nixos/.sync`
(sparse-checkout: `configs imag apps`). Служба:

1. качает свежий `main`, раскладывает `configs/` → `/etc/nixos/`,
   `apps/balc/` → `/etc/nixos/apps/balc/`, `inventory.json` → `/etc/nixos/apps/`;
2. делает предварительную сборку (`nixos-rebuild build`);
3. при успехе — `switch`, при провале — откат к последнему рабочему коммиту;
4. пишет состояние в `/var/lib/nixos-git-sync/status.json`, коммит — в `/etc/nixos/revision`.

**Приложение `balc`** (только у пользователя `balc`): опрашивает ПК по SSH,
показывает статус, ошибки и версии, переименовывает ПК по MAC, запускает
пересборку. Имена и подсети хранятся в `inventory.json`: приложение читает его
с GitHub, **сливает** изменения с других ПК (имя — по свежему `updated_at`,
IP — по `last_seen`) и пишет обратно через GitHub API. Токен хранится в
репозитории зашифрованным мастер-паролем (`token.enc`, scrypt+HMAC) и
разблокируется в приложении («Парк → Мастер-пароль…»).

**Обновление пакетов**: GitHub Actions каждую ночь обновляет `flake.lock` —
утром парк забирает свежие версии сам.

## 🚀 Ввод нового ПК

Установить чистую NixOS и выполнить:

```bash
sudo mkdir -p /etc/nixos/.sync && cd /etc/nixos/.sync && \
sudo git clone --filter=blob:none --sparse https://github.com/GoldenStiv-Fedora/NixOS-balc.git . && \
sudo git sparse-checkout set configs imag apps && \
sudo rsync -a ./configs/ /etc/nixos/ --exclude=hardware-configuration.nix && \
sudo nixos-rebuild switch --flake /etc/nixos#nixos --option experimental-features "nix-command flakes"
```

Дальше таймер всё сделает сам: докачает приложение, инвентарь, обои и
пересоберёт систему. SSH уже включён конфигурацией (вход по паролю `balc`,
root запрещён).

## 🛠 Повседневная работа

| Команда | Что делает |
|---|---|
| `obnovi` | скачать GitHub, разложить и пересобрать систему (с деревом сборки `nom`) |
| `soberi` | пересобрать текущую `/etc/nixos` без обращения к GitHub |
| `sudo nix-collect-garbage -d` | ручная чистка магазина |

---
*Разработано для управления парком ПК на базе NixOS.*
