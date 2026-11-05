"""Terminal progress: one live line that shows the pipeline is working.

    with Progress("Reading files", total=16813, unit="files") as p:
        for f in files:
            ...
            p.advance(note=f.parent.name)

    with step("Loading the CLIP model"):
        load()

A background thread redraws the line ten times a second, so the spinner and
the clock keep moving even while one slow item (a huge PSD, the map layout) is
being worked on. When output isn't a terminal (piped to a file, run by a
scheduler), it prints a plain line every few seconds instead.
"""

from __future__ import annotations

import os
import shutil
import sys
import threading
import time

SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
BAR_WIDTH = 24


def _fmt_duration(s: float) -> str:
    s = int(s)
    if s < 60:
        return f"{s}s"
    if s < 3600:
        return f"{s // 60}m {s % 60:02d}s"
    return f"{s // 3600}h {(s % 3600) // 60:02d}m"


def _supports_unicode(stream) -> bool:
    enc = (getattr(stream, "encoding", None) or "").lower()
    return "utf" in enc


class Progress:
    """A live progress line. `total=None` shows a spinner and a running count."""

    def __init__(self, label: str, total: int | None = None, unit: str = "", stream=None,
                 interval: float = 0.1):
        self.label = label
        self.total = total
        self.unit = unit
        self.stream = stream or sys.stderr
        self.tty = self.stream.isatty() and os.environ.get("TERM") != "dumb"
        self.unicode = _supports_unicode(self.stream)
        self.done = 0
        self.note = ""
        self.start = time.monotonic()
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._frame = 0
        self._last_plain = 0.0
        self._thread = None
        self.interval = interval

    # -- public ---------------------------------------------------------------
    def __enter__(self):
        if self.tty:
            self._thread = threading.Thread(target=self._loop, daemon=True)
            self._thread.start()
        else:
            self._plain(force=True)
        return self

    def __exit__(self, exc_type, exc, tb):
        self.close(failed=exc_type is not None and exc_type is not KeyboardInterrupt,
                   paused=exc_type is KeyboardInterrupt)
        return False

    def advance(self, n: int = 1, note: str | None = None):
        with self._lock:
            self.done += n
            if note is not None:
                self.note = note
        if not self.tty:
            self._plain()

    def set_total(self, total: int | None):
        with self._lock:
            self.total = total

    def set_note(self, note: str):
        with self._lock:
            self.note = note

    def write(self, message: str):
        """Print a message above the live line without garbling it."""
        with self._lock:
            if self.tty:
                self.stream.write("\r\033[K" + message + "\n")
                self._draw_locked()
            else:
                self.stream.write(message + "\n")
            self.stream.flush()

    def close(self, summary: str | None = None, failed: bool = False, paused: bool = False):
        if self._stop.is_set():
            return
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=1)
        elapsed = _fmt_duration(time.monotonic() - self.start)
        mark = ("✗" if failed else "‖" if paused else "✓") if self.unicode else \
            ("x" if failed else "=" if paused else "+")
        count = ""
        if self.done:
            count = f"{self.done:,}" + (f" {self.unit}" if self.unit else "") + ", "
        state = "stopped" if failed else "paused" if paused else elapsed
        line = f"{mark} {self.label}  {summary or count + state}"
        with self._lock:
            if self.tty:
                self.stream.write("\r\033[K" + line + "\n")
            else:
                self.stream.write(line + "\n")
            self.stream.flush()

    # -- drawing -------------------------------------------------------------
    def _loop(self):
        while not self._stop.wait(self.interval):
            with self._lock:
                self._frame += 1
                self._draw_locked()

    def _line(self) -> str:
        elapsed = time.monotonic() - self.start
        spin = SPINNER[self._frame % len(SPINNER)] if self.unicode else "|/-\\"[self._frame % 4]
        parts = [f"{spin} {self.label}"]
        rate = self.done / elapsed if elapsed > 0.5 else 0
        if self.total:
            frac = min(1.0, self.done / self.total)
            fill = int(frac * BAR_WIDTH)
            full, empty = ("█", "░") if self.unicode else ("#", ".")
            parts.append(f"{full * fill}{empty * (BAR_WIDTH - fill)} {frac * 100:3.0f}%")
            parts.append(f"{self.done:,}/{self.total:,}" + (f" {self.unit}" if self.unit else ""))
            if rate and self.done < self.total:
                parts.append(f"~{_fmt_duration((self.total - self.done) / rate)} left")
        else:
            if self.done:
                parts.append(f"{self.done:,}" + (f" {self.unit}" if self.unit else ""))
            parts.append(_fmt_duration(elapsed))
        if rate >= 1 and self.total:
            parts.append(f"{rate:,.0f}/s")
        line = "  ".join(parts)
        if self.note:
            line += "  " + self.note
        width = shutil.get_terminal_size((100, 20)).columns - 1
        return line if len(line) <= width else line[: max(0, width - 1)] + "…"

    def _draw_locked(self):
        self.stream.write("\r\033[K" + self._line())
        self.stream.flush()

    def _plain(self, force: bool = False):
        now = time.monotonic()
        if force or now - self._last_plain >= 5:
            self._last_plain = now
            with self._lock:
                line = self._line()[2:]  # no spinner in logs
                self.stream.write(line + "\n")
                self.stream.flush()


def step(label: str, stream=None) -> Progress:
    """A spinner with elapsed time, for work with no countable parts."""
    return Progress(label, total=None, stream=stream)
