# Telegram Voice Hotkey

Hold a key → records audio → release → sends voice note to Telegram → deletes local file.

Menu bar app. No hardcoded credentials — configurable by anyone.

## Build & Run

```bash
cd telegram-voice-hotkey
swift build -c release
.build/release/TelegramVoiceHotkey
```

On first launch, a setup window appears asking for:
- **Bot Token** — your Telegram bot token
- **Chat ID** — the Telegram chat ID to send to
- **Hotkey** — which function key to use (F5–F16)

Config is saved to `~/Library/Application Support/TelegramVoiceHotkey/config.json`

## Requirements

- macOS 13+
- **Microphone** permission (auto-prompts)
- **Accessibility** permission for global hotkeys:
  System Settings → Privacy & Security → Accessibility → add the app

## How to get your Chat ID

1. Message your bot on Telegram
2. Visit: `https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates`
3. Find `"chat":{"id":123456789}` — that's your chat ID

## Change settings later

Click the 🎤 menu bar icon → **Settings...**

## Auto-start on login

1. `swift build -c release`
2. Copy `.build/release/TelegramVoiceHotkey` to `/Applications/`
3. System Settings → General → Login Items → add it
