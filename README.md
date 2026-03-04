# Telegram Voice Hotkey

A macOS menu bar app for sending Telegram voice notes with a global keyboard shortcut.

Press a hotkey → record → release (or press any key) → voice note sent to Telegram.

## Features

- **Global hotkey** — works from any app, any time
- **Two recording modes** — hold-to-record or press-to-toggle
- **Two send modes:**
  - **Bot API** — sends via your bot (message appears from bot)
  - **User API** — sends via TDLib as *you* (message appears from your account)
- **Self-contained** — TDLib and ffmpeg bundled in the `.app`, no external dependencies
- **OGG/Opus** — proper Telegram voice note format with waveform player
- **Launch at login** — optional auto-start
- **Menu bar status** — shows recording state, accessibility status, hotkey info

## Install

### Download (easiest)
Download `TelegramVoiceHotkey-macOS.zip` from [Releases](https://github.com/norequests/telegram-voice-hotkey/releases), unzip, drag to `/Applications/`.

### Build from source
```bash
git clone https://github.com/norequests/telegram-voice-hotkey.git
cd telegram-voice-hotkey
./build.sh
cp -r TelegramVoiceHotkey.app /Applications/
```

First build takes ~5 minutes (compiles TDLib from source). Subsequent builds are fast.

**Build dependencies** (installed automatically via Homebrew):
- cmake, gperf, openssl (for TDLib compilation)
- ffmpeg (for OGG/Opus conversion)

## Setup

On first launch, a setup window appears:

### Bot API mode
- **Bot Token** — from [@BotFather](https://t.me/BotFather)
- **Chat ID** — the chat to send voice notes to

### User API mode (send as yourself)
- **API ID & Hash** — from [my.telegram.org](https://my.telegram.org) → API Development Tools
- **Phone number** — your Telegram phone number
- **Verification code** — sent to your Telegram app (one-time login)
- **Chat ID** — the chat to send voice notes to

Then set your **hotkey** (click the button, press your combo) and **recording mode**.

## Permissions

The app needs two macOS permissions:
- **Microphone** — auto-prompts on first use
- **Accessibility** — required for global hotkey capture. Grant in:
  System Settings → Privacy & Security → Accessibility

After granting Accessibility, the app auto-detects it (no restart needed).

## How to get your Chat ID

1. Message your bot on Telegram
2. Visit: `https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates`
3. Find `"chat":{"id":123456789}`

## Config & Logs

- Config: `~/Library/Application Support/TelegramVoiceHotkey/config.json`
- Logs: `~/Library/Application Support/TelegramVoiceHotkey/app.log`
- TDLib data: `~/Library/Application Support/TelegramVoiceHotkey/tdlib/`

Click the menu bar icon → **View Log...** to check status.

## Requirements

- macOS 13+ (Ventura or later)
- Apple Silicon or Intel

## License

MIT
