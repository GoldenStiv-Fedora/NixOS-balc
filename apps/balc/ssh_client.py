"""SSH-подключение к ПК парка."""

import socket
from typing import Optional, Tuple

import paramiko

from config import SSH_CONNECT_TIMEOUT, SSH_PASSWORD, SSH_PORT, SSH_USER


class SshError(RuntimeError):
    """Ошибка SSH-подключения или выполнения команды."""


class SshClient:
    def __init__(
        self,
        host: str,
        user: str = SSH_USER,
        password: str = SSH_PASSWORD,
        port: int = SSH_PORT,
        timeout: int = SSH_CONNECT_TIMEOUT,
        key_filename: Optional[str] = None,
    ):
        self.host = host
        self.user = user
        self.password = password
        self.port = port
        self.timeout = timeout
        self.key_filename = key_filename
        self._client: Optional[paramiko.SSHClient] = None

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, exc_type, exc, tb):
        self.close()

    def connect(self) -> None:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        try:
            client.connect(
                hostname=self.host,
                port=self.port,
                username=self.user,
                password=self.password,
                key_filename=self.key_filename,
                timeout=self.timeout,
                banner_timeout=self.timeout,
                auth_timeout=self.timeout,
                allow_agent=False,
                look_for_keys=False,
            )
        except paramiko.AuthenticationException as exc:
            raise SshError(f"Ошибка авторизации на {self.host}: {exc}") from exc
        except (paramiko.SSHException, socket.error, OSError) as exc:
            raise SshError(f"Нет связи с {self.host}: {exc}") from exc
        self._client = client

    def run(self, command: str, timeout: int = SSH_COMMAND_TIMEOUT) -> Tuple[int, str, str]:
        if self._client is None:
            self.connect()
        assert self._client is not None
        try:
            _stdin, stdout, stderr = self._client.exec_command(command, timeout=timeout)
            out = stdout.read().decode("utf-8", "replace")
            err = stderr.read().decode("utf-8", "replace")
            code = stdout.channel.recv_exit_status()
            return code, out, err
        except (paramiko.SSHException, socket.error, OSError) as exc:
            raise SshError(f"Ошибка выполнения команды на {self.host}: {exc}") from exc

    def close(self) -> None:
        if self._client is not None:
            self._client.close()
            self._client = None
