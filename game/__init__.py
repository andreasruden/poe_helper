import os
import sys

from .base import GameWindowAPI, GameWindowNotFound


def _select_gamewindow_impl() -> type[GameWindowAPI]:
    if sys.platform == "win32":
        from .window_win import GameWindow
    elif sys.platform == "linux":
        session: str = os.environ.get("XDG_SESSION_TYPE", "").lower()
        desktop: str = os.environ.get("XDG_CURRENT_DESKTOP", "").upper()
        if session == "wayland" and "KDE" in desktop:
            from .window_kde import GameWindow
        else:
            raise RuntimeError(f"Unsupported session: {session!r} on {desktop!r}")
    else:
        raise RuntimeError(f"Unsupported platform: {sys.platform}")
    return GameWindow


GameWindow: type[GameWindowAPI] = _select_gamewindow_impl()

__all__: list[str] = ["GameWindow", "GameWindowNotFound"]
