# Voice-Code iOS Security & Permissions Review

**App Name:** Untethered
**Bundle ID:** dev.910labs.voice-code
**Review Date:** 2025-11-08
**Platform:** iOS 17.0+

---

## Executive Summary

The voice-code iOS app demonstrates a reasonable security posture with proper permission declarations for core features. However, there are **critical security gaps** that must be addressed before App Store submission, particularly around network security and data protection.

**Security Rating:** ⚠️ **NEEDS IMPROVEMENT**

### Critical Issues
1. ❌ **No App Transport Security (ATS) configuration** - Using insecure `ws://` connections
2. ❌ **No data encryption at rest** - CoreData not encrypted
3. ❌ **Missing network usage justifications** - No local network usage description
4. ⚠️ **Empty entitlements file** - May need additional capabilities

### Strengths
1. ✅ Proper microphone and speech recognition permission declarations
2. ✅ User notification authorization properly implemented
3. ✅ No hardcoded secrets or API keys in codebase
4. ✅ CoreData persistence properly configured
5. ✅ Background audio capability correctly configured

---

## 1. Info.plist Permission Usage Descriptions

### ✅ Declared Permissions

#### Microphone Access
```xml
<key>NSMicrophoneUsageDescription</key>
<string>Untethered needs microphone access for voice input to control Claude.</string>
```
**Status:** ✅ COMPLIANT
**Implementation:** `/Users/travisbrown/code/mono/active/voice-code/ios/VoiceCode/Managers/VoiceInputManager.swift`
- Properly requests `AVAudioSession` permissions
- Sets audio session category to `.record`
- Implements proper cleanup on deinit

#### Speech Recognition
```xml
<key>NSSpeechRecognitionUsageDescription</key>
<string>Untethered needs speech recognition to transcribe your voice commands.</string>
```
**Status:** ✅ COMPLIANT
**Implementation:** `/Users/travisbrown/code/mono/active/voice-code/ios/VoiceCode/Managers/VoiceInputManager.swift`
- Uses `SFSpeechRecognizer.requestAuthorization()`
- Properly tracks authorization status
- Handles denied permissions gracefully

#### Background Audio
```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
```
**Status:** ✅ COMPLIANT
**Purpose:** Enables TTS playback when device is locked (user-configurable)
**Implementation:** `/Users/travisbrown/code/mono/active/voice-code/ios/VoiceCode/Managers/VoiceOutputManager.swift`

### ❌ Missing Required Declarations

#### Local Network Usage (REQUIRED)
```xml
<!-- MISSING - MUST ADD -->
<key>NSLocalNetworkUsageDescription</key>
<string>Untethered connects to your local Claude backend server via WebSocket.</string>
```
**Status:** ❌ **CRITICAL - REQUIRED FOR APP STORE**
**Rationale:** App connects to local network servers (default: `ws://localhost:8080`)
**Impact:** App Store rejection if not added

#### Bonjour Services (Recommended)
```xml
<!-- RECOMMENDED IF USING SERVICE DISCOVERY -->
<key>NSBonjourServices</key>
<array>
    <string>_ws._tcp</string>
</array>
```
**Status:** ⚠️ OPTIONAL (only if implementing Bonjour discovery)

---

## 2. Microphone Access Justification

### Authorization Flow

**Code Path:** `VoiceInputManager.swift:28-35`
```swift
func requestAuthorization(completion: @escaping (Bool) -> Void) {
    SFSpeechRecognizer.requestAuthorization { status in
        DispatchQueue.main.async {
            self.authorizationStatus = status
            completion(status == .authorized)
        }
    }
}
```

**Usage:** Voice input for sending prompts to Claude backend

### Security Considerations
✅ Permission requested only when needed (user-initiated)
✅ Authorization status properly tracked (`@Published var authorizationStatus`)
✅ Graceful degradation when permission denied
✅ Audio session properly configured with `.duckOthers` option
✅ Tap removed and audio session deactivated on cleanup

### Recommendation
Add in-app permission primer before requesting microphone access to improve grant rates.

---

## 3. Network Usage Declarations

### Current Configuration

**Default Server:** `ws://localhost:8080`
**Protocol:** WebSocket (unencrypted)
**Storage:** Server URL/port stored in `UserDefaults` (unencrypted)

**Code Path:** `AppSettings.swift:49-53`
```swift
var fullServerURL: String {
    let cleanURL = serverURL.trimmingCharacters(in: .whitespaces)
    let cleanPort = serverPort.trimmingCharacters(in: .whitespaces)
    return "ws://\(cleanURL):\(cleanPort)"  // ❌ Insecure
}
```

### ❌ Critical Security Issues

#### 1. App Transport Security (ATS) Not Configured
**Status:** ❌ **CRITICAL VULNERABILITY**

**Current State:** No ATS configuration in Info.plist
**Impact:**
- iOS blocks all HTTP/WS connections by default (iOS 9+)
- App likely only works in development with ATS disabled
- **App Store will reject without proper justification**

**Required Action:** Add ATS exception with justification

```xml
<!-- REQUIRED - Add to Info.plist -->
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
    <key>NSExceptionDomains</key>
    <dict>
        <key>localhost</key>
        <dict>
            <key>NSExceptionAllowsInsecureHTTPLoads</key>
            <true/>
            <key>NSIncludesSubdomains</key>
            <true/>
        </dict>
    </dict>
</dict>
```

**Alternative (Recommended):** Implement WSS (WebSocket Secure)
- Generate self-signed certificate for local server
- Implement certificate pinning for added security
- Use `wss://` instead of `ws://`

#### 2. No Certificate Validation
**Status:** ⚠️ **SECURITY RISK**

**Code Path:** `VoiceCodeClient.swift:83-92`
```swift
func connect(sessionId: String? = nil) {
    guard let url = URL(string: serverURL) else {
        currentError = "Invalid server URL"
        return
    }
    let request = URLRequest(url: url)
    webSocket = URLSession.shared.webSocketTask(with: request)  // ❌ No certificate pinning
}
```

**Recommendation:** Implement SSL certificate pinning for production

#### 3. Server Credentials Stored Insecurely
**Status:** ⚠️ **SECURITY RISK**

**Code Path:** `AppSettings.swift:10-18`
```swift
@Published var serverURL: String {
    didSet {
        UserDefaults.standard.set(serverURL, forKey: "serverURL")  // ❌ Unencrypted
    }
}
```

**Recommendation:**
- For local-only deployments: Current approach acceptable
- For remote servers: Move to Keychain with `kSecAttrAccessibleWhenUnlocked`

---

## 4. Keychain Usage and Security

### Current Status
**Keychain Usage:** ❌ **NOT IMPLEMENTED**

**Finding:** No Keychain usage detected in codebase
```bash
# Search Results
$ grep -r "Keychain|SecItem|kSecClass" ios/**/*.swift
# No results found
```

### Data Stored in UserDefaults (Unencrypted)
1. Server URL (`serverURL`)
2. Server port (`serverPort`)
3. Voice identifier (`selectedVoiceIdentifier`)
4. App preferences (boolean flags)

### Risk Assessment
**Current Risk:** ✅ **LOW** (no sensitive credentials stored)

**Recommendation:**
- Current approach acceptable for local development server
- If app evolves to support authenticated remote servers, **MUST** implement Keychain storage for:
  - API tokens
  - Session credentials
  - User authentication tokens

---

## 5. Data Encryption Implementation

### Data at Rest

#### CoreData Storage
**Location:** `/Users/travisbrown/code/mono/active/voice-code/ios/VoiceCode/Managers/PersistenceController.swift`

**Status:** ❌ **NOT ENCRYPTED**

**Current Implementation:**
```swift
init(inMemory: Bool = false) {
    container = NSPersistentContainer(name: "VoiceCode")
    // ❌ No encryption configuration
    container.loadPersistentStores { description, error in
        // ...
    }
}
```

**Data Stored:**
- Session metadata (UUIDs, names, directories)
- Full conversation history (user prompts + Claude responses)
- Message timestamps and status

**Recommendation:** Enable CoreData encryption

```swift
// Add to PersistenceController.init()
if let description = container.persistentStoreDescriptions.first {
    description.setOption(
        FileProtectionType.complete as NSObject,
        forKey: NSPersistentStoreFileProtectionKey
    )
}
```

#### UserDefaults Storage
**Status:** ⚠️ **UNENCRYPTED** (acceptable for current data)

**Stored Data:**
- Server configuration (non-sensitive for local development)
- UI preferences
- Voice selection

**iOS Protection:** Data protected by device encryption when locked

### Data in Transit

**Status:** ❌ **UNENCRYPTED**

**Protocol:** WebSocket (`ws://`) - plaintext
**Transmitted Data:**
- User prompts (voice transcriptions)
- Claude responses
- Session IDs
- Working directory paths

**Critical Vulnerability:**
- Network traffic visible to anyone on local network
- Susceptible to man-in-the-middle attacks
- **Not acceptable for production deployment**

**Required Action:** Implement WSS (WebSocket Secure) with TLS 1.3

---

## 6. Secure Communication (HTTPS/WSS)

### Current State

**Protocol:** WebSocket (`ws://`)
**Encryption:** ❌ **NONE**
**Certificate Validation:** ❌ **NONE**

**Evidence:**
```swift
// AppSettings.swift:52
return "ws://\(cleanURL):\(cleanPort)"  // Unencrypted WebSocket

// VoiceCodeClient.swift:91
webSocket = URLSession.shared.webSocketTask(with: request)  // No TLS config
```

### Security Issues

1. **No Transport Layer Security**
   - All messages sent in plaintext
   - Vulnerable to packet sniffing
   - MITM attacks possible

2. **No Server Authentication**
   - Cannot verify backend server identity
   - Susceptible to rogue server attacks

3. **App Store Compliance**
   - ATS requires HTTPS/WSS by default
   - Current implementation requires ATS exception
   - Likely to raise questions during App Review

### Recommendations

#### Option 1: WSS with Self-Signed Certificate (Local Development)
```swift
// 1. Generate self-signed cert on backend
// 2. Bundle certificate in app
// 3. Implement certificate pinning

class SecureWebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Validate certificate against bundled cert
        // ...
    }
}
```

#### Option 2: Tailscale Integration (Recommended)
- Leverage Tailscale's zero-config TLS
- Automatic certificate management
- Network-level encryption
- No code changes needed

---

## 7. Authentication/Authorization Mechanisms

### Current State
**Authentication:** ❌ **NOT IMPLEMENTED**

**Findings:**
- No user authentication system
- No API key validation
- No session token management
- Backend assumed to be trusted local server

**Backend Connection Flow:**
1. App connects to WebSocket server
2. Sends `connect` message with iOS session UUID
3. Backend accepts all connections (no auth)

**Code Path:** `VoiceCodeClient.swift:587-608`
```swift
private func sendConnectMessage() {
    var message: [String: Any] = [
        "type": "connect"
    ]
    if let sessionId = sessionId {
        message["session_id"] = sessionId  // No authentication token
    }
    sendMessage(message)
}
```

### Risk Assessment

**Current Risk:** ✅ **ACCEPTABLE** for local-only deployment

**Threat Model:**
- **Assumption:** Backend runs on user's local machine or trusted network
- **Attack Surface:** Limited to local network access
- **Mitigations:**
  - iOS app sandbox prevents unauthorized access
  - Backend should bind to localhost only
  - User configures server URL manually

### Future Recommendations

If app evolves to support remote/cloud backends:

1. **Implement OAuth 2.0 or API Key Authentication**
   ```swift
   struct AuthenticatedWebSocketClient {
       var apiKey: String  // Store in Keychain

       func connect() {
           var request = URLRequest(url: serverURL)
           request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
           // ...
       }
   }
   ```

2. **Add Session Token Management**
   - Request tokens on authentication
   - Refresh tokens before expiry
   - Revoke tokens on logout

3. **Implement Certificate Pinning**
   - Bundle expected server certificates
   - Validate on each connection

---

## 8. Entitlements Configuration

### Current Configuration

**File:** `/Users/travisbrown/code/mono/active/voice-code/ios/VoiceCode/VoiceCode.entitlements`

**Status:** ❌ **EMPTY**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
</dict>
</plist>
```

### Code Signing Configuration

**Team ID:** REDACTED_TEAM_ID
**Bundle ID:** dev.910labs.voice-code
**Signing Style:** Automatic

**Source:** `project.pbxproj:290-293`

### Required Entitlements

#### Current Needs
None required for current functionality (✅ correct)

#### Future Needs (If Implementing)

**1. Network Extensions (for VPN/Tailscale integration)**
```xml
<key>com.apple.developer.networking.networkextension</key>
<array>
    <string>packet-tunnel-provider</string>
</array>
```

**2. Background Fetch (for message sync)**
```xml
<key>com.apple.developer.background-modes</key>
<array>
    <string>fetch</string>
    <string>processing</string>
</array>
```

**3. Keychain Sharing (if multi-app suite)**
```xml
<key>keychain-access-groups</key>
<array>
    <string>$(AppIdentifierPrefix)dev.910labs.voice-code</string>
</array>
```

### Recommendation
Empty entitlements file is **acceptable** for current functionality. No changes needed unless adding new capabilities.

---

## 9. Additional Security Findings

### Input Validation

#### ✅ Server URL Validation
**Code Path:** `AppSettings.swift:114-130`
- Validates URL format
- Validates port is numeric
- Tests connection before saving

#### ⚠️ Working Directory Validation
**Status:** PARTIAL

**Code Path:** `VoiceCodeClient.swift:528-534`
```swift
func setWorkingDirectory(_ path: String) {
    let message: [String: Any] = [
        "type": "set_directory",
        "path": path  // ❌ No path validation
    ]
    sendMessage(message)
}
```

**Recommendation:** Add path sanitization
```swift
// Validate path is absolute
guard path.hasPrefix("/") else { return }
// Prevent directory traversal
guard !path.contains("..") else { return }
```

### Logging and Privacy

#### ⚠️ Sensitive Data in Logs
**Code Path:** Multiple locations using `Logger` and `print()`

**Examples:**
```swift
// VoiceCodeClient.swift:524
print("📤 [VoiceCodeClient] Full message: \(message)")  // May contain user prompts

// SessionSyncManager.swift:36
logger.info("[\(index + 1)] \(sessionId) | \(messageCount) msgs | \(name) | \(workingDir)")
```

**Recommendation:**
1. Audit all log statements
2. Redact sensitive data (user prompts, file paths)
3. Use `.private` privacy level for sensitive data
```swift
logger.info("Prompt sent: \(promptText, privacy: .private)")
```

### Session Security

#### ✅ Session ID Generation
**Status:** SECURE

**Implementation:**
- Uses `UUID()` for session IDs (cryptographically secure)
- Lowercase normalization prevents case-sensitivity bugs
- No predictable session IDs

#### ✅ Session Isolation
**Status:** SECURE

**Implementation:**
- Each iOS session has unique UUID
- Backend multiplexes sessions correctly
- No cross-session data leakage detected

---

## 10. App Store Readiness Checklist

### Critical Blockers (Must Fix)

- [ ] **Add `NSLocalNetworkUsageDescription` to Info.plist**
- [ ] **Configure App Transport Security exceptions**
- [ ] **Document network usage in App Store submission**
- [ ] **Implement data encryption at rest (CoreData file protection)**
- [ ] **Audit and redact sensitive data from logs**

### High Priority (Should Fix)

- [ ] **Implement WSS (WebSocket Secure) protocol**
- [ ] **Add certificate pinning for server validation**
- [ ] **Add server URL allow/deny list to prevent misconfiguration**
- [ ] **Implement input validation for working directories**
- [ ] **Add privacy manifest (PrivacyInfo.xcprivacy) - iOS 17 requirement**

### Medium Priority (Nice to Have)

- [ ] **Add in-app permission primer for microphone**
- [ ] **Implement biometric authentication for app launch**
- [ ] **Add app-level passcode lock option**
- [ ] **Implement secure log redaction system**
- [ ] **Add analytics privacy controls**

### Documentation for App Review

- [ ] **Explain local network usage in review notes**
- [ ] **Clarify backend server requirements**
- [ ] **Document encryption export compliance (ITSAppUsesNonExemptEncryption = false)**
- [ ] **Provide privacy policy URL**
- [ ] **Document data retention policy**

---

## 11. Compliance Status

### iOS Requirements

| Requirement | Status | Notes |
|------------|--------|-------|
| Privacy manifests | ❌ Missing | Required for iOS 17+ |
| Required reason APIs | ⚠️ Check needed | UserDefaults, file timestamps |
| Encryption export compliance | ✅ Declared | `ITSAppUsesNonExemptEncryption = false` |
| App Transport Security | ❌ Not configured | Critical blocker |
| Data encryption at rest | ❌ Not implemented | Should add |
| Permission descriptions | ✅ Complete | Microphone + Speech |

### Privacy Regulations

**GDPR Considerations:**
- ✅ No personal data sent to third parties
- ✅ Data stored locally on device
- ⚠️ No data deletion mechanism implemented
- ⚠️ No privacy policy provided

**COPPA Considerations:**
- ✅ No account creation
- ✅ No data collection from minors
- ✅ No advertising

---

## 12. Recommended Security Hardening

### Immediate Actions (Before App Store Submission)

1. **Add Network Security Configuration**
   ```xml
   <!-- Info.plist -->
   <key>NSLocalNetworkUsageDescription</key>
   <string>Untethered connects to your local Claude backend server.</string>

   <key>NSAppTransportSecurity</key>
   <dict>
       <key>NSAllowsLocalNetworking</key>
       <true/>
   </dict>
   ```

2. **Enable CoreData File Protection**
   ```swift
   // PersistenceController.swift
   if let storeDescription = container.persistentStoreDescriptions.first {
       storeDescription.setOption(
           FileProtectionType.complete as NSObject,
           forKey: NSPersistentStoreFileProtectionKey
       )
   }
   ```

3. **Create Privacy Manifest (PrivacyInfo.xcprivacy)**
   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
       <key>NSPrivacyAccessedAPITypes</key>
       <array>
           <dict>
               <key>NSPrivacyAccessedAPIType</key>
               <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
               <key>NSPrivacyAccessedAPITypeReasons</key>
               <array>
                   <string>CA92.1</string> <!-- App configuration -->
               </array>
           </dict>
       </array>
       <key>NSPrivacyCollectedDataTypes</key>
       <array>
           <!-- No data collected -->
       </array>
       <key>NSPrivacyTracking</key>
       <false/>
   </dict>
   </plist>
   ```

4. **Implement Log Redaction**
   ```swift
   extension Logger {
       func logPrompt(_ prompt: String) {
           self.info("Prompt sent: \(prompt, privacy: .private)")
       }
   }
   ```

### Long-term Improvements

1. **Migrate to WSS Protocol**
   - Update backend to support TLS
   - Generate self-signed certificate or use Tailscale
   - Update client to use `wss://` URLs
   - Implement certificate pinning

2. **Implement Biometric Authentication**
   ```swift
   import LocalAuthentication

   class BiometricAuthManager {
       func authenticate() async throws {
           let context = LAContext()
           try await context.evaluatePolicy(
               .deviceOwnerAuthenticationWithBiometrics,
               localizedReason: "Unlock Untethered"
           )
       }
   }
   ```

3. **Add Data Deletion Mechanism**
   - Implement "Clear All Data" in settings
   - Add per-session deletion
   - Clear UserDefaults and CoreData
   - Comply with GDPR "Right to Erasure"

4. **Implement Secure Backup/Export**
   - Encrypt exported session data
   - Use user-provided passphrase
   - Implement AES-256 encryption

---

## 13. Conclusion

### Summary of Findings

**Strengths:**
- Proper permission declarations for core features
- No hardcoded secrets or credentials
- Good use of iOS system APIs (Speech, AVFoundation)
- Appropriate data isolation between sessions

**Critical Vulnerabilities:**
- Unencrypted network communication (WebSocket)
- No App Transport Security configuration
- Missing local network usage description
- No data encryption at rest

**Security Posture:** ⚠️ **ACCEPTABLE for local development, INADEQUATE for production/App Store**

### Go/No-Go Decision

**App Store Submission:** ❌ **NOT READY**

**Blockers:**
1. Missing `NSLocalNetworkUsageDescription`
2. Missing ATS configuration
3. Missing Privacy Manifest (iOS 17+)

**Estimated Effort to Fix Blockers:** 4-8 hours

### Recommended Path Forward

**Phase 1: App Store Readiness (1-2 days)**
1. Add required Info.plist keys
2. Create privacy manifest
3. Enable CoreData file protection
4. Audit and redact logs
5. Submit for App Review

**Phase 2: Security Hardening (1-2 weeks)**
1. Implement WSS protocol
2. Add certificate pinning
3. Implement biometric authentication
4. Add data deletion mechanism
5. Create privacy policy

**Phase 3: Enterprise Readiness (1 month+)**
1. Implement OAuth authentication
2. Add end-to-end encryption option
3. Implement MDM support
4. Add audit logging
5. Security penetration testing

---

## Appendix A: File Inventory

### Security-Relevant Files

| File | Purpose | Security Notes |
|------|---------|----------------|
| `Info.plist` | App permissions | Missing network description |
| `VoiceCode.entitlements` | App capabilities | Empty (acceptable) |
| `AppSettings.swift` | Configuration storage | UserDefaults (unencrypted) |
| `VoiceCodeClient.swift` | Network communication | Unencrypted WebSocket |
| `VoiceInputManager.swift` | Microphone access | Proper authorization |
| `NotificationManager.swift` | User notifications | Proper authorization |
| `PersistenceController.swift` | CoreData storage | No encryption |
| `SessionSyncManager.swift` | Session management | Secure UUIDs |

### Dependencies

No external dependencies detected (pure Swift/iOS SDK)

---

## Appendix B: Threat Model

### Assets
1. User voice input (transcribed prompts)
2. Claude responses
3. Session conversation history
4. Working directory paths
5. Backend server configuration

### Threats

| Threat | Likelihood | Impact | Mitigation Status |
|--------|-----------|--------|-------------------|
| Local network eavesdropping | Medium | High | ❌ Not mitigated |
| MITM attack | Medium | High | ❌ Not mitigated |
| Device theft (unlocked) | Medium | Medium | ⚠️ Partial (iOS sandbox) |
| Device theft (locked) | Low | Low | ✅ Mitigated (device encryption) |
| Malicious local server | Low | High | ❌ Not mitigated |
| CoreData file access | Low | Medium | ⚠️ Partial (file protection needed) |
| Log data leakage | Medium | Low | ⚠️ Partial (needs redaction) |

### Recommended Mitigations
1. **High Priority:** Implement WSS with certificate pinning
2. **High Priority:** Enable CoreData file protection
3. **Medium Priority:** Implement certificate pinning
4. **Medium Priority:** Add log redaction for sensitive data
5. **Low Priority:** Biometric authentication for app launch

---

**Report Generated:** 2025-11-08
**Reviewer:** Claude Code Analysis
**Next Review:** Before App Store submission

