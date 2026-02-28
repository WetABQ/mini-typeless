# MiniTypeless

A lightweight macOS menu bar app for voice dictation — speak, transcribe, polish, and paste into any app.

## Features

- **Multiple STT engines** — WhisperKit (on-device), Apple Speech, OpenAI Whisper API
- **LLM text polishing** — Clean up transcriptions with Claude, OpenAI, Claude Code CLI, Codex CLI, or local MLX models
- **Global hotkey** — Press `Option + D` to start/stop dictation (customizable)
- **Auto-inject** — Transcribed text is automatically pasted into the active app
- **20+ languages** — Chinese, English, Japanese, Korean, French, German, and more
- **Fully local option** — Use WhisperKit + local MLX LLM for completely offline dictation
- **Privacy-first** — No data leaves your Mac when using local models

## Requirements

- macOS 15.0+
- Xcode 16.0+ (to build)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (to generate the Xcode project)

## Getting Started

```bash
# Clone the repo
git clone https://github.com/WetABQ/mini-typeless.git
cd mini-typeless

# Generate Xcode project
xcodegen generate

# Open in Xcode
open MiniTypeless.xcodeproj
```

Build and run from Xcode. The app lives in the menu bar.

## Configuration

All settings are accessible from the menu bar icon → Settings:

| Category | Options |
|----------|---------|
| **STT Provider** | WhisperKit (local), Apple Speech, OpenAI Whisper API |
| **LLM Provider** | Claude Code CLI, Codex CLI, Claude API, OpenAI API, Local MLX |
| **Language** | 20+ languages supported |
| **Hotkey** | Customizable global shortcut (default: `⌥D`) |
| **Injection** | Clipboard + Paste or Clipboard Only |

## How It Works

1. Press the hotkey to start recording
2. Speak naturally
3. Press the hotkey again (or click confirm) to stop
4. Audio is transcribed by your chosen STT engine
5. (Optional) LLM polishes the transcription
6. Text is injected into the active app

## Tech Stack

- Swift 6 / SwiftUI
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — On-device speech recognition
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) — Global hotkey
- [SwiftOpenAI](https://github.com/jamesrochabrun/SwiftOpenAI) — OpenAI API client
- [SwiftAnthropic](https://github.com/jamesrochabrun/SwiftAnthropic) — Claude API client

## License

[MIT](LICENSE)
