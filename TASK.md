# Task: Add Dictation Hotkey (Voice → Clipboard)

Add a third global hotkey to Voice to Slop that records audio, transcribes it, and copies the transcription to the macOS clipboard.

## Context
This is a macOS menu bar app (Swift/AppKit) that currently has two hotkeys:
- ⌃⌥N (Control+Option+N) — record voice → send to Telegram
- ⌃⌥M (Control+Option+M) — take screenshot → send to Telegram

## New Feature
Add a third hotkey: **⌃⌥B** (Control+Option+B, keyCode 0x0B)

### Flow:
1. User presses and holds ⌃⌥B
2. Audio recording starts (same as voice hotkey)
3. User releases the hotkey
4. Audio is transcribed using the configured transcription backend (Gemini/custom endpoint)
5. Transcription text is copied to the macOS clipboard (`NSPasteboard.general`)
6. A macOS notification is shown: "Copied to clipboard" with the first ~50 chars of the transcription as subtitle
7. No Telegram message is sent — this is purely local

### Files to modify:

**Config.swift:**
- Add `dictationHotkey` configuration (keyCode: 0x0B, modifiers: 786432)
- Add `dictationKeyCode` and `dictationModifiers` stored properties

**App.swift:**
- Register third global hotkey monitor for dictation
- Create a `makeDictationClosure()` that:
  - Uses the same recording mechanism as voice
  - Transcribes using the existing transcription pipeline (`CustomTranscriber` or Gemini)
  - Instead of calling `sendVoiceMessage` or `sendTextMessage`, copies the result to clipboard
  - Shows a macOS notification on success
  - Shows an error notification on failure

**SetupWindow.swift:**
- Add a section for "Dictation Hotkey" configuration
- Same pattern as the voice and screenshot hotkey fields
- Include a brief description: "Record voice and copy transcription to clipboard"

**Do NOT modify:**
- The existing voice hotkey behavior
- The existing screenshot hotkey behavior
- The TDLib/Telegram integration
- The transcription backends themselves

### Clipboard implementation:
```swift
import AppKit

let pasteboard = NSPasteboard.general
pasteboard.clearContents()
pasteboard.setString(transcribedText, forType: .string)
```

### Notification implementation:
```swift
import UserNotifications

// Request permission on first use
UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

// Show notification
let content = UNMutableNotificationContent()
content.title = "Voice to Slop"
content.subtitle = "Copied to clipboard"
content.body = String(transcribedText.prefix(100))
let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
UNUserNotificationCenter.current().add(request)
```

### Hotkey registration pattern (follow existing):
```swift
// In App.swift, follow the same pattern as voice/screenshot hotkeys
NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
    // Check for ⌃⌥B (keyCode 0x0B, modifiers 786432)
    // Same hold-to-record or press-to-toggle pattern as voice
}
```

## Version
Bump version to 1.4.0 in the project.

## Definition of Done
- Third hotkey (⌃⌥B) records, transcribes, copies to clipboard
- macOS notification confirms the copy
- Existing voice + screenshot hotkeys unchanged
- Code compiles (Swift 5.9+, macOS 14+)
- Commit and push branch `feat/dictation-hotkey`
- Create PR to `master`
- Run: `openclaw system event --text "Done: dictation-hotkey" --mode now`

## UX Design Spec (from Gemini 3.1 Pro Designer)

Let’s get one thing straight immediately: **You have a context mismatch in your prompt.** You established the environment as a web dashboard (React + Tailwind CSS) for FUNK Coffee Bar, but the feature request is explicitly for a native macOS menu bar app (Swift/AppKit). 

As a Senior UX Designer, I am going to resolve this contradiction by assuming **this macOS app is a companion tool for the FUNK Coffee Bar managers**, and the setup window needs to visually harmonize with your existing React/Tailwind dark theme dashboard. I will design the UX for the native macOS app/menu bar interactions, using Tailwind dark mode aesthetics applied to AppKit/SwiftUI.

Here is the uncompromising, developer-ready UX specification for the "Voice to Clipboard" (⌃⌥B) feature.

---

### 1. Component Layout (AppKit / SwiftUI)

We are dealing with two primary UI surfaces: the **Menu Bar Item** and the **Setup/Preferences Window**.

**A. Menu Bar Item**
*   **Icon:** A minimalist coffee cup or waveform icon. 
*   **Dropdown Menu Hierarchy:**
    *   Current Status (e.g., "API Status: Connected")
    *   Divider
    *   Telegram 1: ⌃⌥N Voice to Telegram
    *   Telegram 2: ⌃⌥M Screenshot to Telegram
    *   **[NEW] Clipboard: ⌃⌥B Voice to Clipboard**
    *   Divider
    *   Preferences... (Opens Setup Window)
    *   Quit Voice to Slop

**B. Setup Window (Preferences)**
*   **Layout:** A fixed-size macOS preference pane. Do not make it freely resizable; that is a terrible pattern for utility settings. Constrain it to 500px wide by 600px high.
*   **Navigation:** Top segmented control or left sidebar for tabs: General, Telegram Auth, **Transcription (New)**.
*   **"Transcription" Tab Hierarchy:**
    *   **Header:** "Gemini / API Configuration"
    *   **Input Field 1:** Base URL (Optional, defaults to Gemini's endpoint).
    *   **Input Field 2 (Secure):** API Key (Secure text field, characters masked).
    *   **Dropdown:** Model Selection (e.g., `gemini-1.5-flash`, `gemini-1.5-pro`).
    *   **Header:** "Hotkeys"
    *   **Hotkey Recorder:** A standard macOS shortcut recorder component. It should display "⌃⌥B" by default but allow the user to click and press new keys to rebind if they have conflicts.

### 2. States

We must manage states gracefully, especially since AI transcription involves network latency.

*   **Idle:** Menu bar icon is standard (Slate-400 equivalent).
*   **Recording (Active):** Menu bar icon turns **Red** (Tailwind Rose-500) and pulses. 
*   **Processing (Loading):** User presses the hotkey to stop. The icon turns **Yellow/Amber** (Tailwind Amber-400) and spins or shows a processing animation. *Do not leave the user wondering if the audio was captured.*
*   **Success:** 
    *   Icon flashes **Green** (Tailwind Emerald-500) for 1 second, then returns to Idle.
    *   macOS Notification appears.
*   **Error State (API Failure, Network Drop):** 
    *   Menu bar icon flashes **Red** with an exclamation mark. 
    *   macOS Notification appears detailing the error.
*   **Empty State (0 seconds of audio):** User pressed and immediately released. Cancel the operation silently. Do not hit the API. Do not show an error.
*   **Disabled / Unconfigured:** If the user presses ⌃⌥B but hasn't entered an API key, play the macOS "Basso" (error) system sound and show a notification: "Setup Required: Please add your Gemini API key."

### 3. User Flow

*Opinion: Do not make this a "Push-to-Talk" feature (hold to record, release to stop). Holding down three keys (⌃⌥B) while trying to articulate a long thought about café inventory will cause hand cramping. Make it a **Toggle**.*

1.  **Start:** User presses `⌃⌥B`.
2.  **Feedback:** System plays a subtle, short "start" chime. Menu bar icon turns red.
3.  **Action:** User dictates (e.g., *"Inventory note: We are down to two bags of Oatly, remind morning shift to order more."*)
4.  **Stop:** User presses `⌃⌥B` again. 
5.  **Feedback:** System plays a subtle "stop" chime. Icon turns Amber and pulses.
6.  **Processing:** App hits the Gemini API. 
7.  **Resolution:** App copies the result to the macOS clipboard. 
8.  **Completion:** System triggers a macOS Notification displaying the first ~50 characters of the transcription.

### 4. Edge Cases & Error Handling

*   **No Microphone Permissions:** macOS will block the audio feed. 
    *   *UX:* On first press, macOS handles the prompt. If denied, subsequent presses must trigger a notification: "Mic Access Denied. Please enable in System Settings -> Privacy."
*   **Transcription Returns Empty:** The user had mic permissions but sat in silence. 
    *   *UX:* Fail gracefully. Notification: "No speech detected. Clipboard was not updated."
*   **API Timeout / Rate Limit:** Gemini takes > 15 seconds or throws a 429.
    *   *UX:* Stop processing animation. Show Error Notification: "Transcription failed (Rate Limited). Try again later." Do *not* overwrite the user's current clipboard with an error message.
*   **Hotkey Conflict:** ⌃⌥B is already bound by another app (e.g., Raycast). 
    *   *UX:* The shortcut recorder in the Setup Window must show a yellow warning triangle: "Shortcut in use by another application."

### 5. Accessibility

Since this is a native macOS app, we lean on `NSAccessibility`.
*   **VoiceOver Announcements:**
    *   When ⌃⌥B is pressed to start: Announce *"Recording started."*
    *   When ⌃⌥B is pressed to stop: Announce *"Processing audio."*
    *   On success: Announce *"Transcription copied to clipboard."* (Crucial for visually impaired users who won't see the notification pop-up immediately).
*   **Focus Management:** In the Setup Window, ensure standard `Tab` order flows logically: Base URL -> API Key -> Model Select -> Hotkey Bindings -> Save Button.

### 6. Responsive 

As mentioned, this is a native macOS settings window. "Responsive" in the web sense does not apply. However, window management does:
*   The Setup Window should have a `minWidth` and `maxWidth` locked. Settings windows that resize infinitely look broken and sloppy. Stick to a fixed 500x600 layout.

### 7. Copy / Labels

Be concise. Managers at FUNK Coffee Bar are busy. Do not use overly technical jargon where avoidable.

**Setup Window:**
*   **Header:** Speech-to-Text Settings
*   **API Key Label:** Gemini API Key
*   **API Key Placeholder:** `AIzaSy...`
*   **Model Label:** AI Model
*   **Help Text under API Key:** "Required to transcribe audio to your clipboard. Get your key from Google AI Studio."

**macOS Notifications:**
*   **Success Title:** Transcription Copied
*   **Success Body:** `[First 50 characters of transcription]...`
*   **Error Title:** Transcription Failed
*   **Error Body (No Mic):** Allow microphone access in System Settings.
*   **Error Body (Network):** Could not reach the API. Check your connection.

### 8. Visual Spec (Tailwind Dark Theme mapped to macOS)

To make this macOS app feel like an extension of the FUNK Coffee Bar internal React dashboard, we will override standard AppKit colors to match Tailwind's dark palette. Instruct your Swift/AppKit coding agent to use the following Hex codes for custom UI elements (like the Setup window background and custom buttons):

*   **Window Background:** `#0f172a` (Tailwind `slate-900`)
*   **Panel / Card Backgrounds:** `#1e293b` (Tailwind `slate-800`)
*   **Text (Primary):** `#f8fafc` (Tailwind `slate-50`)
*   **Text (Secondary/Muted):** `#94a3b8` (Tailwind `slate-400`)
*   **Primary Accent / Success State:** `#10b981` (Tailwind `emerald-500` - FUNK's brand color)
*   **Recording Indicator:** `#f43f5e` (Tailwind `rose-500`)
*   **Processing Indicator:** `#fbbf24` (Tailwind `amber-400`)
*   **Inputs (API Key, URL):** Background `#0f172a`, Border `#334155` (Tailwind `slate-700`), Focus Ring `#10b981`.
*   **Typography:** Do not force web fonts. Use `NSFont.systemFont(ofSize: weight:)` (San Francisco). It is the only acceptable font for a native macOS utility. 

**Instruction to the Coding Agent:** "Implement the Setup window using SwiftUI. Set the `preferredColorScheme` to `.dark`. Use custom `Color(hex:)` extensions to implement the Tailwind palette above. For the global hotkey, use `MASShortcut` or `KeyboardShortcuts` packages to handle the ⌃⌥B binding reliably outside of the app's focus."