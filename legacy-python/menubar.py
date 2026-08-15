#!/usr/bin/env python3
"""
Menu bar UI for Open Whisper.
Shows status, allows start/stop/restart, config access, and model switching.

Usage:
    python3 menubar.py
"""
import os
import sys
import json
import shutil
import subprocess
import threading
import queue
import fcntl
import atexit
import signal
import time

# Point stdlib SSL at certifi's bundled CA store. See daemon.py for the
# full reasoning — short version: py2app's __boot__.py pre-sets
# SSL_CERT_FILE to a bogus path on purpose, and we have to overwrite it
# (assignment, not setdefault) before any SSL-touching code runs. The
# daemon child inherits these via os.environ.copy() in start_daemon.
try:
    import certifi as _certifi
    _ca_bundle = _certifi.where()
    os.environ["SSL_CERT_FILE"] = _ca_bundle
    os.environ["REQUESTS_CA_BUNDLE"] = _ca_bundle
except Exception:
    pass

import paths
from pathlib import Path
import rumps
import sounddevice as sd
import yaml
from AppKit import (
    NSApplication, NSImage, NSPasteboard, NSPasteboardTypeString,
    NSScrollView, NSTextView, NSBezelBorder,
    NSViewWidthSizable,
    NSEventModifierFlagCommand, NSEventModifierFlagShift,
    NSPanel, NSWindowStyleMaskTitled, NSWindowStyleMaskClosable,
    NSBackingStoreBuffered, NSTextField, NSButton,
    NSFont, NSColor, NSBezelStyleRounded,
)
from Foundation import (
    NSTimer, NSRunLoop, NSDate, NSRunLoopCommonModes,
    NSMakeRect, NSMakeSize, NSMakeRange, NSObject,
)
import objc


class EditableTextView(NSTextView):
    """NSTextView subclass that wires Cmd+C / V / X / A directly.

    When NSTextView is added as an NSAlert accessoryView there's no Edit
    menu in scope, so the system has nothing to route Cmd+C through and
    you get the bong. Handling performKeyEquivalent: ourselves restores
    the standard shortcuts.
    """
    def performKeyEquivalent_(self, event):
        if event.modifierFlags() & NSEventModifierFlagCommand:
            chars = (event.charactersIgnoringModifiers() or "").lower()
            if chars == "c":
                self.copy_(self)
                return True
            if chars == "v":
                self.paste_(self)
                return True
            if chars == "x":
                self.cut_(self)
                return True
            if chars == "a":
                self.selectAll_(self)
                return True
            if chars == "z":
                if event.modifierFlags() & NSEventModifierFlagShift:
                    if self.undoManager() and self.undoManager().canRedo():
                        self.undoManager().redo()
                        return True
                else:
                    if self.undoManager() and self.undoManager().canUndo():
                        self.undoManager().undo()
                        return True
        return objc_super_performKeyEquivalent(self, event)


def objc_super_performKeyEquivalent(self, event):
    # Helper to call the superclass's performKeyEquivalent without needing
    # `super()` ergonomics in pyobjc subclasses (which can be brittle).
    return objc.super(EditableTextView, self).performKeyEquivalent_(event)


class _DialogTarget(NSObject):
    """Action target *and* window delegate for the custom-panel dialogs.

    Selectors `save:` / `cancel:` route button presses to handler
    callables stored on the instance. `windowWillClose:` (NSWindowDelegate)
    fires when the user clicks the red close button or hits Cmd+W; we
    treat that as Cancel so the modal session always terminates — without
    this, `app.runModalForWindow_` never returns and the entire app is
    frozen behind an invisible modal.
    """
    def save_(self, sender):
        handler = getattr(self, '_save_handler', None)
        if handler:
            handler()

    def cancel_(self, sender):
        handler = getattr(self, '_cancel_handler', None)
        if handler:
            handler()

    def windowWillClose_(self, notification):
        handler = getattr(self, '_cancel_handler', None)
        if handler:
            handler()


# Hide Python from the Dock - Accessory policy allows menu bar but no Dock icon
def _hide_from_dock():
    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(1)  # NSApplicationActivationPolicyAccessory


LOCK_FILE = paths.state_dir() / '.open-whisper.lock'


def acquire_single_instance():
    """Ensure only one instance runs at a time. Returns lock fd or exits."""
    lock_fd = open(LOCK_FILE, 'w')
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        lock_fd.write(str(os.getpid()))
        lock_fd.flush()
        atexit.register(lambda: _release_lock(lock_fd))
        return lock_fd
    except BlockingIOError:
        print("Open Whisper is already running.", file=sys.stderr)
        sys.exit(0)


def _release_lock(lock_fd):
    """Release the lock file on exit."""
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        lock_fd.close()
        LOCK_FILE.unlink(missing_ok=True)
    except Exception:
        pass


CONFIG_PATH = paths.state_dir() / 'config.yaml'
DAEMON_SCRIPT = paths.bundle_resources_dir() / 'daemon.py'
# Lifetime word/recording counters. Keeps its historical filename so
# existing stats survive the removal of API usage tracking.
STATS_FILE = paths.state_dir() / 'api-usage.json'

# In source mode use the project's .venv (so the daemon subprocess sees the
# venv-installed packages). In a bundled .app there's no .venv — sys.executable
# is the bundled Python, which already has everything py2app put alongside it.
_DEV_VENV_PYTHON = Path(__file__).resolve().parent / '.venv' / 'bin' / 'python3'
PYTHON = str(_DEV_VENV_PYTHON) if _DEV_VENV_PYTHON.exists() else sys.executable

TRANSCRIPTION_MODELS = {
    'tiny':            'Whisper Tiny',
    'base':            'Whisper Base',
    'small':           'Whisper Small',
    'distil-medium':   'Distil Medium (EN)',
    'medium':          'Whisper Medium',
    'distil-large':    'Distil Large v3 (EN)',
    'turbo':           'Whisper Turbo',
    'large':           'Whisper Large',
}

# True when running from a built .app bundle rather than source. The
# Launch at Login toggle registers the running bundle itself, so it only
# makes sense (and only works) in bundled mode.
IN_BUNDLE = any(p.suffix == '.app' for p in Path(sys.executable).resolve().parents)

try:
    from ServiceManagement import SMAppService
except ImportError:
    SMAppService = None

# SMAppServiceStatusEnabled — the app is registered as a login item.
_SM_STATUS_ENABLED = 1

OVERLAY_STYLES = {
    'off':          'Off',
    'solid':        'Solid',
    'translucent':  'Translucent',
}


def resolve_overlay_style(cfg):
    """Normalise overlay config to 'off' / 'solid' / 'translucent'.

    Mirrors the daemon's mapping of the legacy overlay_enabled +
    overlay_translucent pair onto the single overlay_style key.
    """
    style = cfg.get('overlay_style')
    if style in OVERLAY_STYLES:
        return style
    if 'overlay_enabled' in cfg or 'overlay_translucent' in cfg:
        if not cfg.get('overlay_enabled', True):
            return 'off'
        return 'translucent' if cfg.get('overlay_translucent', True) else 'solid'
    return 'translucent'


def set_count_badge(item, count):
    """Show `count` as a native right-aligned menu badge (macOS 14+).

    Falls back to appending "(n)" to the title on older systems. A zero
    count clears the badge either way.
    """
    try:
        from AppKit import NSMenuItemBadge
        badge = NSMenuItemBadge.alloc().initWithCount_(int(count)) if count else None
        item._menuitem.setBadge_(badge)
    except Exception:
        base = item.title.split(' (')[0]
        item.title = f"{base} ({count})" if count else base


TRIGGER_KEYS = {
    'shift_r':        'Right Shift',
    'shift_l':        'Left Shift',
    'ctrl_r':         'Right Control',
    'ctrl_l':         'Left Control',
    'alt_r':          'Right Option',
    'alt_l':          'Left Option',
    'cmd_r':          'Right Command',
    'alt_r+shift_r':  'Right Option + Right Shift',
}

# Compact macOS-style keyboard symbols for status display.
KEY_SYMBOLS = {
    'shift_r': '⇧R',
    'shift_l': '⇧L',
    'ctrl_r':  '⌃R',
    'ctrl_l':  '⌃L',
    'alt_r':   '⌥R',
    'alt_l':   '⌥L',
    'cmd_r':   '⌘R',
}


def trigger_label_short(trigger_key):
    """Render a trigger key string as macOS keyboard symbols (⌥R ⇧R)."""
    parts = trigger_key.split('+')
    return ' '.join(KEY_SYMBOLS.get(p, p) for p in parts)


def truncate_smart(text, max_len):
    """Truncate at the nearest word boundary at or before max_len.
    Falls back to mid-word cut only if no whitespace is reachable.
    """
    if len(text) <= max_len:
        return text
    cut = text.rfind(' ', 0, max_len - 1)
    if cut <= max_len * 0.6:  # word boundary too far back; just hard-cut
        cut = max_len - 1
    return text[:cut].rstrip() + '…'


def _set_tooltip(item, text):
    """Attach a native hover tooltip to a rumps MenuItem.

    rumps has no tooltip API of its own, but every MenuItem wraps a real
    NSMenuItem (`._menuitem`), which does — so this drops straight to
    AppKit rather than adding a wrapper class for one method call.
    """
    item._menuitem.setToolTip_(text)


def _set_hidden(item, hidden):
    """Show or hide a rumps MenuItem in place.

    Same reasoning as _set_tooltip — rumps can add and remove items but not
    hide one, and removing would lose its position in the menu. Hiding keeps
    the row's slot so it can reappear once there's something to show.
    """
    item._menuitem.setHidden_(bool(hidden))


def format_transcript_ts(ts_str):
    """Short human timestamp for a recent-transcript entry.

    Same-day entries show the time ("14:32"); older ones add the date
    ("6 Aug 14:32"). Returns '' for missing/unparseable timestamps so
    legacy entries without one still render.
    """
    if not ts_str:
        return ''
    try:
        entry = time.strptime(ts_str, '%Y-%m-%dT%H:%M:%S')
    except (ValueError, TypeError):
        return ''
    now = time.localtime()
    if (entry.tm_year, entry.tm_yday) == (now.tm_year, now.tm_yday):
        return time.strftime('%H:%M', entry)
    return time.strftime('%-d %b %H:%M', entry)

# Menu bar logo. The icon is static (one logo for all states); running
# state is conveyed by the floating pill and the dropdown status text.
MENUBAR_ICON_DIR = paths.bundle_resources_dir() / 'SVG icons for menu bar'
MENUBAR_ICON_FILE = 'waveform.svg'
# Fallback unicode glyph if the SVG can't be loaded as a template image.
MENUBAR_ICON_FALLBACK = '\U0001F399'

# Single-line cap for the status/last-transcription menu rows — long text
# would stretch the whole dropdown. Persistent alerts that don't fit
# scroll instead of truncating (see _tick_alert_scroll); everything else
# just gets an ellipsis via truncate_smart.
STATUS_MAX_CHARS = 60
ALERT_SCROLL_STEP_TICKS = 2   # advance one character every N status-timer ticks
ALERT_SCROLL_PAUSE_TICKS = 6  # ticks to hold at each end before reversing

# Status display text. 'ready' is built dynamically from the configured
# trigger key — see OpenWhisperMenuBar._ready_label.
STATUS_LABELS = {
    'ready':        'Ready',
    'recording':    'Recording…',
    'transcribing': 'Transcribing…',
    'loading':      'Starting up…',
    'error':        'Error — check logs',
}


def load_menubar_icon():
    """Load the menu bar logo SVG as a template NSImage.

    Sized to 22.5pt to match the standard macOS menu bar icon size and
    flagged as a template so the system tints it for light/dark menu bars.
    Returns None if the SVG can't be read; the caller should fall back to
    a unicode glyph.
    """
    path = MENUBAR_ICON_DIR / MENUBAR_ICON_FILE
    image = NSImage.alloc().initWithContentsOfFile_(str(path))
    if image is None:
        return None
    image.setSize_(NSMakeSize(22.5, 22.5))
    image.setTemplate_(True)
    return image


def load_stats():
    """Load lifetime dictation stats (total words / recordings)."""
    try:
        with open(STATS_FILE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {'total_words': 0, 'total_recordings': 0}


RECENT_TRANSCRIPTS_FILE = paths.state_dir() / 'recent-transcripts.json'


def load_recent_transcripts():
    try:
        with open(RECENT_TRANSCRIPTS_FILE) as f:
            data = json.load(f)
            if isinstance(data, list):
                return data
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    return []


def show_text_editor_dialog(message, informative, default_text,
                            ok="Save", cancel="Cancel",
                            width=420, height=240):
    """Show a modal dialog with a multi-line scrollable text view.

    Built on a custom NSPanel rather than NSAlert because NSAlert always
    reserves a fixed-height icon column on the left, leaving an empty band
    above the message text when no icon is set. A bare panel lets us render
    just the heading, helper text, editor and buttons.

    Returns the edited text on OK, None on Cancel. Pressing Return inside
    the editor inserts a newline; Escape triggers Cancel.
    """
    pad_x = 20
    pad_top = 22
    pad_bottom = 16
    gap = 10

    win_width = max(width + pad_x * 2, 480)
    text_area_width = win_width - pad_x * 2

    heading_font = NSFont.boldSystemFontOfSize_(13)
    info_font = NSFont.systemFontOfSize_(11)
    btn_height = 32
    heading_height = 18

    # Lay out the wrapped informative text first so we know how tall the
    # window needs to be. `wrappingLabelWithString_` + `fittingSize`
    # silently ignores `preferredMaxLayoutWidth_` on first call and gives
    # us the *unwrapped* width, undermeasuring the height — the bottom
    # line gets clipped. `sizeToFit` after setting the preferred width is
    # the canonical fix.
    info_label = NSTextField.wrappingLabelWithString_(informative)
    info_label.setFont_(info_font)
    info_label.setTextColor_(NSColor.secondaryLabelColor())
    info_label.setPreferredMaxLayoutWidth_(text_area_width)
    info_label.sizeToFit()
    info_height = info_label.frame().size.height

    win_height = (pad_top + heading_height + gap + info_height + gap
                  + height + gap + btn_height + pad_bottom)

    panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
        NSMakeRect(0, 0, win_width, win_height),
        NSWindowStyleMaskTitled | NSWindowStyleMaskClosable,
        NSBackingStoreBuffered,
        False,
    )
    panel.setReleasedWhenClosed_(False)
    panel.setTitle_(message)

    content = panel.contentView()

    # Coordinate origin is bottom-left in AppKit, so build top-down.
    y = win_height - pad_top

    heading = NSTextField.labelWithString_(message)
    heading.setFont_(heading_font)
    heading.setFrame_(NSMakeRect(pad_x, y - heading_height, text_area_width, heading_height))
    content.addSubview_(heading)
    y -= heading_height + gap

    info_label.setFrame_(NSMakeRect(pad_x, y - info_height, text_area_width, info_height))
    content.addSubview_(info_label)
    y -= info_height + gap

    scroll = NSScrollView.alloc().initWithFrame_(
        NSMakeRect(pad_x, y - height, text_area_width, height)
    )
    scroll.setHasVerticalScroller_(True)
    scroll.setHasHorizontalScroller_(False)
    scroll.setAutohidesScrollers_(False)
    scroll.setBorderType_(NSBezelBorder)

    text_view = EditableTextView.alloc().initWithFrame_(
        NSMakeRect(0, 0, text_area_width, height)
    )
    text_view.setMinSize_(NSMakeSize(0, height))
    text_view.setMaxSize_(NSMakeSize(1e7, 1e7))
    text_view.setVerticallyResizable_(True)
    text_view.setHorizontallyResizable_(False)
    text_view.setAutoresizingMask_(NSViewWidthSizable)
    text_view.textContainer().setContainerSize_(NSMakeSize(text_area_width, 1e7))
    text_view.textContainer().setWidthTracksTextView_(True)
    text_view.setRichText_(False)
    text_view.setAllowsUndo_(True)
    text_view.setUsesFindPanel_(False)
    text_view.setAutomaticTextReplacementEnabled_(False)
    text_view.setAutomaticDashSubstitutionEnabled_(False)
    text_view.setAutomaticQuoteSubstitutionEnabled_(False)
    text_view.setAutomaticSpellingCorrectionEnabled_(False)
    initial = default_text or ""
    text_view.setString_(initial)
    text_view.setSelectedRange_(NSMakeRange(len(initial), 0))
    scroll.setDocumentView_(text_view)
    content.addSubview_(scroll)

    btn_w = 90
    btn_y = pad_bottom
    save_x = win_width - pad_x - btn_w
    cancel_x = save_x - 8 - btn_w

    result = {'text': None}
    app = NSApplication.sharedApplication()

    def _save():
        result['text'] = str(text_view.string())
        app.stopModal()

    def _cancel():
        result['text'] = None
        app.stopModal()

    target = _DialogTarget.alloc().init()
    target._save_handler = _save
    target._cancel_handler = _cancel

    cancel_btn = NSButton.alloc().initWithFrame_(
        NSMakeRect(cancel_x, btn_y, btn_w, btn_height)
    )
    cancel_btn.setTitle_(cancel)
    cancel_btn.setBezelStyle_(NSBezelStyleRounded)
    cancel_btn.setKeyEquivalent_("\x1b")  # Escape
    cancel_btn.setTarget_(target)
    cancel_btn.setAction_("cancel:")
    content.addSubview_(cancel_btn)

    save_btn = NSButton.alloc().initWithFrame_(
        NSMakeRect(save_x, btn_y, btn_w, btn_height)
    )
    save_btn.setTitle_(ok)
    save_btn.setBezelStyle_(NSBezelStyleRounded)
    # Don't set "\r" as the key equivalent — the text view legitimately
    # consumes Return for newlines, and we want clicking Save to be the
    # only commit path.
    save_btn.setTarget_(target)
    save_btn.setAction_("save:")
    content.addSubview_(save_btn)

    panel.setInitialFirstResponder_(text_view)
    panel.setDelegate_(target)
    panel.center()
    panel.makeKeyAndOrderFront_(None)
    try:
        app.runModalForWindow_(panel)
    finally:
        # Always run cleanup, even if a callback raised. Without this a
        # stray exception inside the modal loop could leave the app frozen
        # behind an invisible window.
        panel.setDelegate_(None)
        panel.orderOut_(None)

    return result['text']


def show_confirm_dialog(message, informative, ok="OK", cancel="Cancel"):
    """Modal yes/no confirmation, returns True on OK / False on Cancel.

    Uses the same custom NSPanel approach as `show_text_editor_dialog` so
    the Python framework rocket icon never appears in the column NSAlert
    would otherwise reserve.
    """
    pad_x = 20
    pad_top = 22
    pad_bottom = 16
    gap = 10
    win_width = 380
    text_area_width = win_width - pad_x * 2

    # See note in show_text_editor_dialog: sizeToFit, not fittingSize,
    # honours preferredMaxLayoutWidth and prevents bottom-line clipping.
    info_label = NSTextField.wrappingLabelWithString_(informative)
    info_label.setFont_(NSFont.systemFontOfSize_(11))
    info_label.setTextColor_(NSColor.secondaryLabelColor())
    info_label.setPreferredMaxLayoutWidth_(text_area_width)
    info_label.sizeToFit()
    info_height = info_label.frame().size.height

    heading_height = 18
    btn_height = 32
    win_height = (pad_top + heading_height + gap + info_height
                  + gap + btn_height + pad_bottom)

    panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
        NSMakeRect(0, 0, win_width, win_height),
        NSWindowStyleMaskTitled | NSWindowStyleMaskClosable,
        NSBackingStoreBuffered,
        False,
    )
    panel.setReleasedWhenClosed_(False)
    panel.setTitle_(message)

    content = panel.contentView()
    y = win_height - pad_top

    heading = NSTextField.labelWithString_(message)
    heading.setFont_(NSFont.boldSystemFontOfSize_(13))
    heading.setFrame_(NSMakeRect(pad_x, y - heading_height, text_area_width, heading_height))
    content.addSubview_(heading)
    y -= heading_height + gap

    info_label.setFrame_(NSMakeRect(pad_x, y - info_height, text_area_width, info_height))
    content.addSubview_(info_label)

    btn_w = 90
    btn_y = pad_bottom
    ok_x = win_width - pad_x - btn_w
    cancel_x = ok_x - 8 - btn_w

    result = {'ok': False}
    app = NSApplication.sharedApplication()

    def _ok():
        result['ok'] = True
        app.stopModal()

    def _cancel():
        result['ok'] = False
        app.stopModal()

    target = _DialogTarget.alloc().init()
    target._save_handler = _ok
    target._cancel_handler = _cancel

    cancel_btn = NSButton.alloc().initWithFrame_(
        NSMakeRect(cancel_x, btn_y, btn_w, btn_height)
    )
    cancel_btn.setTitle_(cancel)
    cancel_btn.setBezelStyle_(NSBezelStyleRounded)
    cancel_btn.setKeyEquivalent_("\x1b")
    cancel_btn.setTarget_(target)
    cancel_btn.setAction_("cancel:")
    content.addSubview_(cancel_btn)

    ok_btn = NSButton.alloc().initWithFrame_(
        NSMakeRect(ok_x, btn_y, btn_w, btn_height)
    )
    ok_btn.setTitle_(ok)
    ok_btn.setBezelStyle_(NSBezelStyleRounded)
    ok_btn.setKeyEquivalent_("\r")
    ok_btn.setTarget_(target)
    ok_btn.setAction_("save:")
    content.addSubview_(ok_btn)

    panel.setDelegate_(target)
    panel.center()
    panel.makeKeyAndOrderFront_(None)
    try:
        app.runModalForWindow_(panel)
    finally:
        # Always run cleanup, even if a callback raised. Without this a
        # stray exception inside the modal loop could leave the app frozen
        # behind an invisible window.
        panel.setDelegate_(None)
        panel.orderOut_(None)

    return result['ok']


def list_input_devices():
    """Return list of (display_name, device_name) for available input devices.
    Skips devices without input channels.
    """
    try:
        devices = sd.query_devices()
    except Exception:
        return []
    result = []
    seen = set()
    for d in devices:
        if d.get('max_input_channels', 0) <= 0:
            continue
        name = d.get('name', '').strip()
        if not name or name in seen:
            continue
        seen.add(name)
        result.append((name, name))
    return result


def format_stats(usage):
    """Format word/recording stats for menu display."""
    words = usage.get('total_words', 0)
    recs = usage.get('total_recordings', 0)
    if words == 0 and recs == 0:
        return "No dictations yet"
    return f"{words:,} words • {recs:,} recordings"


# Rates behind the "time saved typing" line. Both are fixed on purpose: this
# is a fun stat rather than a measurement, and deriving it from the word count
# alone means it works on stats files recorded long before the line existed.
# 40wpm is the conventional average-adult typing speed; 150wpm is a
# comfortable speaking pace.
TYPING_WPM = 40
SPEAKING_WPM = 150


def format_time_saved(usage):
    """Format the time-saved line, or None when there's nothing to show yet.

    Saved time is how long the words would have taken to type, less how long
    they'd take to say. It ignores time spent fixing misrecognitions, so treat
    it as indicative rather than a real productivity measure.
    """
    words = usage.get('total_words', 0)
    if words <= 0:
        return None
    saved_minutes = words * (1 / TYPING_WPM - 1 / SPEAKING_WPM)
    if saved_minutes < 1:
        return None
    if saved_minutes < 60:
        minutes = round(saved_minutes)
        unit = "minute" if minutes == 1 else "minutes"
        return f"{minutes} {unit} saved typing"
    hours = round(saved_minutes / 60)
    unit = "hour" if hours == 1 else "hours"
    return f"{hours} {unit} saved typing"


def load_config():
    with open(CONFIG_PATH) as f:
        return yaml.safe_load(f)


def save_config(cfg):
    with open(CONFIG_PATH, 'w') as f:
        yaml.dump(cfg, f, default_flow_style=False, sort_keys=False)


def copy_to_clipboard(text):
    """Copy text to clipboard with native API fallback."""
    try:
        pb = NSPasteboard.generalPasteboard()
        pb.clearContents()
        pb.setString_forType_(text, NSPasteboardTypeString)
        return True
    except Exception:
        try:
            subprocess.run(['pbcopy'], input=text.encode('utf-8'), check=False)
            return True
        except Exception:
            return False


class OpenWhisperMenuBar(rumps.App):
    def __init__(self):
        super().__init__("MIC", quit_button=None)
        self.daemon_proc = None
        self._menubar_icon = load_menubar_icon()
        self._status_queue = queue.Queue()
        self._last_transcription = None
        # Persistent alert for conditions that won't resolve themselves
        # (denied microphone/accessibility permission). When set, the
        # dropdown status text shows this string instead of whatever
        # transient update most recently fired.
        self._persistent_alert = None
        # Ping-pong scroll state for a persistent alert too long to fit
        # STATUS_MAX_CHARS in one line; None when nothing is scrolling.
        # See _ensure_alert_scroll / _tick_alert_scroll.
        self._scroll_state = None
        self._log_file = None
        self._daemon_exit_lock = threading.Lock()
        # --- Daemon supervisor state ---
        # Set to True by stop_daemon / quit_app so the exit handler knows
        # the next daemon termination is intentional and should not trigger
        # auto-restart.
        self._planned_shutdown = False
        # Number of consecutive unplanned exits with no successful long
        # run in between. Resets when the daemon stays alive ≥ healthy
        # threshold or the user clicks Restart.
        self._restart_attempts = 0
        self._restart_timer = None  # threading.Timer for backoff
        self._daemon_started_at = 0.0  # time.time() of last start_daemon call

        cfg = load_config()
        transcription_model = cfg.get('transcription_model', 'turbo')
        trigger_key = cfg.get('trigger_key', 'shift_r')
        self._trigger_key = trigger_key  # for dynamic 'ready' status
        advanced_cfg = cfg.get('advanced', {}) if isinstance(cfg.get('advanced', {}), dict) else {}
        streaming_enabled = bool(advanced_cfg.get('streaming_transcribe_enabled', True))
        fast_typing_enabled = bool(advanced_cfg.get('fast_typing_enabled', True))
        sound_enabled = bool(cfg.get('sound_enabled', False))
        overlay_style = resolve_overlay_style(cfg)

        # Build menu
        self.status_item = rumps.MenuItem(STATUS_LABELS['loading'])
        self.status_item.set_callback(None)

        self.last_text_item = rumps.MenuItem("No transcriptions yet")
        self.last_text_item.set_callback(self.copy_last)

        # Recent transcripts submenu, loaded from disk. Items get attached
        # after `self.menu = [...]` runs at the end of __init__.
        self.recent_transcripts_menu = rumps.MenuItem("Recent Transcripts")
        self._recent_transcripts = load_recent_transcripts()
        if self._recent_transcripts:
            first = self._recent_transcripts[0]
            first_text = first if isinstance(first, str) else first.get('text', '')
            if first_text:
                self._last_transcription = first_text
                self.last_text_item.title = f"\"{truncate_smart(first_text, 60)}\""

        # Launch at Login — native login item registration. Only meaningful
        # (and only functional) when running from a built .app bundle.
        # NOTE: the tick state is set after `self.menu = [...]` below —
        # rumps silently drops a pre-ticked MenuItem from the bulk menu
        # assembly in some combinations, so insert first, tick second.
        self.login_item = None
        if IN_BUNDLE and SMAppService is not None:
            self.login_item = rumps.MenuItem("Launch at Login", callback=self.toggle_login_item)
            _set_tooltip(self.login_item, "Starts automatically when you log in.")

        # Trigger key submenu — native style: plain title, the tick inside
        # carries the current choice (the ready status shows it anyway).
        self.trigger_items = {}
        trigger_menu = rumps.MenuItem("Trigger Key")
        _set_tooltip(trigger_menu, "Key held to record; release to transcribe.")
        self.trigger_menu = trigger_menu
        for key, label in TRIGGER_KEYS.items():
            item = rumps.MenuItem(label, callback=self.set_trigger_key)
            item._trigger_key = key
            if key == trigger_key:
                item.state = 1
            self.trigger_items[key] = item
            trigger_menu.add(item)

        # --- Settings submenu ---
        # Trigger Key and Launch at Login aren't things you change often,
        # so they've moved off the top level and in here rather than
        # getting their own permanent rows. No header for this first
        # group, to match the unlabelled groups below it — just the
        # items, then a separator into Recognition.
        settings_menu = rumps.MenuItem("Settings")
        settings_menu.add(trigger_menu)
        if self.login_item is not None:
            settings_menu.add(self.login_item)
        settings_menu.add(None)  # separator

        # Recognition ---------------------------------------------------
        # Transcription model submenu — plain title, tick inside.
        self.transcription_items = {}
        transcription_menu = rumps.MenuItem("Transcription Model")
        _set_tooltip(transcription_menu, "Whisper model size — bigger is slower but more accurate.")
        self.transcription_menu = transcription_menu
        for key, label in TRANSCRIPTION_MODELS.items():
            item = rumps.MenuItem(label, callback=self.set_transcription_model)
            item._transcription_key = key
            if key == transcription_model:
                item.state = 1
            self.transcription_items[key] = item
            transcription_menu.add(item)
        settings_menu.add(transcription_menu)

        # Vocabulary editor — term count shown as a native badge.
        self.vocabulary_item = rumps.MenuItem("Vocabulary", callback=self.set_vocabulary)
        _set_tooltip(self.vocabulary_item, "Words Whisper should recognize more easily, like names or jargon.")
        set_count_badge(self.vocabulary_item, len(cfg.get('vocabulary', []) or []))
        settings_menu.add(self.vocabulary_item)

        # Phonetic corrections — exact word replacements applied after
        # transcription, for stubborn mishearings that vocabulary biasing
        # alone can't fix (e.g. Whisper hearing "FNOL" as "ethanol").
        self.phonetic_corrections_item = rumps.MenuItem(
            "Phonetic Corrections", callback=self.set_phonetic_corrections
        )
        _set_tooltip(self.phonetic_corrections_item, "Replaces specific mishearings after transcription.")
        set_count_badge(self.phonetic_corrections_item,
                        len(cfg.get('phonetic_corrections', {}) or {}))
        settings_menu.add(self.phonetic_corrections_item)

        self.streaming_item = rumps.MenuItem("Streaming Transcribe", callback=self.toggle_streaming)
        _set_tooltip(self.streaming_item,
                     "Breaks long dictations into chunks to transcribe faster — "
                     "can leave small artifacts at the seams.")
        self.streaming_item.state = 1 if streaming_enabled else 0
        settings_menu.add(self.streaming_item)

        settings_menu.add(None)  # separator

        # Input / output -------------------------------------------------
        # Input device submenu — plain title, tick inside.
        self.input_device_items = {}
        current_device = cfg.get('input_device')
        input_device_menu = rumps.MenuItem("Input Device")
        _set_tooltip(input_device_menu, "Microphone used for recording.")
        self.input_device_menu = input_device_menu
        default_item = rumps.MenuItem("System Default", callback=self.set_input_device)
        default_item._device_name = None
        default_item.state = 1 if not current_device else 0
        self.input_device_items['__default__'] = default_item
        input_device_menu.add(default_item)
        devices = list_input_devices()
        if devices:
            input_device_menu.add(None)
            for display, name in devices:
                item = rumps.MenuItem(display, callback=self.set_input_device)
                item._device_name = name
                item.state = 1 if name == current_device else 0
                self.input_device_items[name] = item
                input_device_menu.add(item)
        settings_menu.add(input_device_menu)

        self.fast_typing_item = rumps.MenuItem("Fast Typing", callback=self.toggle_fast_typing)
        _set_tooltip(self.fast_typing_item,
                     "Inserts short transcripts directly instead of using the clipboard — quicker.")
        self.fast_typing_item.state = 1 if fast_typing_enabled else 0
        settings_menu.add(self.fast_typing_item)

        settings_menu.add(None)  # separator

        # Feedback --------------------------------------------------------
        # Overlay is a three-way pick (off / solid / translucent), replacing
        # the old pair of toggles where "Translucent" could sit ticked but
        # inert while the overlay itself was off.
        self.overlay_style_items = {}
        overlay_menu = rumps.MenuItem("Overlay")
        _set_tooltip(overlay_menu, "Floating pill shown while recording and transcribing.")
        self.overlay_menu = overlay_menu
        for key, label in OVERLAY_STYLES.items():
            item = rumps.MenuItem(label, callback=self.set_overlay_style)
            item._overlay_style = key
            if key == overlay_style:
                item.state = 1
            self.overlay_style_items[key] = item
            overlay_menu.add(item)
        settings_menu.add(overlay_menu)

        self.sound_item = rumps.MenuItem("Sound Feedback", callback=self.toggle_sound)
        _set_tooltip(self.sound_item, "Plays a sound when recording starts and stops.")
        self.sound_item.state = 1 if sound_enabled else 0
        settings_menu.add(self.sound_item)

        settings_menu.add(None)  # separator

        # Info / maintenance ----------------------------------------------
        stats = load_stats()
        self.stats_item = rumps.MenuItem(format_stats(stats))
        self.stats_item.set_callback(None)
        settings_menu.add(self.stats_item)

        # Second stats line. Hidden rather than omitted when there's nothing
        # to show yet, so it can appear after the first dictation without
        # rebuilding the menu.
        self.time_saved_item = rumps.MenuItem("")
        self.time_saved_item.set_callback(None)
        _set_tooltip(self.time_saved_item,
                     f"How long these words would take to type at {TYPING_WPM}wpm, "
                     f"less how long they'd take to say. Just for fun.")
        settings_menu.add(self.time_saved_item)
        self._refresh_time_saved(stats)

        settings_menu.add(None)  # separator

        settings_menu.add(rumps.MenuItem("Open Config", callback=self.open_config))
        settings_menu.add(rumps.MenuItem("View Logs", callback=self.view_logs))

        restart_item = rumps.MenuItem("Restart", callback=self.restart_daemon)
        _set_tooltip(restart_item, "Hard-restarts the daemon. Most settings apply without this.")

        self.menu = [
            self.status_item,
            self.last_text_item,
            self.recent_transcripts_menu,
            None,
            restart_item,
            None,
            settings_menu,
            None,
            rumps.MenuItem("Quit Open Whisper", callback=self.quit_app),
        ]

        # Populate recent-transcripts items now that the submenu is attached
        # to the NSMenu hierarchy (calling .clear() before this point fails).
        self._rebuild_recent_transcripts_menu()

        # Tick the login item only now that it's safely in the menu (see
        # note above its creation).
        if self.login_item is not None:
            try:
                svc = SMAppService.mainAppService()
                self.login_item.state = 1 if svc.status() == _SM_STATUS_ENABLED else 0
            except Exception:
                self.login_item.state = 0

    @rumps.timer(0.5)
    def _on_ready(self, sender):
        """Called once the app run loop is active. Set icon and start daemon."""
        sender.stop()
        self._install_menu_bar_icon()
        # Replace the default-mode rumps timer with one that fires in all run loop modes,
        # including NSEventTrackingRunLoopMode (active while the menu is open).
        self._status_timer = NSTimer.alloc().initWithFireDate_interval_target_selector_userInfo_repeats_(
            NSDate.date(), 0.2, self, '_processStatusQueue:', None, True)
        NSRunLoop.currentRunLoop().addTimer_forMode_(self._status_timer, NSRunLoopCommonModes)
        threading.Thread(target=self.start_daemon, daemon=True).start()

    def _processStatusQueue_(self, timer):
        """Process status updates on the main thread. Fires in all run loop modes."""
        self._process_status_queue()

    def _process_status_queue(self):
        while True:
            try:
                update = self._status_queue.get_nowait()
            except queue.Empty:
                break

            action = update.get('action')
            if action == 'status':
                # A persistent alert (e.g. denied permission) wins over any
                # transient status update — those would otherwise mask the
                # underlying problem after one normal-looking line.
                text = self._persistent_alert or update['text']
                if self._persistent_alert and len(text) > STATUS_MAX_CHARS:
                    # Too long for one line and important enough to show in
                    # full — scroll it instead of truncating. _tick_alert_scroll
                    # (called below on every timer firing) paints it.
                    self._ensure_alert_scroll(text)
                else:
                    self._scroll_state = None
                    self.status_item.title = truncate_smart(text, STATUS_MAX_CHARS)
            elif action == 'last_text':
                text = update['text']
                self._last_transcription = text
                self.last_text_item.title = f"\"{truncate_smart(text, STATUS_MAX_CHARS)}\""
                # Refresh recent-transcripts submenu from disk (daemon writes
                # the file just before emitting last_text).
                self._recent_transcripts = load_recent_transcripts()
                self._rebuild_recent_transcripts_menu()
            elif action == 'stats':
                usage = update.get('usage') or load_stats()
                self.stats_item.title = format_stats(usage)
                self._refresh_time_saved(usage)

        # Runs every timer firing (not just when the queue had something),
        # so the scroll keeps moving even while nothing new comes in.
        self._tick_alert_scroll()

    def _refresh_time_saved(self, usage):
        """Update the time-saved line, hiding it when there's nothing to show."""
        label = format_time_saved(usage)
        if label is None:
            _set_hidden(self.time_saved_item, True)
            return
        self.time_saved_item.title = label
        _set_hidden(self.time_saved_item, False)

    def _ensure_alert_scroll(self, text):
        """(Re)start the ping-pong scroll for an oversized persistent alert.

        A no-op if we're already mid-scroll on this exact message, so a
        repeated identical status update doesn't reset the animation.
        """
        if self._scroll_state and self._scroll_state['text'] == text:
            return
        self._scroll_state = {'text': text, 'pos': 0, 'dir': 1, 'pause': 0, 'ticks': 0}

    def _tick_alert_scroll(self):
        """Advance the scroll window by one character, bouncing at each end.

        Only does anything while `_scroll_state` is set — i.e. while a
        persistent alert is both active and too long for one line. Driven
        by the same 0.2s status timer as everything else, so no extra
        timer to manage.
        """
        state = self._scroll_state
        if not state:
            return
        text = state['text']
        state['ticks'] += 1
        if state['ticks'] >= ALERT_SCROLL_STEP_TICKS:
            state['ticks'] = 0
            if state['pause'] > 0:
                state['pause'] -= 1
            else:
                max_pos = len(text) - STATUS_MAX_CHARS
                state['pos'] += state['dir']
                if state['pos'] >= max_pos:
                    state['pos'], state['dir'] = max_pos, -1
                    state['pause'] = ALERT_SCROLL_PAUSE_TICKS
                elif state['pos'] <= 0:
                    state['pos'], state['dir'] = 0, 1
                    state['pause'] = ALERT_SCROLL_PAUSE_TICKS
        self.status_item.title = text[state['pos']:state['pos'] + STATUS_MAX_CHARS]

    def _rebuild_recent_transcripts_menu(self):
        """Rebuild the Recent Transcripts submenu from self._recent_transcripts."""
        # rumps lazily creates the underlying NSMenu when a submenu is first
        # interacted with; calling .clear() before that point raises
        # AttributeError. Guard it so the initial-populate-from-__init__ works.
        try:
            self.recent_transcripts_menu.clear()
        except AttributeError:
            pass
        if not self._recent_transcripts:
            empty = rumps.MenuItem("No transcripts yet")
            empty.set_callback(None)
            self.recent_transcripts_menu.add(empty)
            return
        for entry in self._recent_transcripts:
            text = entry if isinstance(entry, str) else entry.get('text', '')
            if not text:
                continue
            ts = format_transcript_ts(entry.get('ts')) if isinstance(entry, dict) else ''
            title = f"{ts}   \"{truncate_smart(text, 50)}\"" if ts else f"\"{truncate_smart(text, 50)}\""
            item = rumps.MenuItem(title, callback=self._copy_recent)
            item._full_text = text
            self.recent_transcripts_menu.add(item)
        self.recent_transcripts_menu.add(None)
        self.recent_transcripts_menu.add(rumps.MenuItem("Clear History", callback=self._clear_recent))

    def _copy_recent(self, sender):
        text = getattr(sender, '_full_text', None)
        if not text:
            return
        if copy_to_clipboard(text):
            self._queue_status("Copied to clipboard!")
            def reset():
                import time
                time.sleep(1.5)
                if self.daemon_proc and self.daemon_proc.poll() is None:
                    self._queue_status(self._ready_label())
            threading.Thread(target=reset, daemon=True).start()

    def _clear_recent(self, sender):
        if not self._recent_transcripts:
            return
        confirmed = show_confirm_dialog(
            message="Clear transcript history?",
            informative=(f"This removes all {len(self._recent_transcripts)} "
                         f"recent transcripts. Cannot be undone."),
            ok="Clear",
            cancel="Cancel",
        )
        if not confirmed:
            return
        self._recent_transcripts = []
        try:
            RECENT_TRANSCRIPTS_FILE.unlink(missing_ok=True)
        except Exception:
            pass
        self._rebuild_recent_transcripts_menu()

    def _install_menu_bar_icon(self):
        """Set the menu bar logo once at startup.

        The glyph never changes — running state is surfaced via the floating
        pill and the dropdown status text. Falls back to a unicode mic when
        the SVG can't be loaded as a template image.
        """
        if self._menubar_icon is not None:
            try:
                button = self._nsapp.nsstatusitem.button()
                button.setImage_(self._menubar_icon)
                button.setTitle_("")
                return
            except (AttributeError, Exception):
                pass
        self.title = MENUBAR_ICON_FALLBACK

    def _open_log_file(self):
        if self._log_file:
            return
        log_path = paths.log_dir() / 'daemon.log'
        # Rotate before opening so the log can't grow unbounded across
        # months of use. We rotate at file-open rather than mid-stream to
        # avoid contending with the daemon writer.
        try:
            if log_path.exists() and log_path.stat().st_size > 10 * 1024 * 1024:
                backup_path = paths.log_dir() / 'daemon.log.1'
                backup_path.unlink(missing_ok=True)
                log_path.rename(backup_path)
        except OSError:
            # Rotation is best-effort. If it fails, fall through and append
            # to whatever's there — we'd rather keep logging than refuse.
            pass
        # Explicit utf-8 + replace: the daemon's status lines contain
        # em-dashes and other non-ASCII glyphs. Default encoding inside a
        # py2app bundle can be ASCII, which would crash the watcher
        # threads on every status update.
        self._log_file = open(log_path, 'a', buffering=1,
                              encoding='utf-8', errors='replace')

    def _close_log_file(self):
        if self._log_file:
            try:
                self._log_file.close()
            except Exception:
                pass
            self._log_file = None

    # --- Daemon supervisor ---
    # If the daemon exits unexpectedly (crash, hang killed by OS, etc.) we
    # auto-restart it with exponential backoff so a single failure doesn't
    # leave the app dead. After RESTART_MAX_ATTEMPTS consecutive failures
    # without a healthy run in between, we give up and surface a sticky
    # "Stopped — click Restart" alert. The user-driven restart flow always
    # bypasses the cap.
    _RESTART_BACKOFF_BASE = 1.0       # seconds
    _RESTART_BACKOFF_FACTOR = 3.0     # 1s, 3s, 9s, 27s, 81s
    _RESTART_MAX_ATTEMPTS = 5
    _RESTART_HEALTHY_THRESHOLD = 60.0  # daemon ran ≥ this long → reset counter

    def _kill_orphaned_overlays(self):
        """Belt-and-braces cleanup of any pill subprocess left behind by a
        daemon that exited without flushing a `hide` first.

        The daemon owns the overlay's stdin pipe, so a clean daemon exit
        normally closes the pipe and the overlay terminates itself. If
        that doesn't happen (overlay stuck in main-thread work, etc.) the
        pill stays on screen forever. We can't reach the pill from here,
        so we use pgrep to find any process whose argv contains our
        overlay binary path and SIGTERM it.
        """
        overlay_bin = paths.bundle_resources_dir() / 'overlay'
        if not overlay_bin.exists():
            return
        try:
            result = subprocess.run(
                ['pgrep', '-f', str(overlay_bin)],
                capture_output=True, text=True, timeout=2,
            )
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            return
        my_pid = os.getpid()
        for pid_str in result.stdout.split():
            try:
                pid = int(pid_str)
            except ValueError:
                continue
            if pid == my_pid:
                continue
            try:
                os.kill(pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError, OSError):
                pass

    def _schedule_auto_restart(self, delay_s):
        if self._restart_timer is not None:
            self._restart_timer.cancel()
        timer = threading.Timer(delay_s, self._auto_restart_tick)
        timer.daemon = True
        self._restart_timer = timer
        timer.start()

    def _auto_restart_tick(self):
        # Re-check planned shutdown — the user may have quit while we
        # were waiting.
        if self._planned_shutdown:
            return
        try:
            self.start_daemon()
        except Exception as e:
            # Don't let a start failure crash the supervisor thread.
            self._queue_status(f"Restart failed: {e}")

    def _handle_daemon_exit(self):
        with self._daemon_exit_lock:
            if self.daemon_proc and self.daemon_proc.poll() is None:
                return
            runtime = time.time() - self._daemon_started_at if self._daemon_started_at else 0
            self.daemon_proc = None
            self._close_log_file()
            # Defensive: kill any pill the dead daemon left visible.
            self._kill_orphaned_overlays()

            if self._planned_shutdown:
                # Restart/quit invoked stop_daemon — don't auto-restart.
                self._planned_shutdown = False
                return

            # Unplanned exit. If the daemon survived a healthy stretch,
            # treat the failure as fresh rather than counting against the
            # cumulative attempt cap.
            if runtime >= self._RESTART_HEALTHY_THRESHOLD:
                self._restart_attempts = 0

            self._restart_attempts += 1
            if self._restart_attempts > self._RESTART_MAX_ATTEMPTS:
                # A specific alert (e.g. a permission problem) explains the
                # exits better than the generic give-up message — keep it.
                if not self._persistent_alert:
                    self._set_persistent_alert(
                        f"Daemon kept stopping ({self._RESTART_MAX_ATTEMPTS} attempts) — "
                        f"click Restart to try again"
                    )
                return

            delay = self._RESTART_BACKOFF_BASE * (
                self._RESTART_BACKOFF_FACTOR ** (self._restart_attempts - 1)
            )
            self._queue_status(
                f"Daemon stopped — restarting in {int(round(delay))}s "
                f"({self._restart_attempts}/{self._RESTART_MAX_ATTEMPTS})"
            )
            self._schedule_auto_restart(delay)

    def _queue_status(self, text):
        """Queue a status text change for the main thread."""
        self._status_queue.put({'action': 'status', 'text': text})

    def _set_persistent_alert(self, message):
        """Latch a sticky status message (denied permission, etc).

        Subsequent transient `_queue_status` updates won't overwrite it
        until `_clear_persistent_alert` is called, so the user always sees
        the underlying problem when they open the dropdown.
        """
        self._persistent_alert = message
        # Push a status update so the title refreshes on the main thread
        # via the existing queue plumbing.
        self._queue_status(message)

    def _clear_persistent_alert(self):
        """Drop the sticky alert. Called when the daemon reaches Ready —
        whatever was wrong has either resolved or been worked around.
        """
        if self._persistent_alert is not None:
            self._persistent_alert = None
            self._scroll_state = None
            self._queue_status(self._ready_label())

    def _queue_last_text(self, text):
        """Queue a last transcription update for the main thread."""
        self._status_queue.put({'action': 'last_text', 'text': text})

    def start_daemon(self):
        self._queue_status(STATUS_LABELS['loading'])

        cmd = [PYTHON, str(DAEMON_SCRIPT)]

        self._open_log_file()
        self._daemon_started_at = time.time()

        # Force UTF-8 on both ends. Inside a py2app bundle, locale env vars
        # don't always propagate, so without these:
        #   - the producer (daemon) might default sys.stdout encoding to
        #     ASCII and crash on the first em-dash;
        #   - the consumer (us, with `text=True`) falls back to
        #     `locale.getpreferredencoding(False)` (often ASCII too) and
        #     crashes the watcher threads on the same characters.
        env = os.environ.copy()
        env['PYTHONIOENCODING'] = 'utf-8'

        self.daemon_proc = subprocess.Popen(
            cmd,
            stderr=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            encoding='utf-8',
            errors='replace',
            bufsize=1,
            env=env,
        )

        threading.Thread(target=self._watch_stderr, daemon=True).start()
        threading.Thread(target=self._watch_events, daemon=True).start()

    def _watch_stderr(self):
        """Mirror daemon stderr to our stderr and the log file.

        Status parsing happens in _watch_events via the daemon's structured
        JSON events — stderr is kept purely as the human-readable log.
        """
        if not self.daemon_proc:
            return
        for line in self.daemon_proc.stderr:
            line = line.strip()
            print(line, file=sys.stderr, flush=True)
            if self._log_file:
                self._log_file.write(line + '\n')
                self._log_file.flush()

        self._handle_daemon_exit()

    def _watch_events(self):
        """Watch daemon stdout for structured JSON events."""
        if not self.daemon_proc or not self.daemon_proc.stdout:
            return
        for line in self.daemon_proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue

            kind = event.get('event')
            if kind == 'state':
                state = event.get('state')
                text = event.get('text')
                if state == 'ready':
                    self._clear_persistent_alert()
                if state in STATUS_LABELS:
                    label = self._ready_label() if state == 'ready' else STATUS_LABELS[state]
                    self._queue_status(text or label)
                elif text:
                    self._queue_status(text)
            elif kind == 'last_text':
                text = event.get('text', '')
                if text:
                    self._queue_last_text(text)
            elif kind == 'stats':
                usage = event.get('usage')
                if not isinstance(usage, dict):
                    usage = load_stats()
                self._status_queue.put({'action': 'stats', 'usage': usage})
            elif kind == 'permission':
                # Sticky: survives transient status updates until the daemon
                # reaches 'ready', so the user always sees what's blocking it.
                self._set_persistent_alert(event.get('message', 'Permission required'))
            elif kind == 'config_error':
                message = event.get('message', 'Check config.yaml')
                self._queue_status(f"Config error: {message}")
            elif kind == 'warning':
                message = event.get('message')
                if message:
                    self._queue_status(message)
            elif kind == 'error':
                message = event.get('message')
                self._queue_status(message or STATUS_LABELS['error'])

        self._handle_daemon_exit()

    def stop_daemon(self):
        # Mark BEFORE terminate so the watcher threads (which see the exit
        # via stream-close) read the flag as True inside _handle_daemon_exit.
        self._planned_shutdown = True
        if self._restart_timer is not None:
            self._restart_timer.cancel()
            self._restart_timer = None
        if self.daemon_proc:
            self.daemon_proc.terminate()
            try:
                self.daemon_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.daemon_proc.kill()
            self.daemon_proc = None
        self._close_log_file()

    def _ready_label(self):
        """Status string for the 'ready' state, including the current trigger."""
        return f"Ready — hold {trigger_label_short(self._trigger_key)} to dictate"

    def _restart_daemon(self):
        """Stop and restart daemon (call from background thread)."""
        self.stop_daemon()
        self.start_daemon()

    def _apply_settings(self, note="Applying settings…"):
        """Apply a saved config change to the running daemon, no restart.

        SIGHUP makes the daemon re-read config.yaml in place — the Whisper
        model stays loaded, so changes land in well under a second instead
        of the several seconds a full restart takes. Falls back to a
        restart if the daemon isn't running.
        """
        proc = self.daemon_proc
        if proc and proc.poll() is None:
            try:
                proc.send_signal(signal.SIGHUP)
                self._queue_status(note)
                return
            except Exception:
                pass
        threading.Thread(target=self._restart_daemon, daemon=True).start()

    def toggle_login_item(self, sender):
        """Register/unregister the app itself as a macOS login item."""
        try:
            svc = SMAppService.mainAppService()
            if svc.status() == _SM_STATUS_ENABLED:
                ok, err = svc.unregisterAndReturnError_(None)
            else:
                ok, err = svc.registerAndReturnError_(None)
            if not ok:
                self._queue_status(f"Login item change failed: {err}")
                return
            enabled = svc.status() == _SM_STATUS_ENABLED
            sender.state = 1 if enabled else 0
            self._queue_status(f"Launch at Login {'on' if enabled else 'off'}")
        except Exception as e:
            self._queue_status(f"Login item change failed: {e}")

    def restart_daemon(self, sender):
        # User-initiated restart bypasses the auto-restart cap and clears
        # any sticky alert (e.g. "Daemon kept stopping…", or a permission
        # message they've just resolved).
        if self._restart_timer is not None:
            self._restart_timer.cancel()
            self._restart_timer = None
        self._restart_attempts = 0
        self._clear_persistent_alert()
        threading.Thread(target=self._restart_daemon, daemon=True).start()

    def set_transcription_model(self, sender):
        model_key = sender._transcription_key
        cfg = load_config()
        cfg['transcription_model'] = model_key
        save_config(cfg)
        for key, item in self.transcription_items.items():
            item.state = 1 if key == model_key else 0
        self._apply_settings(f"Loading {TRANSCRIPTION_MODELS.get(model_key, model_key)}…")

    def set_trigger_key(self, sender):
        trigger_key = sender._trigger_key
        cfg = load_config()
        cfg['trigger_key'] = trigger_key
        save_config(cfg)
        self._trigger_key = trigger_key
        for key, item in self.trigger_items.items():
            item.state = 1 if key == trigger_key else 0
        self._apply_settings()

    def _toggle_top_flag(self, key, item, label, default=False):
        """Flip cfg[key] (top-level), update the menu item, apply live."""
        cfg = load_config()
        new_val = not bool(cfg.get(key, default))
        cfg[key] = new_val
        save_config(cfg)
        item.state = 1 if new_val else 0
        self._apply_settings(f"{label} {'on' if new_val else 'off'}")

    def toggle_streaming(self, sender):
        # Streaming is a default-on flag; absence-of-key means "on".
        cfg = load_config()
        advanced = cfg.get('advanced', {})
        if not isinstance(advanced, dict):
            advanced = {}
        new_val = not bool(advanced.get('streaming_transcribe_enabled', True))
        advanced['streaming_transcribe_enabled'] = new_val
        cfg['advanced'] = advanced
        save_config(cfg)
        self.streaming_item.state = 1 if new_val else 0
        self._apply_settings(f"Streaming transcribe {'on' if new_val else 'off'}")

    def toggle_fast_typing(self, sender):
        # Fast Typing is a default-on flag; we want absence-of-key to mean "on".
        cfg = load_config()
        advanced = cfg.get('advanced', {})
        if not isinstance(advanced, dict):
            advanced = {}
        new_val = not bool(advanced.get('fast_typing_enabled', True))
        advanced['fast_typing_enabled'] = new_val
        cfg['advanced'] = advanced
        save_config(cfg)
        self.fast_typing_item.state = 1 if new_val else 0
        self._apply_settings(f"Fast typing {'on' if new_val else 'off'}")

    def toggle_sound(self, sender):
        self._toggle_top_flag('sound_enabled', self.sound_item, 'Sound feedback')

    def set_overlay_style(self, sender):
        style = sender._overlay_style
        cfg = load_config()
        cfg['overlay_style'] = style
        # Retire the legacy pair so the config carries one source of truth.
        cfg.pop('overlay_enabled', None)
        cfg.pop('overlay_translucent', None)
        save_config(cfg)
        for key, item in self.overlay_style_items.items():
            item.state = 1 if key == style else 0
        self._apply_settings(f"Overlay: {OVERLAY_STYLES[style]}")

    def set_input_device(self, sender):
        device_name = getattr(sender, '_device_name', None)
        cfg = load_config()
        cfg['input_device'] = device_name
        save_config(cfg)
        for key, item in self.input_device_items.items():
            if device_name is None:
                item.state = 1 if key == '__default__' else 0
            else:
                item.state = 1 if key == device_name else 0
        label = device_name if device_name else 'System Default'
        self._apply_settings(f"Input device: {label}")

    def set_vocabulary(self, sender):
        cfg = load_config()
        current = cfg.get('vocabulary', []) or []
        result = show_text_editor_dialog(
            message="Vocabulary",
            informative=("One term per line. Whisper will favour these "
                         "spellings — helpful for acronyms, names and jargon."),
            default_text='\n'.join(current),
            ok="Save",
            cancel="Cancel",
            width=440,
            height=280,
        )
        if result is None:
            return
        terms = [line.strip() for line in result.splitlines() if line.strip()]
        cfg['vocabulary'] = terms
        save_config(cfg)
        set_count_badge(self.vocabulary_item, len(terms))
        self._apply_settings(f"Vocabulary saved ({len(terms)} term{'s' if len(terms) != 1 else ''})")

    def set_phonetic_corrections(self, sender):
        cfg = load_config()
        current = cfg.get('phonetic_corrections', {}) or {}
        default_text = '\n'.join(f"{k} => {v}" for k, v in current.items())
        result = show_text_editor_dialog(
            message="Phonetic Corrections",
            informative=(
                "One correction per line, in the form  misheard => correct. "
                "Whole-word matches are replaced after transcription "
                "(case-insensitive). Use for mishearings the Vocabulary "
                "list can't fix.\n\n"
                "Lines without '=>' are ignored."
            ),
            default_text=default_text,
            ok="Save",
            cancel="Cancel",
            width=440,
            height=280,
        )
        if result is None:
            return
        corrections = {}
        for line in result.splitlines():
            line = line.strip()
            if not line or '=>' not in line:
                continue
            left, _, right = line.partition('=>')
            left = left.strip()
            right = right.strip()
            if left and right:
                corrections[left] = right
        cfg['phonetic_corrections'] = corrections
        save_config(cfg)
        n = len(corrections)
        set_count_badge(self.phonetic_corrections_item, n)
        self._apply_settings(
            f"Phonetic corrections saved ({n} pair{'s' if n != 1 else ''})"
        )

    def copy_last(self, sender):
        """Copy the last transcription to clipboard."""
        if self._last_transcription:
            copied = copy_to_clipboard(self._last_transcription)
            self._queue_status("Copied to clipboard!" if copied else "Failed to copy to clipboard")
            # Reset status after a moment
            def reset():
                import time
                time.sleep(1.5)
                if self.daemon_proc and self.daemon_proc.poll() is None:
                    self._queue_status(self._ready_label())
            threading.Thread(target=reset, daemon=True).start()

    def open_config(self, sender):
        subprocess.run(['open', str(CONFIG_PATH)])

    def view_logs(self, sender):
        """Open a Terminal window tailing the live daemon log."""
        log_path = paths.log_dir() / 'daemon.log'
        log_path.touch(exist_ok=True)
        script = (
            'tell application "Terminal"\n'
            '  activate\n'
            '  do script "tail -f ' + "'" + str(log_path) + "'" + '"\n'
            'end tell'
        )
        subprocess.Popen(['osascript', '-e', script])

    def quit_app(self, sender):
        self.stop_daemon()
        self._close_log_file()
        rumps.quit_application()


def _bootstrap_state_dir():
    """First-run setup of `state_dir()`. Idempotent.

    Seeds `~/Library/Application Support/Open Whisper/config.yaml` from the
    bundled `config.example.yaml` when missing. Run at every app start,
    before the daemon subprocess is spawned (the daemon reads config.yaml
    on launch); a no-op when the config already exists.
    """
    config_target = paths.state_dir() / 'config.yaml'
    if not config_target.exists():
        example = paths.bundle_resources_dir() / 'config.example.yaml'
        if example.exists():
            shutil.copy2(example, config_target)


if __name__ == '__main__':
    acquire_single_instance()
    _hide_from_dock()
    _bootstrap_state_dir()
    OpenWhisperMenuBar().run()
