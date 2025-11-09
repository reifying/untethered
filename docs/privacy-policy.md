# Privacy Policy for Untethered

**Last Updated:** November 8, 2025

## Overview

Untethered is a voice-controlled interface for Claude Code that runs on your iOS device and connects to your own backend server. This privacy policy explains what data we collect, how we use it, and your rights.

## Data We Collect

### Voice Audio
- **What:** Temporary voice recordings during push-to-talk
- **How:** Apple Speech Recognition (on-device processing)
- **Storage:** Not stored permanently, discarded after transcription
- **Purpose:** Convert voice to text for Claude commands
- **Privacy:** Processed entirely on your device using Apple's Speech Framework

### Conversation History
- **What:** Text transcriptions of your prompts and Claude's responses
- **Storage:** Locally on your device (CoreData) and on your configured backend server
- **Purpose:** Display conversation history, enable session continuity across devices
- **Control:** You can delete individual sessions or all data at any time

### App Settings
- **What:** Backend server URL, port, voice preferences, notification settings
- **Storage:** Locally on your device (UserDefaults)
- **Purpose:** App configuration and functionality
- **Privacy:** Never leaves your device

### Command Execution History
- **What:** Shell commands executed via the app and their output
- **Storage:** Your backend server only (7-day retention)
- **Purpose:** Allow you to review command history and output
- **Control:** Managed by your backend server configuration

## How We Use Data

- All data is used solely for app functionality
- Voice audio is processed on-device by Apple's Speech Framework
- Text transcriptions are sent ONLY to your configured backend server
- **We (app developer) never receive, store, or access your data**
- No analytics, tracking, or third-party services
- No cloud services controlled by the app developer

## Data Sharing

- **Third Parties:** None. No data is shared with anyone except your configured server
- **Backend Server:** You control and configure your own backend server
- **Advertising:** None. We don't use your data for advertising
- **Analytics:** None. We don't collect analytics or usage data
- **App Developer:** We cannot access your data

## Your Backend Server

- You configure the backend server URL and port
- Data transmitted to your server is YOUR responsibility
- We recommend using secure connections (wss://) for remote access
- Backend stores session data in `~/.claude/projects/` on your server
- Command history is retained for 7 days on your server (configurable)

## Data Security

- **Local Storage:** iOS CoreData (encrypted at rest by iOS system encryption)
- **Network:** Supports both ws:// and wss:// connections to your server
- **Recommendation:** Use wss:// (secure WebSocket) or VPN for production use
- **No Cloud Backup:** Data stays on your device and your server only
- **No Third-Party Access:** App developer and third parties have no access to your data

## Your Rights

- **Access:** View all conversation history in the app
- **Delete:** Delete individual sessions or all local data from Settings
- **Export:** Copy conversation text via clipboard
- **Control:** Configure or disconnect from backend server anytime
- **Portability:** Session data stored in standard JSONL format on your server

## Data Retention

### On Your Device
- Conversation history: Retained until you manually delete
- App settings: Retained until you uninstall the app or clear data
- Voice recordings: Immediately discarded after transcription

### On Your Server
- Session data: Retained indefinitely until you delete
- Command history: 7 days (configurable in backend settings)

## Children's Privacy

Untethered is a developer tool not directed at children under 13. We do not knowingly collect data from children.

## Required Permissions

### Microphone Access
- **Purpose:** Record voice input for transcription
- **Usage:** Only while push-to-talk button is pressed
- **Privacy:** Audio processed on-device by Apple's Speech Framework

### Speech Recognition
- **Purpose:** Convert voice recordings to text
- **Usage:** On-device processing via Apple's Speech Framework
- **Privacy:** No data sent to Apple or third parties for speech recognition

### Notifications
- **Purpose:** Optional text-to-speech playback of Claude responses
- **Usage:** Only if you enable "Read Aloud" feature
- **Privacy:** Notifications show response previews

### Local Network Access
- **Purpose:** Connect to backend server on your local network
- **Usage:** WebSocket connection to user-configured server
- **Privacy:** Only connects to the server you specify

## No Third-Party Services

Untethered does not integrate any third-party services:
- No analytics platforms
- No crash reporting services
- No advertising networks
- No social media integration
- Only native Apple frameworks are used

## Changes to This Policy

We may update this privacy policy from time to time. Changes will be:
- Posted on this page with updated "Last Updated" date
- Noted in app update release notes if significant

## Contact

For privacy questions or concerns:

**Email:** privacy@910labs.dev
**Website:** https://910labs.dev
**GitHub:** https://github.com/910labs/voice-code

## Technical Details

For transparency, here are the technical specifics:

### Frameworks Used
- **Speech Framework:** On-device speech recognition
- **AVFoundation:** Audio recording and playback
- **CoreData:** Local data persistence
- **UserNotifications:** Optional text-to-speech notifications
- **Network:** WebSocket client for backend communication

### Data Formats
- **Session Storage:** JSONL (JSON Lines) format
- **Local Database:** CoreData SQLite
- **Network Protocol:** WebSocket (JSON messages with snake_case keys)

### No Tracking
- **NSPrivacyTracking:** false
- **Tracking Domains:** None
- **IDFA:** Not collected
- **Device Fingerprinting:** Not performed
- **Analytics:** Not collected

## Open Source

Untethered is open source software. You can review the complete source code at:
https://github.com/910labs/voice-code

This transparency allows you to verify exactly what the app does with your data.

## Your Data Stays Yours

**Bottom Line:** Your voice recordings, conversations, commands, and settings stay on your device and your server. We (the app developers) never see, store, or have access to any of your data. Untethered is a tool that connects your iPhone to your own infrastructure—nothing more.
