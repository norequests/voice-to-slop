# Telegram Voice Hotkey

A macOS menu bar app that lets you send Telegram voice notes to your Openclaw with a global keyboard shortcut.

Hold a hotkey → record → release → voice note sent as **you** via Telegram's User API.

> **Prerequisites:** You need an [OpenClaw](https://github.com/openclaw/openclaw) agent connected to Telegram that can receive and transcribe voice notes. See [Setup step 3](#3-set-up-your-ai-to-receive-voice-notes) for details.

## Install

### Option 1: Download ZIP (easiest)

1. Download the latest `.zip` from [**Releases**](https://github.com/norequests/telegram-voice-hotkey/releases)
2. Unzip it
3. Drag `TelegramVoiceHotkey.app` to `/Applications/`
4. Open it — if macOS blocks it, go to **System Settings → Privacy & Security** and click "Open Anyway"

> **Note:** The app is not notarized. macOS may say it's "damaged." Fix with:
> ```bash
> sudo xattr -cr /Applications/TelegramVoiceHotkey.app
> ```
> Or right-click → Open the first time.

### Option 2: Build from source

```bash
# Install dependencies
brew install cmake gperf openssl ffmpeg

# Clone and build
git clone https://github.com/norequests/telegram-voice-hotkey.git
cd telegram-voice-hotkey

# Build TDLib (first time only, ~5 minutes)
./scripts/setup-tdlib.sh

# Build the app
./build.sh

# Install
sudo rm -rf /Applications/TelegramVoiceHotkey.app
cp -r TelegramVoiceHotkey.app /Applications/
```

**Requirements:** macOS 13+ (Ventura or later), Xcode Command Line Tools (`xcode-select --install`)

## Setup

On first launch, a setup window appears.

### 1. Get Telegram API credentials

1. Go to [my.telegram.org](https://my.telegram.org)
2. Log in with your phone number
3. Click **API Development Tools**
4. Create an app (any name/description)
5. Copy your **API ID** and **API Hash**

### 2. Configure the app

- **API ID** — paste from step above
- **API Hash** — paste from step above
- **Phone** — your Telegram phone number (e.g. `+12125551234`)
- Click **Send Code** → enter the 5-digit code from Telegram
- **Chat ID** — the chat to send voice notes to (numeric ID)
- **Hotkey** — click the field and press your desired key combo
- **Mode** — hold-to-record (release sends) or press-to-toggle

### 3. Set up your AI to receive voice notes

For the full loop — send voice → AI responds — your [OpenClaw](https://github.com/openclaw/openclaw) agent needs to handle inbound audio:

1. **Connect OpenClaw to Telegram** — set up the [Telegram channel](https://docs.openclaw.ai) so your agent receives messages from your bot
2. **Transcribe with Gemini** — OpenClaw doesn't natively transcribe audio. Use a script that sends the `.ogg` file to Google Gemini's API for transcription, then your agent (Claude, etc.) handles the response

The result: hold your hotkey → speak → AI receives the transcription and replies in chat.

### 4. Grant permissions

The app needs two macOS permissions:

- **Microphone** — prompts automatically on first recording
- **Accessibility** — required for the global hotkey. Grant in:
  **System Settings → Privacy & Security → Accessibility**

The app detects when permission is granted (no restart needed).

## How to find a Chat ID

The Chat ID is the numeric ID of the Telegram chat you want to send voice notes to.

**Easiest method:** Use [@userinfobot](https://t.me/userinfobot) — forward a message from your target chat, and it'll tell you the ID.

**For a bot:** Message the bot, then visit `https://api.telegram.org/bot<TOKEN>/getUpdates` and find `"chat":{"id":123456789}`.

## Features

- **Global hotkey** — works from any app, any time
- **Sends as you** — uses Telegram's User API (TDLib), messages appear from your account
- **OGG/Opus format** — proper Telegram voice note with waveform player
- **Self-contained** — TDLib and ffmpeg bundled in the `.app`
- **Launch at login** — optional auto-start
- **Menu bar status** — live recording state, connection status, hotkey info

## Files

| Path | Description |
|------|-------------|
| `~/Library/Application Support/TelegramVoiceHotkey/config.json` | Settings |
| `~/Library/Application Support/TelegramVoiceHotkey/app.log` | App log |
| `~/Library/Application Support/TelegramVoiceHotkey/tdlib/` | Telegram session data |
| `~/Library/Application Support/TelegramVoiceHotkey/tdlib.log` | TDLib internal log |

Click the menu bar icon → **View Log...** to check status.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| "TDLib not found" | Run `./scripts/setup-tdlib.sh` then rebuild |
| Hotkey doesn't work | Check Accessibility permission in System Settings |
| "Chat not found" | Make sure Chat ID is numeric, not a username |
| App won't open | Right-click → Open, or allow in Privacy & Security |
| Corrupt session | Delete `~/Library/Application Support/TelegramVoiceHotkey/tdlib/` and re-login |

## macOS only

This is a native Swift/AppKit app. Windows and Linux are not supported. PRs welcome.

## License

MIT
