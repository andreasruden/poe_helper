from typing import Any
import os
import re
import time

from gi.repository import Gio, GLib

from .base import GameWindowNotFound

KWIN = "org.kde.KWin"
SHOT_PATH, SHOT_IFACE = "/org/kde/KWin/ScreenShot2", "org.kde.KWin.ScreenShot2"
RESOURCE_CLASS = "steam_app_238960"

_bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)


class GameWindow:
    def __init__(self) -> None:
        self._uuid: str | None = None
        self._geometry: tuple[int, int, int, int] | None = None
        self._geometry_refresh_time: float = 0.0

    def _find_uuid(self) -> str:
        res = _call("/WindowsRunner", "org.kde.krunner1", "Match", GLib.Variant("(s)", ("Path of Exile",))).unpack()[0]
        for match in res:
            m: re.Match[str] | None = re.search(r"\{[0-9a-fA-F-]+\}", match[0])
            if not m:
                continue
            info: dict[str, Any] = self._info(m.group(0))
            if info.get("resourceClass") == RESOURCE_CLASS:
                return m.group(0)
        raise GameWindowNotFound(f"no window with class {RESOURCE_CLASS!r} and title Path of Exile")

    @staticmethod
    def _info(uuid: str) -> dict[str, Any]:
        return _call("/KWin", "org.kde.KWin", "getWindowInfo", GLib.Variant("(s)", (uuid,))).unpack()[0]

    def geometry(self) -> tuple[int, int, int, int]:
        """Window geometry (x, y, w, h) in global coordinates; cached for refresh_s seconds."""
        now: float = time.monotonic()
        if self._geometry is not None and now - self._geometry_refresh_time < 1.0:
            return self._geometry
        try:
            if self._uuid is None:
                self._uuid = self._find_uuid()
            info: dict[str, Any] = self._info(self._uuid)
        except (GLib.Error, GameWindowNotFound):
            self._uuid = self._find_uuid()      # window might have been recreated: look it up again
            info = self._info(self._uuid)
        if info.get("minimized"):
            raise GameWindowNotFound("game window is minimized")
        x, y, w, h = (int(round(info[k])) for k in ("x", "y", "width", "height"))
        self._geometry = (x, y, w, h)
        self._geometry_refresh_time = now
        return self._geometry

    def _capture_global(self, x: int, y: int, w: int, h: int) -> tuple[dict[str, Any], bytes]:
        r, wr = os.pipe()
        fdl = Gio.UnixFDList()
        idx = fdl.append(wr)
        os.close(wr)
        opts: dict[str, Any] = {"native-resolution": GLib.Variant("b", True)}
        try:
            res = _call(SHOT_PATH, SHOT_IFACE, "CaptureArea",
                        GLib.Variant("(iiuua{sv}h)", (x, y, w, h, opts, idx)), "(a{sv})", fds=fdl).unpack()[0]
            need = res["stride"] * res["height"]
            data = bytearray()
            while len(data) < need:
                chunk: bytes = os.read(r, need - len(data))
                if not chunk:
                    break
                data += chunk
        finally:
            os.close(r)
        if len(data) < need:
            raise RuntimeError("short read from KWin screenshot pipe")
        return res, bytes(data)

    def get_region(self, x: int, y: int, w: int, h: int) -> list[list[tuple[int, int, int]]]:
        """Return rows of (r, g, b) tuples for a region given in window-relative coordinates."""
        gx, gy, gw, gh = self.geometry()
        if x < 0 or y < 0 or x + w > gw or y + h > gh:
            raise ValueError(f"region ({x},{y},{w},{h}) outside game window {gw}x{gh}")
        meta, data = self._capture_global(gx + x, gy + y, w, h)
        stride = meta["stride"]
        return [[(data[o + 2], data[o + 1], data[o])                       # bytes are B,G,R,X
                 for o in range(row * stride, row * stride + w * 4, 4)] for row in range(h)]

    def get_pixel(self, x: int, y: int) -> tuple[int, int, int]:
        """RGB tuple of the pixel at window-relative (x, y)."""
        return self.get_region(x, y, 1, 1)[0][0]


def _call(path: str, iface: str, method: str, params: GLib.Variant | None, reply_type: str | None = None,
          fds: Gio.UnixFDList | None = None, dest: str = KWIN, timeout: int = 5000) -> GLib.Variant:
    vt: GLib.VariantType | None = GLib.VariantType(reply_type) if reply_type else None
    if fds is None:
        return _bus.call_sync(dest, path, iface, method, params, vt, Gio.DBusCallFlags.NONE, timeout, None)
    res, _ = _bus.call_with_unix_fd_list_sync(dest, path, iface, method, params, vt,
                                              Gio.DBusCallFlags.NONE, timeout, fds, None)
    return res
