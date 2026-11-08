import asyncio
import atexit
import configparser
import json
import os
import re
import subprocess
import time
from typing import Any, Callable, Tuple

from evdev import AbsInfo, InputDevice, UInput, ecodes, list_devices
from gi.repository import Gio, GLib
from xkbcommon import xkb

from .base import GameWindowNotFound, MouseButton

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

MOUSE_BUTON_MAP = {
    MouseButton.LEFT: ecodes.BTN_LEFT,
    MouseButton.RIGHT: ecodes.BTN_RIGHT,
}

MODS: dict[str, int] = {
    "^": ecodes.KEY_LEFTCTRL,
    "!": ecodes.KEY_LEFTALT,
    "+": ecodes.KEY_LEFTSHIFT,
    "#": ecodes.KEY_LEFTMETA,
}
MOD_CODES: frozenset[int] = frozenset(MODS.values())

MOUSE_KEYS: dict[str, tuple[int, ...]] = {
    "xbutton1": (ecodes.BTN_SIDE, ecodes.BTN_BACK),
    "xbutton2": (ecodes.BTN_EXTRA, ecodes.BTN_FORWARD),
    "mbutton": (ecodes.BTN_MIDDLE,),
}

_bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)


class GameWindow:
    def __init__(self, evloop: asyncio.AbstractEventLoop) -> None:
        self.evloop: asyncio.AbstractEventLoop = evloop
        self._binds: dict[Tuple[frozenset[int], int], Callable[[], None]] = {}
        self._held: set[int] = set()
        self._uuid: str | None = None
        self._geometry: tuple[int, int, int, int] | None = None
        self._geometry_refresh_time: float = 0.0
        self._install_focus_tracker()
        self._install_evdev()

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
    
    def send_keys(self, keys: str) -> None:
        for ch in keys:
            code, mods = self._char_map[ch]
            for mod in mods:
                self._key(mod, 1)
            self._key(code, 1)
            self._key(code, 0)
            for mod in reversed(mods):
                self._key(mod, 0)

    def move_mouse(self, x: int, y: int) -> None:
        """Move the mouse to a position in window coordinates."""
        wx, wy, _, _ = self.geometry()
        self._uinput.write(ecodes.EV_ABS, ecodes.ABS_X, wx + x)
        self._uinput.write(ecodes.EV_ABS, ecodes.ABS_Y, wy + y)
        self._uinput.syn()

    def click_mouse(self, button: MouseButton, release: bool=True) -> None:
        real_button = MOUSE_BUTON_MAP[button]
        self._key(real_button, 1)
        if release:
            time.sleep(0.05)
            self._key(real_button, 0)
    
    # FIXME: We need to regenerate the binds when the layout changes
    def set_hotkey(self, keys: str, callback: Callable[[], None]) -> None:
        mods = set()
        i = 0
        while i < len(keys) - 1 and keys[i] in MODS:  # a modifier can be a bind on its own
            mods.add(MODS[keys[i]])
            i += 1
        key = keys[i:]
        if not key:
            raise ValueError(f"hotkey {keys!r} has no key")
        
        codes: tuple[int, ...]
        if len(key) == 1:
            if key not in self._char_map:
                raise ValueError(f"key {key!r} not on current layout")
            code, char_mods = self._char_map[key]
            mods |= MOD_CODES & set(char_mods)
            codes = (code,)
        elif key.lower() in MOUSE_KEYS:
            codes = MOUSE_KEYS[key.lower()]
        else:
            code = ecodes.ecodes.get(f"KEY_{key.upper()}")
            if code is None:
                raise ValueError(f"unknown key name: {key!r}")
            codes = (code,)
        for code in codes:
            self._binds[(frozenset(mods), code)] = callback
    
    def _key(self, code: int, state: int) -> None:
        self._uinput.write(ecodes.EV_KEY, code, state)
        self._uinput.syn()

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
    
    def _install_evdev(self) -> None:
        # Calculate desktop size using screend doctor
        outputs = json.loads(subprocess.check_output(["kscreen-doctor", "-j"]))["outputs"]
        enabled = [o for o in outputs if o.get("enabled")]
        w = max(o["pos"]["x"] + int(o["size"]["width"] / o.get("scale", 1)) for o in enabled)
        h = max(o["pos"]["y"] + int(o["size"]["height"] / o.get("scale", 1)) for o in enabled)

        # Install a layout index tracker & build the current layout
        _bus.signal_subscribe("org.kde.keyboard", "org.kde.KeyboardLayouts", "layoutChanged", "/Layouts",
                              None, Gio.DBusSignalFlags.NONE, self._update_char_map_cb)
        self._update_char_map()

        # Setup reading of real devices
        self._devices = []
        for path in list_devices():
            device = InputDevice(path)
            if not set(device.capabilities().get(ecodes.EV_KEY, [])):
                continue
            assert device.name != "poe_helper kb+m"
            self._devices.append(device)
            self.evloop.add_reader(device.fd, self._on_readable_device, device)

        # Install our virtual kb+m device
        keys_skip = set(range(ecodes.BTN_JOYSTICK, ecodes.BTN_WHEEL))
        capabilities = {
            ecodes.EV_KEY: [c for c in ecodes.keys if c not in keys_skip],
            ecodes.EV_ABS: [
                (ecodes.ABS_X, AbsInfo(0, 0, w - 1, 0, 0, 0)),
                (ecodes.ABS_Y, AbsInfo(0, 0, h - 1, 0, 0, 0)),
            ],
        }
        self._uinput = UInput(capabilities, "poe_helper kb+m")
        atexit.register(self._uninstall_evdev)
        time.sleep(0.5)
    
    def _uninstall_evdev(self) -> None:
        self._uinput.close()
    
    def _update_char_map_cb(self, *a) -> None:
        index = a[5].unpack()[0]
        self._update_char_map(index)

    def _update_char_map(self, layout_index=None) -> None:
        if layout_index is None:
            layout_index = _call("/Layouts", "org.kde.KeyboardLayouts", "getLayout", None, "(u)",
                                 dest="org.kde.keyboard").unpack()[0]
        self._char_map = _build_char_map(layout_index)
    
    def _on_readable_device(self, device):
        try:
            events = list(device.read())
        except OSError:
            self.evloop.remove_reader(device.fd)
            self._devices.remove(device)
            device.close()
            return
        for ev in events:
            if ev.type != ecodes.EV_KEY:
                continue
            if ev.value == 1:
                self._held.add(ev.code)
            elif ev.value == 0:
                self._held.discard(ev.code)
            self._on_key(ev.code, ev.value)

    def _on_key(self, code, value):
        if value != 1 or code in MOD_CODES or not self.is_focused():
            return
        mods = MOD_CODES & self._held
        if callback := self._binds.get((mods, code)):
            callback()

def _build_char_map(layout_index: int = 0) -> dict[str, tuple[int, tuple[int, ...]]]:
    cfg = configparser.ConfigParser(interpolation=None)
    cfg.read(os.path.expanduser("~/.config/kxkbrc"))
    sec = cfg["Layout"] if cfg.has_section("Layout") else {}
    keymap = xkb.Context().keymap_new_from_names(
        model=sec.get("Model") or None, layout=sec.get("LayoutList") or None,
        variant=sec.get("VariantList") or None, options=sec.get("Options") or None)

    shift = 1 << keymap.mod_get_index("Shift")
    altgr = 1 << keymap.mod_get_index("Mod5")  # ISO_Level3_Shift
    combos: list[tuple[int, tuple[int, ...]]] = [
        (0, ()),
        (shift, (ecodes.KEY_LEFTSHIFT,)),
        (altgr, (ecodes.KEY_RIGHTALT,)),
        (shift | altgr, (ecodes.KEY_LEFTSHIFT, ecodes.KEY_RIGHTALT)),
    ]

    out: dict[str, tuple[int, tuple[int, ...]]] = {
        "\n": (ecodes.KEY_ENTER, ()),
        "\t": (ecodes.KEY_TAB, ())
    }

    for mask, mod_keys in combos:  # fewest modifiers first so the simplest combo wins
        state = keymap.state_new()
        state.update_mask(mask, 0, 0, 0, 0, layout_index)
        for kc in range(keymap.min_keycode(), keymap.max_keycode() + 1):  # ascending: main block beats keypad
            ch = state.key_get_string(kc)
            if len(ch) == 1 and ch.isprintable() and ch not in out:
                out[ch] = (kc - 8, mod_keys)  # XKB keycode = evdev keycode + 8
    return out


def _call(path: str, iface: str, method: str, params: GLib.Variant | None, reply_type: str | None = None,
          fds: Gio.UnixFDList | None = None, dest: str = KWIN, timeout: int = 5000) -> GLib.Variant:
    vt: GLib.VariantType | None = GLib.VariantType(reply_type) if reply_type else None
    if fds is None:
        return _bus.call_sync(dest, path, iface, method, params, vt, Gio.DBusCallFlags.NONE, timeout, None)
    res, _ = _bus.call_with_unix_fd_list_sync(dest, path, iface, method, params, vt,
                                              Gio.DBusCallFlags.NONE, timeout, fds, None)
    return res
