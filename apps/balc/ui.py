"""Графический интерфейс приложения balc."""

import ipaddress
import queue
import shutil
import subprocess
import threading
import tkinter as tk
from datetime import datetime
from pathlib import Path
from tkinter import messagebox, simpledialog, ttk
from typing import Dict, Optional, Tuple

import config
from fleet import FleetManager
from inventory import Inventory
from models import PcStatus
from notify import Notifier
from store import History


class BalcApp:
    def __init__(self):
        self.root = tk.Tk()
        self.root.title(config.APP_TITLE)
        self.root.geometry("1280x760")
        self.root.minsize(960, 560)
        self.root.protocol("WM_DELETE_WINDOW", self.on_close)

        icon_path = Path(__file__).with_name("icon.png")
        if icon_path.exists():
            try:
                self._icon = tk.PhotoImage(file=str(icon_path))
                self.root.iconphoto(True, self._icon)
            except tk.TclError:
                self._icon = None

        self.inventory = Inventory()
        self.history = History()
        self.notifier = Notifier()
        self.fleet = FleetManager(self.inventory, self.history, self.notifier)

        self._queue: "queue.Queue[Tuple[str, object]]" = queue.Queue()
        self._refresh_running = False
        self._rebuild_running = False
        self._rename_running = False
        self._settings_running = False
        self._closing = False
        self._sort_col = "name"
        self._sort_reverse = False

        self._build_ui()
        self.log_line("Приложение запущено.")
        self.status_var.set("Подготовка...")
        self.source_var.set(f"База имён: {self.inventory.source}")
        self.root.after(300, self._initial_refresh)
        self.root.after(200, self._poll_queue)
        self.root.after(config.REFRESH_SECONDS * 1000, self._auto_refresh)

    def _build_ui(self) -> None:
        style = ttk.Style()
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure("Treeview", rowheight=26, font=("DejaVu Sans", 10))
        style.configure("Treeview.Heading", font=("DejaVu Sans", 10, "bold"))

        menubar = tk.Menu(self.root)
        fleet_menu = tk.Menu(menubar, tearoff=0)
        fleet_menu.add_command(label="Обновить", command=self.refresh_async)
        fleet_menu.add_command(label="Найти ПК", command=self.discover_async)
        fleet_menu.add_command(label="Подсети…", command=self.edit_subnets)
        fleet_menu.add_separator()
        fleet_menu.add_command(label="Выход", command=self.on_close)
        menubar.add_cascade(label="Парк", menu=fleet_menu)

        pc_menu = tk.Menu(menubar, tearoff=0)
        pc_menu.add_command(label="Пересобрать", command=self.rebuild_selected)
        pc_menu.add_command(label="Переименовать", command=self.rename_selected)
        pc_menu.add_command(label="Открыть SSH", command=self.open_ssh)
        pc_menu.add_command(label="Копировать IP", command=self.copy_ip)
        menubar.add_cascade(label="ПК", menu=pc_menu)

        help_menu = tk.Menu(menubar, tearoff=0)
        help_menu.add_command(label="О программе", command=self.about)
        menubar.add_cascade(label="Помощь", menu=help_menu)
        self.root.config(menu=menubar)

        top = ttk.Frame(self.root, padding=(10, 8))
        top.pack(fill="x")
        self.btn_refresh = ttk.Button(top, text="Обновить", command=self.refresh_async)
        self.btn_refresh.pack(side="left")
        self.btn_discover = ttk.Button(top, text="Найти ПК", command=self.discover_async)
        self.btn_discover.pack(side="left", padx=(6, 0))
        self.btn_rebuild = ttk.Button(top, text="Пересобрать", command=self.rebuild_selected)
        self.btn_rebuild.pack(side="left", padx=(6, 0))
        self.btn_rename = ttk.Button(top, text="Переименовать", command=self.rename_selected)
        self.btn_rename.pack(side="left", padx=(6, 0))
        self.btn_subnets = ttk.Button(top, text="Подсети…", command=self.edit_subnets)
        self.btn_subnets.pack(side="left", padx=(6, 0))

        self.auto_var = tk.BooleanVar(value=True)
        ttk.Checkbutton(top, text="Автообновление", variable=self.auto_var).pack(
            side="left", padx=(14, 0)
        )

        search_frame = ttk.Frame(top)
        search_frame.pack(side="right")
        ttk.Label(search_frame, text="Поиск:").pack(side="left", padx=(0, 4))
        self.search_var = tk.StringVar()
        self.search_var.trace_add("write", lambda *_: self.render())
        ttk.Entry(search_frame, textvariable=self.search_var, width=26).pack(side="left")

        paned = ttk.PanedWindow(self.root, orient="horizontal")
        paned.pack(fill="both", expand=True, padx=10, pady=(0, 6))

        left = ttk.Frame(paned)
        right = ttk.Frame(paned)
        paned.add(left, weight=4)
        paned.add(right, weight=2)

        columns = ("name", "ip", "state", "build", "commit", "checked", "error")
        headings = {
            "name": "Имя",
            "ip": "IP",
            "state": "Сеть",
            "build": "Сборка",
            "commit": "Коммит",
            "checked": "Проверен",
            "error": "Ошибка",
        }
        widths = {
            "name": 180,
            "ip": 120,
            "state": 100,
            "build": 110,
            "commit": 130,
            "checked": 130,
            "error": 300,
        }
        self.tree = ttk.Treeview(left, columns=columns, show="headings", selectmode="browse")
        for column in columns:
            self.tree.heading(
                column,
                text=headings[column],
                command=lambda col=column: self.sort_by(col),
            )
            self.tree.column(
                column,
                width=widths[column],
                anchor="w",
                stretch=column in ("name", "error"),
            )
        self.tree.tag_configure("online", foreground="#0b6b2f")
        self.tree.tag_configure("offline", foreground="#777777")
        self.tree.tag_configure("error", foreground="#b00020")
        self.tree.tag_configure("stale", foreground="#a15c00")
        self.tree.tag_configure("building", foreground="#0050a0")
        self.tree.bind("<<TreeviewSelect>>", lambda _event: self.on_select())
        self.tree.bind("<Button-3>", self.show_context_menu)
        self.tree.bind("<Double-1>", lambda _event: self.open_ssh())

        tree_scroll = ttk.Scrollbar(left, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=tree_scroll.set)
        self.tree.pack(side="left", fill="both", expand=True)
        tree_scroll.pack(side="right", fill="y")

        self.context_menu = tk.Menu(self.root, tearoff=0)
        self.context_menu.add_command(label="Пересобрать", command=self.rebuild_selected)
        self.context_menu.add_command(label="Переименовать", command=self.rename_selected)
        self.context_menu.add_separator()
        self.context_menu.add_command(label="Открыть SSH", command=self.open_ssh)
        self.context_menu.add_command(label="Копировать IP", command=self.copy_ip)
        self.context_menu.add_separator()
        self.context_menu.add_command(label="Обновить", command=self.refresh_async)

        details_frame = ttk.LabelFrame(right, text="Состояние ПК", padding=6)
        details_frame.pack(fill="both", expand=True)
        self.details = tk.Text(
            details_frame,
            wrap="word",
            width=50,
            height=24,
            state="disabled",
            font=("DejaVu Sans Mono", 9),
        )
        details_scroll = ttk.Scrollbar(
            details_frame, orient="vertical", command=self.details.yview
        )
        self.details.configure(yscrollcommand=details_scroll.set)
        self.details.pack(side="left", fill="both", expand=True)
        details_scroll.pack(side="right", fill="y")

        log_frame = ttk.LabelFrame(self.root, text="Журнал", padding=4)
        log_frame.pack(fill="x", padx=10, pady=(0, 8))
        self.log = tk.Text(
            log_frame,
            height=7,
            wrap="word",
            state="disabled",
            font=("DejaVu Sans Mono", 9),
        )
        log_scroll = ttk.Scrollbar(log_frame, orient="vertical", command=self.log.yview)
        self.log.configure(yscrollcommand=log_scroll.set)
        self.log.pack(side="left", fill="both", expand=True)
        log_scroll.pack(side="right", fill="y")

        bottom = ttk.Frame(self.root, padding=(10, 4))
        bottom.pack(fill="x", side="bottom")
        self.status_var = tk.StringVar(value="Готово")
        self.source_var = tk.StringVar(value="")
        ttk.Label(bottom, textvariable=self.status_var).pack(side="left")
        ttk.Label(bottom, textvariable=self.source_var).pack(side="right")

    def _initial_refresh(self) -> None:
        self.refresh_async(discover=not bool(self.inventory.all()))

    def _poll_queue(self) -> None:
        if self._closing:
            return
        try:
            while True:
                kind, payload = self._queue.get_nowait()
                if kind == "log":
                    self.log_line(str(payload))
                elif kind == "status":
                    self.status_var.set(str(payload))
                elif kind == "refresh_done":
                    self.on_refresh_done()
                elif kind == "refresh_finished":
                    self._refresh_running = False
                    self._update_busy()
                    self.status_var.set(self._summary())
                elif kind == "error":
                    self.log_line(f"ОШИБКА: {payload}")
                    self.notifier.error(str(payload))
                    self.status_var.set(str(payload))
                elif kind == "rebuild_done":
                    mac, ok, message = payload  # type: ignore[misc]
                    self.on_rebuild_done(str(mac), bool(ok), str(message))
                elif kind == "rename_done":
                    ok, message = payload  # type: ignore[misc]
                    self._rename_running = False
                    self._update_busy()
                    self.log_line(f"Имя: {message}")
                    if not ok:
                        messagebox.showwarning("Имя сохранено локально", str(message))
                    self.render()
                    self.status_var.set(self._summary())
                elif kind == "settings_done":
                    ok, message = payload  # type: ignore[misc]
                    self._settings_running = False
                    self._update_busy()
                    self.log_line(f"Подсети: {message}")
                    if not ok:
                        messagebox.showwarning("Подсети сохранены локально", str(message))
                    self.source_var.set(f"База имён: {self.inventory.source}")
                    self.status_var.set(self._summary())
        except queue.Empty:
            pass
        self.root.after(200, self._poll_queue)

    def _auto_refresh(self) -> None:
        if self._closing:
            return
        if (
            self.auto_var.get()
            and not self._refresh_running
            and not self._rebuild_running
            and not self._rename_running
            and not self._settings_running
        ):
            self.refresh_async()
        self.root.after(config.REFRESH_SECONDS * 1000, self._auto_refresh)

    def _update_busy(self) -> None:
        busy = (
            self._refresh_running
            or self._rebuild_running
            or self._rename_running
            or self._settings_running
        )
        state = "disabled" if busy else "normal"
        for button in (
            self.btn_refresh,
            self.btn_discover,
            self.btn_rebuild,
            self.btn_rename,
            self.btn_subnets,
        ):
            button.configure(state=state)
        try:
            self.root.configure(cursor="watch" if busy else "")
        except tk.TclError:
            pass

    def refresh_async(self, discover: bool = False) -> None:
        if self._refresh_running:
            return
        if self._rebuild_running or self._rename_running or self._settings_running:
            self.log_line("Дождитесь завершения текущей операции.")
            return
        self._refresh_running = True
        self._update_busy()
        self.status_var.set("Поиск ПК..." if discover else "Опрос парка...")
        threading.Thread(
            target=self._refresh_worker,
            args=(discover,),
            daemon=True,
        ).start()

    def _refresh_worker(self, discover: bool) -> None:
        try:
            self.fleet.refresh(
                discover=discover,
                progress=lambda message: self._queue.put(("log", message)),
            )
            self._queue.put(("refresh_done", None))
        except Exception as exc:
            self._queue.put(("error", f"Ошибка обновления: {exc}"))
        finally:
            self._queue.put(("refresh_finished", None))

    def discover_async(self) -> None:
        self.refresh_async(discover=True)

    def on_refresh_done(self) -> None:
        self.render()
        self.source_var.set(f"База имён: {self.inventory.source}")
        self.status_var.set(self._summary())
        self._update_busy()

    def _summary(self) -> str:
        total, online, stale, errors = self.fleet.summary()
        return (
            f"Всего: {total} · В сети: {online} · "
            f"Не пересобраны: {stale} · Ошибки: {errors}"
        )

    def _build_label(self, status: PcStatus) -> str:
        if not status.online:
            return "—"
        if status.rebuild_active in {"active", "activating", "reloading"}:
            return "идёт"
        if status.last_result in {"building", "built", "switching"} and status.sync_active in {
            "active",
            "activating",
            "reloading",
        }:
            return "идёт"
        if status.has_error:
            return "ошибка"
        if status.stale:
            return "не пересобран"
        if status.success_commit:
            return "готово"
        return "нет данных"

    def _commit_label(self, status: PcStatus) -> str:
        success = status.short_commit(status.success_commit)
        remote = status.short_commit(status.remote_commit)
        if status.success_commit and status.remote_commit and status.success_commit != status.remote_commit:
            return f"{success} → {remote}"
        if status.success_commit:
            return success
        if status.remote_commit:
            return f"→ {remote}"
        return "—"

    def _sort_key(self, item: Tuple[str, Dict, PcStatus]):
        mac, record, status = item
        column = self._sort_col
        if column == "name":
            return str(record.get("name") or "яяя").lower()
        if column == "ip":
            return str(status.ip or record.get("ip") or "")
        if column == "state":
            return status.state_label
        if column == "build":
            return self._build_label(status)
        if column == "commit":
            return status.success_commit or status.remote_commit or ""
        if column == "checked":
            return status.checked_at or 0.0
        if column == "error":
            return status.error or status.last_error or ""
        return mac

    def sort_by(self, column: str) -> None:
        if self._sort_col == column:
            self._sort_reverse = not self._sort_reverse
        else:
            self._sort_col = column
            self._sort_reverse = False
        self.render()

    def render(self) -> None:
        selected = self.selected_mac()
        query = self.search_var.get().strip().lower()
        rows = self.fleet.rows()
        rows.sort(key=self._sort_key, reverse=self._sort_reverse)

        children = self.tree.get_children()
        if children:
            self.tree.delete(*children)

        for mac, record, status in rows:
            name = str(record.get("name") or "Без имени")
            ip = status.ip or str(record.get("ip") or "—")
            state = status.state_label
            build = self._build_label(status)
            commit = self._commit_label(status)
            checked = self._format_time(status.checked_at)
            error = " ".join((status.error or status.last_error or "").split())
            if len(error) > 90:
                error = error[:87] + "..."
            haystack = f"{name} {ip} {mac} {state} {build} {error}".lower()
            if query and query not in haystack:
                continue

            if not status.online:
                tag = "offline"
            elif status.rebuild_active in {"active", "activating", "reloading"}:
                tag = "building"
            elif status.has_error:
                tag = "error"
            elif status.stale:
                tag = "stale"
            else:
                tag = "online"

            self.tree.insert(
                "",
                "end",
                iid=mac or f"ip:{ip}",
                values=(name, ip, state, build, commit, checked, error),
                tags=(tag,),
            )

        if selected and self.tree.exists(selected):
            self.tree.selection_set(selected)
            self.on_select()
        elif self.tree.get_children():
            first = self.tree.get_children()[0]
            self.tree.selection_set(first)
            self.on_select()
        else:
            self._show_details(None)

    def selected_mac(self) -> Optional[str]:
        selection = self.tree.selection()
        return selection[0] if selection else None

    def on_select(self) -> None:
        mac = self.selected_mac()
        if not mac:
            self._show_details(None)
            return
        for row_mac, record, status in self.fleet.rows():
            if row_mac == mac:
                self._show_details((record, status))
                return
        self._show_details(None)

    def _show_details(self, data: Optional[Tuple[Dict, PcStatus]]) -> None:
        if data is None:
            text = "Выберите ПК в списке."
        else:
            record, status = data
            lines = [
                f"Имя: {record.get('name') or 'Без имени'}",
                f"MAC: {status.mac or '—'}",
                f"IP: {status.ip or record.get('ip') or '—'}",
                f"Состояние: {status.state_label}",
                f"Hostname: {status.hostname or '—'}",
                f"Machine-ID: {status.machine_id or '—'}",
                f"NixOS: {status.nixos_version or '—'}",
                f"Поколение: {status.generation or '—'}",
                f"Ревизия: {status.revision or '—'}",
                "",
                f"Последняя проверка: {self._format_time(status.checked_at)}",
                f"Последний результат: {status.last_result or '—'}",
                f"Последняя успешная сборка: {status.last_success_at or '—'}",
                f"Успешный коммит: {status.success_commit or '—'}",
                f"Коммит в GitHub: {status.remote_commit or '—'}",
                f"Сборка активна: {status.rebuild_active or '—'}",
                f"Синхронизация активна: {status.sync_active or '—'}",
                f"Uptime: {status.uptime or '—'}",
                f"Диск: {status.disk or '—'}",
                f"/nix/store: {status.store_size or '—'}",
            ]
            if status.error:
                lines.extend(["", f"Ошибка связи: {status.error}"])
            if status.last_error:
                lines.extend(["", f"Ошибка сборки: {status.last_error}"])
            text = "\n".join(lines)

        self.details.configure(state="normal")
        self.details.delete("1.0", "end")
        self.details.insert("1.0", text)
        self.details.configure(state="disabled")

    @staticmethod
    def _format_time(timestamp: float) -> str:
        if not timestamp:
            return "—"
        try:
            return datetime.fromtimestamp(timestamp).strftime("%d.%m.%Y %H:%M")
        except (OSError, ValueError):
            return "—"

    def show_context_menu(self, event) -> None:
        row = self.tree.identify_row(event.y)
        if not row:
            return
        self.tree.selection_set(row)
        self.on_select()
        self.context_menu.tk_popup(event.x_root, event.y_root)

    def rebuild_selected(self) -> None:
        mac = self.selected_mac()
        if not mac:
            messagebox.showinfo("Пересборка", "Сначала выберите ПК.")
            return
        if self._rebuild_running:
            messagebox.showinfo("Пересборка", "Пересборка уже выполняется.")
            return
        status = self.fleet.statuses.get(mac)
        if status is None or not status.online:
            messagebox.showerror("Пересборка", "ПК не в сети.")
            return

        name = self.fleet.display_name(mac)
        if not messagebox.askyesno(
            "Пересборка",
            (
                f"Запустить пересборку на ПК «{name}»?\n\n"
                "Будет скачан GitHub и собрана система. Это может занять несколько минут."
            ),
        ):
            return

        old_attempt = status.last_attempt_at
        self._rebuild_running = True
        self._update_busy()
        self.status_var.set(f"Пересборка: {name}")
        self.log_line(f"{name}: запуск пересборки...")
        threading.Thread(
            target=self._rebuild_worker,
            args=(mac, old_attempt),
            daemon=True,
        ).start()

    def _rebuild_worker(self, mac: str, old_attempt: str) -> None:
        name = self.fleet.display_name(mac)
        ok, message = self.fleet.request_rebuild(mac)
        if not ok:
            self._queue.put(("rebuild_done", (mac, False, message)))
            return
        self._queue.put(("log", f"{name}: {message}"))
        ok, message, _status = self.fleet.wait_rebuild(
            mac,
            old_attempt,
            progress=lambda text: self._queue.put(("log", f"{name}: {text}")),
        )
        self._queue.put(("rebuild_done", (mac, ok, message)))

    def on_rebuild_done(self, mac: str, ok: bool, message: str) -> None:
        self._rebuild_running = False
        self._update_busy()
        name = self.fleet.display_name(mac)
        self.log_line(f"{name}: {'успешно' if ok else 'ошибка'}: {message}")
        if ok:
            messagebox.showinfo("Пересборка", f"{name}: {message}")
        else:
            messagebox.showerror("Пересборка", f"{name}: {message}")
        self.root.after(500, self.refresh_async)

    def rename_selected(self) -> None:
        mac = self.selected_mac()
        if not mac:
            messagebox.showinfo("Имя ПК", "Сначала выберите ПК.")
            return
        if self._rename_running:
            return
        old_name = self.inventory.name_for(mac)
        new_name = simpledialog.askstring(
            "Имя ПК",
            f"Новое имя для {old_name or mac}:",
            initialvalue=old_name,
            parent=self.root,
        )
        if new_name is None:
            return
        new_name = new_name.strip()
        if not new_name:
            return
        self._rename_running = True
        self._update_busy()
        self.status_var.set("Сохранение имени...")
        threading.Thread(
            target=self._rename_worker,
            args=(mac, new_name),
            daemon=True,
        ).start()

    def _rename_worker(self, mac: str, name: str) -> None:
        ok, message = self.inventory.set_name(mac, name)
        self._queue.put(("rename_done", (ok, message)))

    def edit_subnets(self) -> None:
        if self._settings_running:
            return
        current = ", ".join(self.inventory.scan_subnets)
        value = simpledialog.askstring(
            "Подсети для поиска",
            "Укажите подсети через запятую (например, 192.168.1.0/24):",
            initialvalue=current,
            parent=self.root,
        )
        if value is None:
            return
        subnets = [part.strip() for part in value.split(",") if part.strip()]
        for subnet in subnets:
            try:
                ipaddress.ip_network(subnet, strict=False)
            except ValueError:
                messagebox.showerror("Подсети", f"Некорректная подсеть: {subnet}")
                return
        self._settings_running = True
        self._update_busy()
        self.status_var.set("Сохранение подсетей...")
        threading.Thread(
            target=self._settings_worker,
            args=(subnets,),
            daemon=True,
        ).start()

    def _settings_worker(self, subnets) -> None:
        ok, message = self.inventory.set_scan_subnets(subnets)
        self._queue.put(("settings_done", (ok, message)))

    def open_ssh(self) -> None:
        mac = self.selected_mac()
        if not mac:
            return
        status = self.fleet.statuses.get(mac)
        ip = status.ip if status and status.ip else self.inventory.ip_for(mac)
        if not ip:
            messagebox.showerror("SSH", "Неизвестен IP-адрес ПК.")
            return
        command = f"ssh -o StrictHostKeyChecking=accept-new {config.SSH_USER}@{ip}"
        if shutil.which("xfce4-terminal"):
            try:
                subprocess.Popen(["xfce4-terminal", "--command", command])
                return
            except OSError:
                pass
        if shutil.which("xterm"):
            try:
                subprocess.Popen(["xterm", "-e", "sh", "-c", command])
                return
            except OSError:
                pass
        messagebox.showinfo("SSH", f"Выполните в терминале:\n\n{command}")

    def copy_ip(self) -> None:
        mac = self.selected_mac()
        if not mac:
            return
        status = self.fleet.statuses.get(mac)
        ip = status.ip if status and status.ip else self.inventory.ip_for(mac)
        if not ip:
            return
        self.root.clipboard_clear()
        self.root.clipboard_append(ip)
        self.log_line(f"IP скопирован: {ip}")

    def log_line(self, message: str) -> None:
        timestamp = datetime.now().strftime("%H:%M:%S")
        self.log.configure(state="normal")
        self.log.insert("end", f"[{timestamp}] {message}\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def about(self) -> None:
        messagebox.showinfo(
            "О программе",
            (
                f"balc {config.APP_VERSION}\n"
                "Управление парком NixOS.\n\n"
                "Идентификация ПК — по MAC-адресу.\n"
                "Данные: инвентарь GitHub + живой статус по SSH."
            ),
        )

    def on_close(self) -> None:
        self._closing = True
        self.root.destroy()

    def run(self) -> None:
        self.root.mainloop()
