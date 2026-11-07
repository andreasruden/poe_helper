import atexit
from typing import Any
import os
import re
import time

from gi.repository import Gio, GLib

from .base import GameWindowNotFound

KWIN = "org.kde.KWin"
SHOT_PATH, SHOT_IFACE = "/org/kde/KWin/ScreenShot2", "org.kde.KWin.ScreenShot2"
RESOURCE_CLASS = "steam_app_238960"

FOCUS_XML = """
<node>
  <interface name="poe_helper.Focus">
    <method name="Focused">
      <arg name="uuid" type="s" direction="in"/>
      <arg name="resource_class" type="s" direction="in"/>
    </method>
  </interface>
</node>
"""

FOCUS_JS_FMTSTR = """
function sendBusReport(w) {{
  callDBus("{bus_name}", "/PoeHelper/Focus", "poe_helper.Focus", "Focused", w ? w.internalId.toString() : "",
    w ? w.resourceClass : "");
}}
workspace.windowActivated.connect(sendBusReport);
sendBusReport(workspace.activeWindow);
"""

_bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)


class GameWindow:
    def __init__(self) -> None:
        self._uuid: str | None = None
        self._geometry: tuple[int, int, int, int] | None = None
        self._geometry_refresh_time: float = 0.0
        self._install_focus_tracker()

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

    def is_focused(self) -> bool:
        while self._glib_ctx.iteration(False):
            pass
        return self.active_resource_class == RESOURCE_CLASS

    def _install_focus_tracker(self) -> None:
        self.active_uuid = None
        self.active_resource_class = None
        self._reg_id: int | None = None
        self._script_path: str | None = None
        self._glib_ctx = GLib.MainContext.default()

        interface = Gio.DBusNodeInfo.new_for_xml(FOCUS_XML).interfaces[0]
        self._reg_id = _bus.register_object("/PoeHelper/Focus", interface, self._on_focused, None, None)

        # Add the javascript script
        self._script_path = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "poe_helper_focus.js")
        with open(self._script_path, "w") as f:
            f.write(FOCUS_JS_FMTSTR.format(bus_name=_bus.get_unique_name()))
        _call("/Scripting", "org.kde.kwin.Scripting", "unloadScript", GLib.Variant("(s)", ("poe_helper_focus.js",)))
        script_id = _call("/Scripting", "org.kde.kwin.Scripting", "loadScript",
            GLib.Variant("(ss)", (self._script_path, "poe_helper_focus.js"))).unpack()[0]
        if script_id < 0:
            raise RuntimeError("KWin rejected the focus script")  # XXX: more info?
        _call(f"/Scripting/Script{script_id}", "org.kde.kwin.Script", "run", None)

        atexit.register(self._uninstall_focus_tracker)

        # Wait for the first report
        deadline = time.monotonic() + 3.0
        while self.active_resource_class is None and time.monotonic() < deadline:
            self._glib_ctx.iteration(False) or time.sleep(0.01)

    def _uninstall_focus_tracker(self) -> None:
        try:
            _call("/Scripting", "org.kde.kwin.Scripting", "unloadScript",
                  GLib.Variant("(s)", ("poe_helper_focus.js",)))
        except GLib.Error:
            pass
        if self._reg_id is not None:
            _bus.unregister_object(self._reg_id)
            self._reg_id = None
        if self._script_path is not None:
            try:
                os.unlink(self._script_path)
            except FileNotFoundError:
                pass

    def _on_focused(self, _conn, _sender, _path, _iface, method, params, invocation):
        if method == "Focused":
            uuid, resource_class = params.unpack()
            self.active_uuid = uuid or None
            self.active_resource_class = resource_class or None
        invocation.return_value(None)


def _call(path: str, iface: str, method: str, params: GLib.Variant | None, reply_type: str | None = None,
          fds: Gio.UnixFDList | None = None, dest: str = KWIN, timeout: int = 5000) -> GLib.Variant:
    vt: GLib.VariantType | None = GLib.VariantType(reply_type) if reply_type else None
    if fds is None:
        return _bus.call_sync(dest, path, iface, method, params, vt, Gio.DBusCallFlags.NONE, timeout, None)
    res, _ = _bus.call_with_unix_fd_list_sync(dest, path, iface, method, params, vt,
                                              Gio.DBusCallFlags.NONE, timeout, fds, None)
    return res
