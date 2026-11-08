import asyncio
import os
from dataclasses import dataclass
from enum import StrEnum
from typing import Callable, Protocol


class MouseButton(StrEnum):
    LEFT = "left"
    RIGHT = "right"


class GameWindowNotFound(RuntimeError):
    pass


class GameWindowAPI(Protocol):
    def __init__(self, evloop: asyncio.AbstractEventLoop) -> None: ...
    def get_region(self, x: int, y: int, w: int, h: int) -> list[list[tuple[int, int, int]]]: ...
    def get_pixel(self, x: int, y: int) -> tuple[int, int, int]: ...
    def is_focused(self) -> bool: ...
    def send_keys(self, keys: str) -> None: ...
    def move_mouse(self, x: int, y: int) -> None: ...
    def click_mouse(self, button: MouseButton, release: bool=True) -> None: ...
    def set_hotkey(self, keys: str, callback: Callable[[], None]) -> None: ...
    def on_zone_change(self, callback: Callable[[ZoneEvent], None]) -> None: ...


@dataclass(frozen=True)
class ZoneEvent:
    zone: str
    timestamp: str         # timestamp
    tickkount: int         # GetTickCount() of log entry

def parse_zone_line(line: str) -> ZoneEvent | None:
    ENTERED = ": You have entered "
    i = line.find(ENTERED)
    if i < 0:
        return None
    zone = line[i + len(ENTERED):].rstrip().removesuffix(".")
    words = line.split()
    return ZoneEvent(zone=zone, timestamp=" ".join(words[:2]), tickkount=int(words[2]))


def last_zone_in_file(path: str | os.PathLike[str]) -> ZoneEvent | None:
    block_size: int = 64 * 1024
    with open(path, "rb") as f:
        size = f.seek(0, os.SEEK_END)
        n = block_size
        while True:
            start = max(0, size - n)
            f.seek(start)
            lines = f.read().split(b"\n")
            if start > 0:
                lines = lines[1:]
            for line in reversed(lines[:-1]):
                if evt := parse_zone_line(line.decode("utf-8", "replace")):
                    return evt
            if start == 0:
                return None
            n *= 2
