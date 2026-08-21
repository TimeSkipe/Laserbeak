#!/usr/bin/env python3
"""Місток між демоном і програмою, якій потрібен справжній термінал.

    pty-bridge.py <команда> [аргументи...]

Claude Code — інтерактивна програма: вона читає ввід із термінала, а не
зі звичайного каналу. Тому просто передати їй stdin через pipe не можна.

Місток виділяє псевдотермінал, запускає в ньому команду і зшиває:

    наш stdin  (pipe від демона)  ->  ввід термінала
    вивід термінала               ->  наш stdout (pipe до демона)

Чому не /usr/bin/script: він викликає tcgetattr на власному stdin і падає
з "Operation not supported on socket", коли той є каналом, а не терміналом.

Використовується лише стандартна бібліотека — жодних залежностей, і
python3 у macOS є з коробки.
"""

import os
import pty
import select
import signal
import sys
import termios
import tty

# Розмір вікна впливає на те, як Claude Code малює свій інтерфейс.
ROWS = int(os.environ.get("LASERBEAK_PTY_ROWS", "40"))
COLS = int(os.environ.get("LASERBEAK_PTY_COLS", "120"))


def set_window_size(fd, rows, cols):
    import fcntl
    import struct
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    except OSError:
        pass


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("вкажи команду\n")
        return 2

    command = sys.argv[1:]

    pid, master = pty.fork()

    if pid == 0:
        # Дочірній процес: він уже всередині псевдотермінала.
        os.environ["TERM"] = os.environ.get("TERM", "xterm-256color")
        try:
            os.execvp(command[0], command)
        except OSError as err:
            sys.stderr.write(f"не вдалося запустити {command[0]}: {err}\n")
            os._exit(127)

    set_window_size(master, ROWS, COLS)

    stdin_fd = sys.stdin.fileno()
    stdout_fd = sys.stdout.fileno()

    # Дитина померла — виходимо, не чекаючи на читання.
    def on_child(_signum, _frame):
        raise SystemExit(0)

    signal.signal(signal.SIGCHLD, on_child)

    try:
        while True:
            try:
                ready, _, _ = select.select([master, stdin_fd], [], [], 0.5)
            except (OSError, InterruptedError):
                break

            if master in ready:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    break
                if not data:
                    break
                os.write(stdout_fd, data)

            if stdin_fd in ready:
                try:
                    data = os.read(stdin_fd, 65536)
                except OSError:
                    break
                if not data:
                    # Демон закрив канал — коректно завершуємо сесію.
                    os.write(master, b"\x04")
                    continue
                os.write(master, data)
    except SystemExit:
        pass
    finally:
        # Дочитуємо хвіст виводу, який міг лишитись у буфері.
        try:
            while True:
                ready, _, _ = select.select([master], [], [], 0.2)
                if not ready:
                    break
                data = os.read(master, 65536)
                if not data:
                    break
                os.write(stdout_fd, data)
        except OSError:
            pass

        try:
            os.close(master)
        except OSError:
            pass

    try:
        _, status = os.waitpid(pid, 0)
        return os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") else 0
    except (ChildProcessError, OSError):
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
