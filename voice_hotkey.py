#!/usr/bin/env python3
"""
Telegram Voice Hotkey — Hold a key to record, release to send.
Menu bar app for macOS. No Xcode needed.

Usage:
    pip3 install pyaudio pynput requests rumps
    python3 voice_hotkey.py
"""

import os
import sys
import json
import wave
import struct
import tempfile
import threading
import time
from pathlib import Path

import pyaudio
import requests
from pynput import keyboard
import rumps

# ─── Config ──────────────────────────────────────────────────────────────────

CONFIG_DIR = Path.home() / "Library" / "Application Support" / "TelegramVoiceHotkey"
CONFIG_FILE = CONFIG_DIR / "config.json"

DEFAULT_CONFIG = {
    "bot_token": "",
    "chat_id": "",
    "hotkey": "f5",
}

def load_config():
    if CONFIG_FILE.exists():
        try:
            with open(CONFIG_FILE) as f:
                cfg = json.load(f)
            if cfg.get("bot_token") and cfg.get("chat_id"):
                return cfg
        except Exception:
            pass
    return dict(DEFAULT_CONFIG)

def save_config(cfg):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    with open(CONFIG_FILE, "w") as f:
        json.dump(cfg, f, indent=2)

# ─── Audio Recording ─────────────────────────────────────────────────────────

RATE = 44100
CHANNELS = 1
FORMAT = pyaudio.paInt16
CHUNK = 1024

class Recorder:
    def __init__(self):
        self.frames = []
        self.recording = False
        self.pa = pyaudio.PyAudio()
        self.stream = None

    def start(self):
        if self.recording:
            return
        self.frames = []
        self.recording = True
        self.stream = self.pa.open(
            format=FORMAT, channels=CHANNELS, rate=RATE,
            input=True, frames_per_buffer=CHUNK,
            stream_callback=self._callback
        )
        self.stream.start_stream()

    def _callback(self, data, frame_count, time_info, status):
        if self.recording:
            self.frames.append(data)
        return (data, pyaudio.paContinue)

    def stop(self) -> str | None:
        """Stop recording, return path to wav file or None if too short."""
        if not self.recording:
            return None
        self.recording = False
        if self.stream:
            self.stream.stop_stream()
            self.stream.close()
            self.stream = None

        if len(self.frames) < 5:  # < ~0.1s
            return None

        # Write to temp wav
        fd, path = tempfile.mkstemp(suffix=".wav")
        os.close(fd)
        with wave.open(path, "wb") as wf:
            wf.setnchannels(CHANNELS)
            wf.setsampwidth(self.pa.get_sample_size(FORMAT))
            wf.setframerate(RATE)
            wf.writeframes(b"".join(self.frames))
        return path

# ─── Telegram Sender ─────────────────────────────────────────────────────────

def send_voice(bot_token: str, chat_id: str, filepath: str) -> bool:
    url = f"https://api.telegram.org/bot{bot_token}/sendVoice"
    try:
        with open(filepath, "rb") as f:
            resp = requests.post(url, data={"chat_id": chat_id}, files={"voice": ("voice.wav", f, "audio/wav")})
        return resp.status_code == 200
    except Exception as e:
        print(f"❌ Send failed: {e}")
        return False

# ─── Menu Bar App ────────────────────────────────────────────────────────────

class VoiceHotkeyApp(rumps.App):
    def __init__(self):
        super().__init__("🎤", quit_button=None)
        self.config = load_config()
        self.recorder = Recorder()
        self.listener = None

        # Menu items
        self.status_item = rumps.MenuItem("Hold hotkey to record")
        self.menu = [
            self.status_item,
            None,  # separator
            rumps.MenuItem("Settings...", callback=self.open_settings),
            None,
            rumps.MenuItem("Quit", callback=rumps.quit_application),
        ]

        if self.is_configured:
            self.start_listener()
            self.status_item.title = f"Hold {self.config['hotkey'].upper()} to record"
        else:
            self.status_item.title = "Not configured — click Settings"
            # Auto-open settings on first run
            rumps.Timer(self.auto_settings, 1).start()

    @property
    def is_configured(self):
        return bool(self.config.get("bot_token")) and bool(self.config.get("chat_id"))

    def auto_settings(self, _):
        if not self.is_configured:
            self.open_settings(None)

    def open_settings(self, _):
        # Use osascript dialogs (no tkinter/Qt needed)
        token = self._prompt("Bot Token", "Enter your Telegram bot token:", self.config.get("bot_token", ""))
        if token is None:
            return
        chat_id = self._prompt("Chat ID", "Enter the Telegram chat ID:", self.config.get("chat_id", ""))
        if chat_id is None:
            return

        # Record hotkey combo
        rumps.notification("Telegram Voice Hotkey", "", "Press your desired hotkey combination now...")
        hotkey = self._record_hotkey()
        if hotkey is None:
            hotkey = self.config.get("hotkey", "f5")

        self.config = {"bot_token": token.strip(), "chat_id": chat_id.strip(), "hotkey": hotkey}
        save_config(self.config)

        if self.is_configured:
            self.status_item.title = f"Hold {self.config['hotkey'].upper()} to record"
            self.start_listener()
            rumps.notification("Telegram Voice Hotkey", "", f"Ready — hold {self.config['hotkey'].upper()} to record")
        else:
            self.status_item.title = "Not configured"

    def _record_hotkey(self):
        """Listen for a key combo press and return it as a string like 'ctrl+shift+/'."""
        import subprocess
        result = {"combo": None, "done": False}
        pressed_modifiers = set()
        pressed_key = None

        def on_press(key):
            nonlocal pressed_key
            if key in (keyboard.Key.ctrl, keyboard.Key.ctrl_l, keyboard.Key.ctrl_r,
                       keyboard.Key.shift, keyboard.Key.shift_l, keyboard.Key.shift_r,
                       keyboard.Key.alt, keyboard.Key.alt_l, keyboard.Key.alt_r,
                       keyboard.Key.cmd, keyboard.Key.cmd_l, keyboard.Key.cmd_r):
                if key in (keyboard.Key.ctrl, keyboard.Key.ctrl_l, keyboard.Key.ctrl_r):
                    pressed_modifiers.add("ctrl")
                elif key in (keyboard.Key.shift, keyboard.Key.shift_l, keyboard.Key.shift_r):
                    pressed_modifiers.add("shift")
                elif key in (keyboard.Key.alt, keyboard.Key.alt_l, keyboard.Key.alt_r):
                    pressed_modifiers.add("alt")
                elif key in (keyboard.Key.cmd, keyboard.Key.cmd_l, keyboard.Key.cmd_r):
                    pressed_modifiers.add("cmd")
            else:
                # Got the main key
                if hasattr(key, 'char') and key.char:
                    pressed_key = key.char
                elif hasattr(key, 'name'):
                    pressed_key = key.name
                else:
                    pressed_key = str(key)

                parts = sorted(pressed_modifiers) + [pressed_key]
                result["combo"] = "+".join(parts)
                result["done"] = True
                return False  # stop listener

        listener = keyboard.Listener(on_press=on_press)
        listener.start()
        listener.join(timeout=10)
        if listener.is_alive():
            listener.stop()

        if result["combo"]:
            print(f"🎹 Recorded hotkey: {result['combo']}")
        return result["combo"]

    def _prompt(self, title, message, default=""):
        """macOS native input dialog via osascript."""
        import subprocess
        script = f'''
        set result to display dialog "{message}" default answer "{default}" with title "{title}" buttons {{"Cancel", "OK"}} default button "OK"
        return text returned of result
        '''
        try:
            result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=60)
            if result.returncode == 0:
                return result.stdout.strip()
        except Exception:
            pass
        return None

    def start_listener(self):
        if self.listener:
            self.listener.stop()

        hotkey_str = self.config.get("hotkey", "f5").lower()
        parts = hotkey_str.split("+")
        required_modifiers = set()
        target_key_name = parts[-1]  # last part is the main key

        for p in parts[:-1]:
            required_modifiers.add(p.strip())

        # Resolve the main key
        target_key = None
        # Check function keys
        for i in range(1, 21):
            if target_key_name == f"f{i}":
                target_key = getattr(keyboard.Key, f"f{i}", None)
                break
        # Check special keys
        special = {"space": keyboard.Key.space, "tab": keyboard.Key.tab,
                   "enter": keyboard.Key.enter, "esc": keyboard.Key.esc}
        if target_key_name in special:
            target_key = special[target_key_name]

        # For single char keys, we match by char
        target_char = target_key_name if len(target_key_name) == 1 else None

        active_modifiers = set()

        def _check_modifier(key, add=True):
            mod = None
            if key in (keyboard.Key.ctrl, keyboard.Key.ctrl_l, keyboard.Key.ctrl_r):
                mod = "ctrl"
            elif key in (keyboard.Key.shift, keyboard.Key.shift_l, keyboard.Key.shift_r):
                mod = "shift"
            elif key in (keyboard.Key.alt, keyboard.Key.alt_l, keyboard.Key.alt_r):
                mod = "alt"
            elif key in (keyboard.Key.cmd, keyboard.Key.cmd_l, keyboard.Key.cmd_r):
                mod = "cmd"
            if mod:
                if add:
                    active_modifiers.add(mod)
                else:
                    active_modifiers.discard(mod)

        def _key_matches(key):
            if target_key and key == target_key:
                return True
            if target_char and hasattr(key, 'char') and key.char == target_char:
                return True
            return False

        def _modifiers_match():
            if not required_modifiers:
                return True
            return required_modifiers.issubset(active_modifiers)

        def on_press(key):
            _check_modifier(key, add=True)
            if _key_matches(key) and _modifiers_match() and not self.recorder.recording:
                self.title = "🔴"
                self.recorder.start()
                print("🔴 Recording...")

        def on_release(key):
            if _key_matches(key) and self.recorder.recording:
                self.title = "🎤"
                filepath = self.recorder.stop()
                if filepath:
                    print("📤 Sending...")
                    threading.Thread(target=self._send_and_cleanup, args=(filepath,), daemon=True).start()
                else:
                    print("⏭ Too short")
            _check_modifier(key, add=False)

        self.listener = keyboard.Listener(on_press=on_press, on_release=on_release)
        self.listener.start()

    def _send_and_cleanup(self, filepath):
        ok = send_voice(self.config["bot_token"], self.config["chat_id"], filepath)
        try:
            os.unlink(filepath)
        except Exception:
            pass
        print("✅ Sent" if ok else "❌ Failed")


if __name__ == "__main__":
    VoiceHotkeyApp().run()
