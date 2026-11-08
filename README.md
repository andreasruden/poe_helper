# PoE Helper

A tool that gives you some helpers when playing PoE.

## Setup

### Linux

Only works for Wayland + KDE currently. Dependencies are: python3.11+ python-gobject libxkbcommon.

#### Install

```sh
python -m venv --system-site-packages .venv
source .venv/bin/activate
pip install -e .
```

#### Warning

Poe helper reads hotkeys from your keyboard and mouse devices (`/dev/input/event*`). These events may not be readable
by your user. Adding yourself to the input group would enable this reading but comes with some security considerations.
Namely, you're effectively enabling keylogging for any program running as your user. I'm planning to address this
sometime, but in the meantime you'd probably be better of having a separate user for poe and this script.
