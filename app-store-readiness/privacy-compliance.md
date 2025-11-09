# App Store Privacy Compliance Report - Untethered (Voice-Code)

**Generated:** November 8, 2025
**App Name:** Untethered
**Bundle ID:** dev.910labs.voice-code
**Version:** 1.0 (Build 18)

---

## Executive Summary

**CRITICAL ISSUES FOUND:** The app is NOT ready for App Store submission. Multiple required privacy elements are missing or incomplete.

**Status:** ❌ NOT COMPLIANT

**Priority Items:**
1. Missing Privacy Manifest (PrivacyInfo.xcprivacy) - REQUIRED
2. No Privacy Policy URL - REQUIRED
3. Incomplete Required Reason API declarations - REQUIRED
4. Missing data collection disclosures - REQUIRED

---

## 1. Privacy Policy

### Status: ❌ CRITICAL - NOT FOUND

**Issue:**
- No privacy policy document found in codebase
- No privacy policy URL configured in App Store Connect
- This is **mandatory** for App Store submission

**Required Actions:**
1. Create comprehensive privacy policy covering:
   - Voice data collection and processing
   - Speech recognition usage (Apple's on-device vs server)
   - Network communication with backend server
   - WebSocket data transmission
   - CoreData local storage
   - User notifications
   - Server URL configuration storage (UserDefaults)
   - No third-party analytics/tracking (verify and state)

2. Host privacy policy at public URL (e.g., GitHub Pages, website)

3. Add URL to Info.plist:
   ```xml
   <key>NSPrivacyPolicyURL</key>
   <string>https://yourcompany.com/privacy</string>
   ```

4. Configure privacy policy URL in App Store Connect during submission

**Key Points to Address:**
- Voice recordings are processed locally via Apple's Speech Framework (on-device)
- Text transcriptions are sent to backend WebSocket server
- Backend server URL is user-configured
- No third-party analytics, tracking, or advertising
- CoreData stores conversation history locally on device
- No data sold to third parties
- User can delete all local data

---

## 2. Privacy Manifest (PrivacyInfo.xcprivacy)

### Status: ❌ CRITICAL - MISSING

**Issue:**
No `PrivacyInfo.xcprivacy` file exists in the project. This is **required** as of iOS 17 for apps using certain APIs.

**Location:** Should be at `/Users/travisbrown/code/mono/active/voice-code/ios/VoiceCode/PrivacyInfo.xcprivacy`

**Required Content:**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- App Privacy Configuration -->
    <key>NSPrivacyTracking</key>
    <false/>

    <key>NSPrivacyTrackingDomains</key>
    <array>
        <!-- Empty - no tracking domains -->
    </array>

    <key>NSPrivacyCollectedDataTypes</key>
    <array>
        <!-- Voice Audio -->
        <dict>
            <key>NSPrivacyCollectedDataType</key>
            <string>NSPrivacyCollectedDataTypeAudioData</string>
            <key>NSPrivacyCollectedDataTypeLinked</key>
            <false/>
            <key>NSPrivacyCollectedDataTypeTracking</key>
            <false/>
            <key>NSPrivacyCollectedDataTypePurposes</key>
            <array>
                <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
            </array>
        </dict>

        <!-- User Content (conversation history) -->
        <dict>
            <key>NSPrivacyCollectedDataType</key>
            <string>NSPrivacyCollectedDataTypeOtherUserContent</string>
            <key>NSPrivacyCollectedDataTypeLinked</key>
            <false/>
            <key>NSPrivacyCollectedDataTypeTracking</key>
            <false/>
            <key>NSPrivacyCollectedDataTypePurposes</key>
            <array>
                <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
            </array>
        </dict>
    </array>

    <key>NSPrivacyAccessedAPITypes</key>
    <array>
        <!-- UserDefaults (Required Reason API) -->
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>CA92.1</string> <!-- Access info from same app -->
            </array>
        </dict>

        <!-- File timestamp (Required Reason API - if using) -->
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>C617.1</string> <!-- Displayed to user or app functionality -->
            </array>
        </dict>
    </array>
</dict>
</plist>
```

**Implementation Steps:**
1. Create `PrivacyInfo.xcprivacy` file in Xcode (File > New > File > App Privacy)
2. Add to VoiceCode target
3. Configure as shown above
4. Verify file is included in Copy Bundle Resources build phase

---

## 3. Data Collection Disclosures

### Status: ⚠️ INCOMPLETE

**Current State:**
App collects data but no formal disclosures exist beyond usage descriptions.

**Data Types Collected:**

#### 3.1 Voice Audio
- **Collection:** ✅ Yes
- **Purpose:** Voice input for Claude Code control
- **Processing:** On-device via Apple Speech Framework
- **Storage:** Temporary (during recording only, not persisted)
- **Linked to User:** No
- **Used for Tracking:** No
- **Disclosure Status:** ❌ Needs App Store Connect configuration

#### 3.2 User Content (Conversation History)
- **Collection:** ✅ Yes
- **Purpose:** Display conversation history, sync with backend
- **Storage:** Local CoreData + backend server
- **Linked to User:** No (stored by session UUID)
- **Used for Tracking:** No
- **Disclosure Status:** ❌ Needs App Store Connect configuration

#### 3.3 User Settings
- **Collection:** ✅ Yes (UserDefaults)
- **Data:** Server URL, port, voice preferences, notification settings
- **Purpose:** App functionality
- **Storage:** Local UserDefaults only
- **Linked to User:** No
- **Used for Tracking:** No
- **Disclosure Status:** ❌ Needs App Store Connect configuration

#### 3.4 Network Communication
- **Protocol:** WebSocket (ws://)
- **Destination:** User-configured server
- **Data Transmitted:** Text transcriptions, session IDs, commands
- **Security:** ⚠️ Currently unencrypted (ws:// not wss://)
- **Disclosure Status:** ❌ Needs documentation

**Required Actions:**
1. Configure data collection disclosures in App Store Connect during submission
2. For each data type above, specify:
   - Data type category
   - Collection purpose
   - Whether linked to user identity
   - Whether used for tracking
   - Whether shared with third parties

---

## 4. Usage Descriptions (Permissions)

### Status: ✅ PARTIAL - Needs Review

**Current Implementations:**

#### 4.1 Microphone Access
```xml
<key>NSMicrophoneUsageDescription</key>
<string>Untethered needs microphone access for voice input to control Claude.</string>
```
**Status:** ✅ Present
**Quality:** ✅ Good - Clear and specific
**Recommendation:** Consider adding benefit: "Untethered needs microphone access to enable hands-free voice commands for Claude Code."

#### 4.2 Speech Recognition
```xml
<key>NSSpeechRecognitionUsageDescription</key>
<string>Untethered needs speech recognition to transcribe your voice commands.</string>
```
**Status:** ✅ Present
**Quality:** ✅ Good - Clear and specific
**Recommendation:** None

#### 4.3 Notifications (Implicit)
- **Usage:** Requested at runtime via `UNUserNotificationCenter`
- **Purpose:** "Read Aloud" feature for Claude responses
- **Implementation:** ✅ Proper authorization request in `NotificationManager.swift`
- **Description:** Not required in Info.plist (handled by system prompt)

#### 4.4 Background Audio
```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
```
**Status:** ✅ Present
**Purpose:** Continue text-to-speech playback when locked
**Justification:** ✅ Valid - supports "Continue Playback When Locked" feature

**Missing Usage Descriptions:**
- None detected (app doesn't request location, camera, photos, contacts, etc.)

---

## 5. Required Reason API Declarations

### Status: ❌ INCOMPLETE

Apple requires explicit reason codes for certain APIs as of iOS 17.

**APIs Used Requiring Declarations:**

#### 5.1 UserDefaults
- **Usage:** `AppSettings.swift` - stores server URL, port, voice settings, notification preferences
- **Files:** `AppSettings.swift` (lines 11, 17, 24, 26, 33, 39, 45, 106-111)
- **Required Declaration:** ✅ Included in privacy manifest above
- **Reason Code:** CA92.1 (Access info from same app)

#### 5.2 File Timestamp APIs
- **Potential Usage:** CoreData (`NSPersistentContainer`), FileManager
- **Files:** `PersistenceController.swift`, potentially session sync
- **Required Declaration:** ✅ Included in privacy manifest above (if using)
- **Reason Code:** C617.1 (Displayed to user or app functionality)

#### 5.3 Network APIs (URLSession/WebSocket)
- **Usage:** `VoiceCodeClient.swift` - WebSocket communication
- **Current:** No tracking, no fingerprinting
- **Declaration:** Not required (no tracking purposes)
- **Note:** Uses user-configured server only

#### 5.4 System Boot Time
- **Usage:** ❓ Not detected
- **Declaration:** Not needed

#### 5.5 Disk Space
- **Usage:** ❓ Not detected
- **Declaration:** Not needed

**Action Required:**
- Add Privacy Manifest with UserDefaults and FileTimestamp declarations (see Section 2)

---

## 6. Third-Party SDK Privacy

### Status: ✅ CLEAN - No Third-Party SDKs

**Analysis:**
- No CocoaPods (no Podfile found)
- No Swift Package Manager dependencies (no Package.swift found)
- No embedded frameworks detected
- Uses only Apple's native frameworks:
  - Foundation
  - SwiftUI
  - CoreData
  - Speech (SFSpeechRecognizer)
  - AVFoundation (audio recording/playback)
  - UserNotifications
  - Combine
  - UIKit

**Conclusion:**
No third-party privacy declarations needed. This is a significant advantage for App Store review.

---

## 7. Network/Internet Permissions

### Status: ⚠️ NEEDS DOCUMENTATION

**Current Implementation:**

#### 7.1 WebSocket Connection
- **Protocol:** ws:// (unencrypted)
- **Destination:** User-configured server (default: ws://[user-input]:8080)
- **Purpose:** Real-time communication with voice-code backend
- **Data Transmitted:**
  - Voice transcriptions (text)
  - Session UUIDs
  - Working directory paths
  - Command execution requests
  - Claude responses

#### 7.2 Security Concerns
**Issue:** ⚠️ Unencrypted WebSocket (ws:// not wss://)
- **Risk:** Data transmitted in plaintext
- **Mitigation:** Currently relies on VPN (Tailscale mentioned in README)
- **Recommendation:** Strongly suggest supporting wss:// for App Store

#### 7.3 ATS (App Transport Security)
**Status:** ❌ Likely needs exception for ws://

**Required:** Add to Info.plist if keeping ws://
```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
    <!-- Or more specific: -->
    <key>NSExceptionDomains</key>
    <dict>
        <!-- Allow user-configured domains -->
    </dict>
</dict>
```

**Note:** Apple may reject ws:// usage. Strongly recommend wss:// support.

#### 7.4 Network Usage Justification
**Purpose Statement (for App Store):**
"Untethered connects to a user-configured backend server to send voice commands and receive Claude Code responses. The connection enables real-time communication between your iPhone and your development environment."

---

## 8. User Data Handling Transparency

### Status: ⚠️ NEEDS IMPROVEMENT

#### 8.1 Data Persistence
**Local Storage:**
- **CoreData:** Session metadata, conversation history
- **UserDefaults:** Server settings, preferences
- **Location:** Device only (not iCloud synced)
- **Deletion:** ⚠️ No explicit "Delete All Data" feature detected

**Backend Storage:**
- **Server:** User-controlled (not app developer)
- **Data:** Session JSONL files (`~/.claude/projects/**/*.jsonl`)
- **Responsibility:** User's server, not app developer
- **Disclosure:** ❌ Must be documented in privacy policy

#### 8.2 Data Sharing
**Status:** ✅ No data shared with app developer or third parties
- No analytics SDKs
- No crash reporting SDKs
- No advertising SDKs
- Data goes only to user's configured server

#### 8.3 User Control
**Current:**
- ✅ Server URL configurable by user
- ✅ Voice selection configurable
- ✅ Notification opt-in
- ⚠️ No "Export Data" feature
- ⚠️ No "Delete Account/Data" feature (local data)

**Recommendations:**
1. Add Settings option: "Clear All Local Data"
2. Add data export feature (helpful for GDPR-like compliance)
3. Document how to clear backend data (user's server)

#### 8.4 Data Retention
**Local:**
- Indefinite (until user deletes session)
- No automatic cleanup detected

**Backend:**
- Command history: 7 days (per `STANDARDS.md`)
- Session data: Indefinite (user controls)

**Recommendation:**
Document retention policies in privacy policy.

---

## 9. Encryption Declaration

### Status: ✅ CORRECT

**Current Setting:**
```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

**Analysis:**
- ✅ Correct if only using Apple's standard HTTPS/TLS
- ⚠️ WebSocket uses ws:// (unencrypted) not wss://
- ✅ No custom cryptography detected
- ✅ Speech recognition uses Apple's on-device processing

**Verification:**
Setting is appropriate given current implementation. If wss:// is added (recommended), this setting remains correct as it would use standard TLS.

---

## 10. Privacy Nutrition Labels (App Store Connect)

### Status: ❌ NOT CONFIGURED

**Required for Submission:**
Must configure in App Store Connect under "App Privacy" section.

**Recommended Responses:**

#### Data Collection Summary:
**Collected:**
- Audio Data (voice recordings) - temporary, not stored
- User Content (conversation text) - stored locally and on user's server
- Product Interaction (usage of app features) - local only

**NOT Collected:**
- Contact Info
- Location
- Identifiers (IDFA, device ID)
- Usage Data for analytics
- Diagnostics
- Financial Info
- Health & Fitness
- Contacts
- User Content beyond conversation history

#### Data Linked to User:
**Answer:** No
**Rationale:** Sessions identified by UUID only, no personal identifiers

#### Data Used to Track:
**Answer:** No
**Rationale:** No analytics, no third-party SDKs, no tracking

#### Data Purposes:
1. **App Functionality** - All data collected serves app operation only
2. **Analytics** - None
3. **App Personalization** - Voice preference only (local)
4. **Advertising** - None

---

## 11. Additional Requirements

### 11.1 TestFlight Privacy
**Status:** ⚠️ REVIEW NEEDED
- TestFlight has same privacy requirements as App Store
- Beta testers see privacy summary
- Must be configured before external TestFlight release

### 11.2 Sign in with Apple
**Status:** ✅ N/A - No authentication system

### 11.3 Children's Privacy (COPPA)
**Status:** ⚠️ NEEDS DECISION
- No age gate detected
- App Store rating will determine if subject to COPPA
- **Recommendation:** Rate 4+ (general audience) and state not directed at children

### 11.4 Privacy by Design
**Current Status:**
- ✅ No unnecessary permissions
- ✅ No third-party tracking
- ✅ Minimal data collection
- ✅ User-controlled backend
- ⚠️ Unencrypted transport (ws://)
- ⚠️ No data deletion feature

---

## 12. Compliance Checklist

### Critical (Must Fix Before Submission)
- [ ] Create and host privacy policy
- [ ] Add privacy policy URL to Info.plist and App Store Connect
- [ ] Create PrivacyInfo.xcprivacy manifest
- [ ] Add Required Reason API declarations (UserDefaults, FileTimestamp)
- [ ] Configure App Store Connect privacy nutrition labels
- [ ] Add ATS exception for ws:// OR implement wss://

### High Priority (Strongly Recommended)
- [ ] Implement wss:// support for secure WebSocket
- [ ] Add "Clear Local Data" feature in Settings
- [ ] Document data retention policies
- [ ] Add data export feature
- [ ] Review and improve usage description strings

### Medium Priority (Nice to Have)
- [ ] Add in-app privacy policy link
- [ ] Implement session auto-cleanup (optional retention period)
- [ ] Add privacy indicator in UI (when mic is active)

### Low Priority (Future Enhancement)
- [ ] GDPR-compliant data export (JSON format)
- [ ] Privacy dashboard showing collected data
- [ ] Consent management for notifications

---

## 13. Specific File Changes Needed

### 13.1 Create: PrivacyInfo.xcprivacy
**Location:** `/Users/travisbrown/code/mono/active/voice-code/ios/VoiceCode/PrivacyInfo.xcprivacy`
**Content:** See Section 2 above
**Action:** Create in Xcode, add to VoiceCode target

### 13.2 Update: Info.plist
**Location:** `/Users/travisbrown/code/mono/active/voice-code/ios/VoiceCode/Info.plist`

**Add:**
```xml
<key>NSPrivacyPolicyURL</key>
<string>https://your-domain.com/privacy-policy</string>

<!-- If keeping ws:// -->
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
</dict>
```

### 13.3 Create: Privacy Policy Document
**Location:** New file (host externally)
**Action:** Write comprehensive privacy policy covering all findings above

### 13.4 Update: AppSettings.swift (Optional)
**Location:** `/Users/travisbrown/code/mono/active/voice-code/ios/VoiceCode/Managers/AppSettings.swift`
**Action:** Add method to clear all UserDefaults (for "Clear Data" feature)

### 13.5 Create: SettingsView additions (Optional)
**Location:** `/Users/travisbrown/code/mono/active/voice-code/ios/VoiceCode/Views/SettingsView.swift`
**Action:** Add "Clear Local Data" button, "Privacy Policy" link

---

## 14. Privacy Policy Template

Below is a template to get started (customize for your needs):

```markdown
# Privacy Policy for Untethered

Last Updated: [Date]

## Overview
Untethered is a voice-controlled interface for Claude Code. This privacy policy explains what data we collect, how we use it, and your rights.

## Data We Collect

### Voice Audio
- **What:** Temporary voice recordings during push-to-talk
- **How:** Apple Speech Recognition (on-device processing)
- **Storage:** Not stored, discarded after transcription
- **Purpose:** Convert voice to text for Claude commands

### Conversation History
- **What:** Text transcriptions of your prompts and Claude's responses
- **Storage:** Locally on your device (CoreData) and on your configured backend server
- **Purpose:** Display conversation history, enable session continuity
- **Control:** You can delete individual sessions or all data

### App Settings
- **What:** Server URL, port, voice preferences, notification settings
- **Storage:** Locally on your device (UserDefaults)
- **Purpose:** App configuration and functionality

## How We Use Data

- All data is used solely for app functionality
- Voice audio is processed on-device by Apple's Speech Framework
- Text transcriptions are sent ONLY to your configured backend server
- We (app developer) never receive, store, or access your data
- No analytics, tracking, or third-party services

## Data Sharing

- **Third Parties:** None. No data shared with anyone except your configured server
- **Backend Server:** You control and configure your own backend
- **Advertising:** None. We don't use your data for advertising
- **Analytics:** None. We don't collect analytics or usage data

## Your Backend Server

- You configure the backend server URL
- Data transmitted to your server is YOUR responsibility
- We recommend using secure connections (wss://) and VPN for remote access
- Backend stores session data in `~/.claude/projects/` on your server

## Data Security

- Local data stored in iOS CoreData (encrypted at rest by iOS)
- Network: Currently supports ws:// (unencrypted). Use VPN for security or configure wss://
- No data transmitted to app developer or third parties
- No cloud backup (data stays on device and your server)

## Your Rights

- **Access:** View all conversation history in the app
- **Delete:** Delete individual sessions or all local data (Settings)
- **Export:** [Feature not yet implemented]
- **Control:** Configure or disconnect from backend server anytime

## Children's Privacy

Untethered is not directed at children under 13. We do not knowingly collect data from children.

## Changes

We may update this policy. Changes will be posted in the app and on this page.

## Contact

[Your contact information]

## Technical Details

- **Platform:** iOS
- **Data Storage:** CoreData (local), user's backend server
- **Encryption:** iOS default encryption, optional wss://
- **Third-Party SDKs:** None
- **Analytics:** None
```

---

## 15. Timeline and Next Steps

### Immediate (Before ANY Submission)
1. **Week 1:**
   - Create privacy policy document
   - Host privacy policy at public URL
   - Create PrivacyInfo.xcprivacy file

2. **Week 1:**
   - Update Info.plist with privacy policy URL
   - Add ATS exception if needed
   - Test privacy manifest validation

3. **Week 2:**
   - Configure App Store Connect privacy labels
   - Add "Clear Local Data" feature
   - Test all privacy-related features

### Recommended (Before Public Release)
4. **Week 2-3:**
   - Implement wss:// support
   - Add privacy policy link in app
   - Security audit of network communication

5. **Week 3-4:**
   - Beta test with TestFlight (privacy labels visible)
   - Collect feedback on privacy concerns
   - Final privacy review

---

## 16. Risk Assessment

### High Risk (Likely Rejection)
- ❌ Missing privacy policy URL
- ❌ Missing PrivacyInfo.xcprivacy
- ⚠️ Unencrypted ws:// without justification

### Medium Risk (May Cause Delay)
- ⚠️ Incomplete App Store Connect privacy labels
- ⚠️ Missing ATS configuration

### Low Risk (Acceptable)
- ✅ Usage descriptions present
- ✅ No third-party SDKs
- ✅ Minimal data collection

---

## 17. Summary

**Current Status:**
The Untethered app has strong privacy fundamentals (no third-party SDKs, minimal data collection, user-controlled backend) but is **missing critical App Store requirements**.

**Must-Fix Items:**
1. Privacy Manifest (PrivacyInfo.xcprivacy)
2. Privacy Policy URL
3. App Store Connect privacy configuration
4. Required Reason API declarations

**Estimated Time to Compliance:**
- **Minimum:** 1-2 weeks (create documents, update files)
- **Recommended:** 3-4 weeks (add wss://, data deletion, polish)

**Difficulty:** Moderate - mostly documentation and configuration, minimal code changes needed.

---

## 18. Resources

**Apple Documentation:**
- Privacy Manifest Files: https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
- Required Reason API: https://developer.apple.com/documentation/bundleresources/privacy_manifest_files/describing_use_of_required_reason_api
- App Store Privacy Details: https://developer.apple.com/app-store/app-privacy-details/
- App Transport Security: https://developer.apple.com/documentation/security/preventing_insecure_network_connections

**Tools:**
- Privacy Manifest Validator (Xcode)
- App Store Connect > App Privacy section
- plutil (validate plist files)

---

**Report End**
