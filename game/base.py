from typing import Protocol

class GameWindowNotFound(RuntimeError):
    pass


class GameWindowAPI(Protocol):
    def get_region(self, x: int, y: int, w: int, h: int) -> list[list[tuple[int, int, int]]]: ...
    def get_pixel(self, x: int, y: int) -> tuple[int, int, int]: ...
    def is_focused(self) -> bool: ...
