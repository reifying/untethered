# Backend Services - App Store Compliance Review

**Status**: CRITICAL GAPS IDENTIFIED - Self-Hosted Architecture Not App Store Ready
**Date**: 2025-11-08
**App**: Untethered (voice-code)
**Team**: 910 Labs, LLC

---

## Executive Summary

The voice-code app (marketed as "Untethered") currently requires users to **run their own backend server** on their local network or VPN. This architecture presents significant App Store compliance challenges and will likely face rejection during review. The app is fundamentally dependent on infrastructure that Apple reviewers cannot access or evaluate.

**Critical Finding**: The app is **non-functional without a user-operated backend server**, which violates Apple's requirement that apps must be demonstrable and functional during review.

---

## 1. Server Infrastructure Requirements

### Current Architecture

**Backend Type**: Self-hosted Clojure WebSocket server
**Deployment Model**: User-operated (personal laptop/server)
**Access Method**: Local network or remote access
**Server Management**: User responsibility

### Implementation Details

```
Architecture:
iPhone App (Swift)
  ↓ WebSocket (ws://{user-configured-ip}:8080)
Clojure Backend (User's Machine)
  ↓ Filesystem Watcher (~/.claude/projects/)
Claude Code CLI (User's Machine)
```

**Backend Requirements (User-side)**:
- Java 11+ runtime
- Clojure CLI tools
- Claude Code CLI installed (`~/.claude/local/claude`)
- Network accessibility (local network or remote access setup)
- Manual server startup: `clojure -M -m voice-code.server`

**Configuration Files**:
- `/Users/travisbrown/code/mono/active/voice-code/backend/src/voice_code/server.clj` - Main server
- `/Users/travisbrown/code/mono/active/voice-code/backend/resources/config.edn` - Server config
- `/Users/travisbrown/code/mono/active/voice-code/ios/VoiceCode/Managers/AppSettings.swift` - iOS client config

**Server Settings (iOS App)**:
- Server address: User-configurable (local IP or localhost)
- Port: Configurable (default 8080)
- Connection test available in Settings UI
- No cloud-hosted alternative provided

### App Store Compliance Issues

**🚨 CRITICAL ISSUES**:

1. **Non-Demonstrable During Review**
   - Apple reviewers cannot access user-hosted backends
   - App will crash or show "connection failed" errors
   - No demo/test server provided for review purposes

2. **Violates Guideline 2.1 - App Completeness**
   - App requires external setup not controlled by developer
   - Cannot be fully evaluated by review team
   - Core functionality dependent on unavailable infrastructure

3. **Poor User Experience**
   - Requires technical knowledge (Clojure, networking)
   - Complex setup process (install backend, configure network, start server)
   - No out-of-box functionality

4. **Guideline 4.2.7 Violation Risk**
   - "Apps that download code" concern (connects to arbitrary servers)
   - Dynamic server configuration could be flagged
   - No server validation or security controls

**Code Evidence**:
```swift
// From SettingsView.swift - User configures arbitrary servers
TextField("Server Address", text: $settings.serverURL)
TextField("Port", text: $settings.serverPort)

// Help text reveals infrastructure expectations
Text("1. Start the backend server on your computer")
Text("2. Find your server's IP address")
```

### Recommendations

**REQUIRED CHANGES** (Choose one):

**Option A: Hosted Backend Service** (Recommended for App Store)
- Deploy centralized backend service on cloud provider (AWS, GCP, Heroku)
- Provide managed infrastructure accessible to all users
- Apple reviewers can test against production service
- Add authentication (API keys, OAuth)
- Estimated effort: 2-3 weeks

**Option B: Local-Only Mode** (Alternative)
- Redesign as localhost-only app (127.0.0.1)
- Bundle backend as embedded service (may violate App Store rules)
- Document as developer tool requiring Claude CLI pre-installed
- Likely still faces rejection without hosted option
- Estimated effort: 1-2 weeks

**Option C: Hybrid Approach** (Best UX)
- Provide hosted backend for general users (App Store compliance)
- Support advanced mode for self-hosting (power users)
- Default to hosted service, optional self-host configuration
- Estimated effort: 3-4 weeks

---

## 2. API Availability and Reliability

### Current Implementation

**API Type**: Custom WebSocket protocol (documented in STANDARDS.md)
**Protocol Version**: 0.2.0
**Uptime Guarantees**: None (user-operated)
**Health Monitoring**: None (connection test only)

**WebSocket Messages** (27 message types):
- Connection: `hello`, `connect`, `connected`, `ping`, `pong`
- Sessions: `session_list`, `session_history`, `session_updated`, `session_created`
- Prompts: `prompt`, `ack`, `response`, `turn_complete`, `session_locked`
- Commands: `execute_command`, `command_started`, `command_output`, `command_complete`
- Data: `recent_sessions`, `command_history`, `get_command_output`

**Connection Management**:
- Automatic reconnection with exponential backoff (1s → 60s max)
- Subscription restoration after reconnect
- Message delivery queue with acknowledgments
- Lock state cleared on disconnect

**Code Reference**: `/Users/travisbrown/code/mono/active/voice-code/ios/VoiceCode/Managers/VoiceCodeClient.swift`

### Availability Issues

**🚨 PROBLEMS**:

1. **Zero Availability Guarantee**
   - Backend runs on user's laptop (not always-on)
   - Server stops when laptop sleeps or shuts down
   - No redundancy or failover

2. **Network Dependency**
   - Requires stable local network or remote access setup
   - Mobile data usage not accounted for
   - No offline mode

3. **No Service Monitoring**
   - No uptime tracking
   - No error reporting/analytics
   - Users troubleshoot independently

### Reliability Concerns

**Failure Scenarios** (Not Handled):
- User's laptop battery dies → Service down
- Network connection drops → App unusable
- User forgets to start server → Silent failure
- Network change (Wi-Fi → Cellular) → Connection lost
- macOS sleep/wake → Server process killed

**Current Handling**:
```swift
// From VoiceCodeClient.swift - Only handles reconnection, not service availability
private func setupReconnection() {
    // Exponential backoff: 1s, 2s, 4s, 8s, 16s, 32s, 60s (max)
    let delay = min(pow(2.0, Double(reconnectionAttempts)), maxReconnectionDelay)
    // Will retry forever, even if server is permanently down
}
```

### App Store Compliance

**Guideline 2.1 - App Completeness**:
- ❌ App fails gracefully but provides no value when backend is unavailable
- ❌ No error messaging explaining "start your backend server"
- ❌ Review team cannot make backend available

### Recommendations

**REQUIRED**:

1. **Deploy Managed Backend**
   - 99.9% uptime SLA minimum
   - Load balancer with health checks
   - Auto-scaling for concurrent users
   - Geographic distribution (latency optimization)

2. **Monitoring & Alerting**
   - Uptime monitoring (Pingdom, StatusPage)
   - Error tracking (Sentry, Datadog)
   - Performance metrics (response times, message queue depth)
   - Public status page

3. **Graceful Degradation**
   - Offline mode for viewing cached sessions
   - Clear error messages with actionable steps
   - Retry logic with user feedback

4. **Connection Quality**
   - Bandwidth usage monitoring
   - Cellular vs Wi-Fi detection
   - Quality-of-service warnings

---

## 3. Service Downtime Handling

### Current Behavior

**Connection Loss Handling**:
```swift
// Automatic reconnection only - no user feedback beyond connection status
case .failure(let error):
    self.isConnected = false
    self.currentError = error.localizedDescription
    self.lockedSessions.removeAll()
```

**Lifecycle Management**:
- App reconnects when returning to foreground
- WebSocket disconnect triggers cleanup
- Session locks cleared (prevents stuck state)
- No data loss (CoreData persists locally)

**User Experience**:
- Connection status indicator (isConnected boolean)
- Generic error messages
- No distinction between "backend down" vs "network issue"

### App Store Issues

**🚨 PROBLEMS**:

1. **No Downtime Communication**
   - Users don't know if issue is temporary or permanent
   - No estimated recovery time
   - No fallback instructions

2. **Service Expectations**
   - App sets expectation of always-on service
   - Cannot deliver without hosted infrastructure
   - Review team expects continuous availability

3. **Data Synchronization**
   - Local changes (new sessions) can't sync when backend down
   - No conflict resolution if backend state diverges
   - Message delivery queue may grow indefinitely

### Recommendations

**REQUIRED**:

1. **Service Status Integration**
   - Status page API integration
   - Planned maintenance notifications
   - Incident reporting to users

2. **Offline Mode**
   - Read-only access to cached sessions
   - Queue prompts for later delivery
   - Conflict resolution on reconnection

3. **User Communication**
   - Distinguish error types (network vs server vs configuration)
   - Provide actionable guidance
   - Link to support resources

4. **Data Resilience**
   - Local-first architecture (already partially implemented with CoreData)
   - Eventual consistency guarantees
   - Background sync when connection restored

---

## 4. Backend Privacy Compliance

### Current Data Flow

**Data Collected by Backend**:
1. **Session Data** (stored in `~/.claude/.session-index.edn`):
   - iOS session UUID (lowercase)
   - Claude session ID (UUID)
   - Working directory paths
   - Last modified timestamps
   - Message counts

2. **Conversation History** (stored in `~/.claude/projects/**/*.jsonl`):
   - User prompts (text)
   - Claude responses (text)
   - Token usage statistics
   - API costs
   - Timestamps

3. **Command Execution History** (stored in `~/.voice-code/command-history/`):
   - Command IDs and shell commands executed
   - Working directories
   - Exit codes and duration
   - stdout/stderr output (up to 7 days)
   - Execution timestamps

4. **WebSocket Metadata**:
   - Client IP addresses (ephemeral, not persisted)
   - Connection timestamps (logs only)
   - Session subscription state (in-memory only)

**Data Storage Locations**:
```
~/.claude/projects/          # Claude CLI managed (conversation JSONL files)
~/.claude/.session-index.edn # Backend session index
~/.voice-code/command-history/ # Command execution logs
```

**Privacy Controls**: NONE
- No encryption at rest
- No encryption in transit (WebSocket without TLS)
- No access controls
- No user consent mechanisms
- No data export/deletion APIs

### Privacy Policy Requirements

**🚨 CRITICAL GAPS**:

Apple App Privacy Requirements (Guideline 5.1.1):

1. **Missing Privacy Policy**
   - ❌ No privacy policy document exists
   - ❌ No privacy policy URL in App Store Connect
   - ❌ Required for all apps that collect data

2. **Data Collection Disclosure**
   - ❌ App collects conversation data (linked to user)
   - ❌ Must disclose in App Privacy section
   - ❌ Must explain purpose and usage

3. **Third-Party Sharing**
   - ⚠️ Data sent to Claude API (Anthropic)
   - ❌ Must disclose third-party data sharing
   - ❌ Must link to Claude's privacy policy

4. **User Rights**
   - ❌ No data access request mechanism
   - ❌ No data deletion capability
   - ❌ No opt-out for analytics/tracking

5. **GDPR/CCPA Compliance** (if applicable):
   - ❌ No consent mechanism
   - ❌ No right-to-be-forgotten implementation
   - ❌ No data portability

### Data Categories (Per Apple's Requirements)

**Must Disclose**:
- ✅ Contact Info: None collected
- ⚠️ User Content: Conversation transcripts, voice input
- ❌ Usage Data: Not explicitly collected (should track for analytics)
- ❌ Identifiers: Session UUIDs (linked to user)
- ❌ Diagnostics: None collected (should implement)

### Encryption Status

**Current State**:
- WebSocket: `ws://` (unencrypted) ❌
- File storage: Plain text JSONL/EDN ❌
- Voice data: Transcribed by iOS (encrypted in transit to Apple) ✅

**Required Changes**:
- Use `wss://` (WebSocket Secure) with TLS certificate
- Implement at-rest encryption for sensitive files
- Document encryption in privacy policy

### Recommendations

**REQUIRED IMMEDIATELY**:

1. **Create Privacy Policy** (Legal review recommended)
   - Document what data is collected
   - Explain how data is used
   - Disclose third-party sharing (Claude API)
   - Detail retention periods
   - Explain user rights
   - Host at permanent URL (required for App Store submission)

2. **Update App Privacy Questionnaire** (App Store Connect)
   - User Content: "Conversation transcripts used to interact with Claude AI"
   - Purpose: "App Functionality"
   - Linked to User: Yes (via session IDs)
   - Third Parties: Anthropic (Claude API)

3. **Implement Privacy Controls**
   ```swift
   // Add to Settings
   - View Privacy Policy (link)
   - Request Data Export (generate JSONL archive)
   - Delete All Data (confirm + backend API call)
   - Analytics Opt-Out (future)
   ```

4. **Security Hardening**
   - Enable TLS for WebSocket (wss://)
   - Add server certificate validation
   - Implement session-level encryption for sensitive data
   - Add authentication layer (API keys, OAuth)

5. **Compliance Documentation**
   - Privacy policy (public URL)
   - Data retention policy (internal)
   - Incident response plan (internal)
   - User data request procedures (support docs)

**Sample Privacy Policy Outline**:
```
Untethered Privacy Policy

1. Introduction
   - Who we are (910 Labs, LLC)
   - Contact information

2. Data We Collect
   - Voice input (transcribed locally by iOS)
   - Conversation history (prompts and responses)
   - Session metadata (UUIDs, timestamps)
   - Command execution logs

3. How We Use Data
   - Provide voice interaction with Claude AI
   - Sync conversations across devices
   - Execute development commands

4. Data Sharing
   - Anthropic (Claude API) - receives prompts for AI responses
   - Link to Anthropic's privacy policy

5. Data Storage
   - Location: User's local machine (self-hosted) OR Cloud service (if hosted)
   - Retention: 7 days (command history), indefinite (conversations)
   - Encryption: TLS in transit, [specify at-rest encryption]

6. User Rights
   - Access your data
   - Delete your data
   - Opt-out of future features (analytics)

7. Children's Privacy
   - App not directed at children under 13

8. Changes to Policy
   - Notify users of material changes

9. Contact
   - Email: privacy@910labs.dev
```

---

## 5. Data Retention Policies

### Current Retention Behavior

**Conversation History** (`~/.claude/projects/`):
- **Retention**: Indefinite
- **Size Management**: Manual compaction via `claude compact` command
- **Deletion**: Manual file deletion by user
- **Backup**: None (local files only)

**Session Index** (`~/.claude/.session-index.edn`):
- **Retention**: Indefinite (grows unbounded)
- **Cleanup**: None (no automatic pruning)
- **Corruption Handling**: Returns empty map on error

**Command History** (`~/.voice-code/command-history/`):
- **Retention**: 7 days (implemented)
- **Cleanup**: Automatic on backend startup
- **Storage**: `index.edn` + per-command `.log` files

**Code Reference**:
```clojure
; From commands_history.clj
(def ^:private default-retention-days 7)

(defn cleanup-expired-sessions!
  "Remove sessions older than retention period.
  Deletes both index entries and log files."
  [& {:keys [retention-days] :or {retention-days default-retention-days}}]
  ; ... implementation
)
```

### Data Growth Issues

**Unbounded Growth**:
1. **Session Index**: Grows with every Claude session (no limit)
2. **JSONL Files**: Conversation history accumulates (can reach 100MB+ per session)
3. **No Storage Quotas**: Users can exhaust disk space
4. **No Archival Strategy**: Old sessions persist indefinitely

**User Impact**:
- Performance degradation (large index files)
- Disk space exhaustion
- Slow session list loading (700+ sessions reported in tests)

### App Store Requirements

**Guideline 5.1.1 - Data Collection and Storage**:
- ✅ Command history has defined retention (7 days)
- ❌ Conversation history has no retention policy
- ❌ No user control over retention periods
- ❌ No storage limit warnings

### Recommendations

**REQUIRED**:

1. **Define Retention Policy** (Document publicly)
   ```
   Data Type              Retention    Rationale
   -------------          ---------    ---------
   Conversation History   90 days*     Balance utility vs storage
   Session Metadata       Indefinite   Lightweight, used for browsing
   Command Logs           7 days       Debugging only, minimal value
   Voice Transcripts      Not stored   Processed and discarded immediately

   *User-configurable: 30/60/90/180/365 days or "Keep All"
   ```

2. **Implement Retention Controls**
   ```swift
   // Add to Settings
   Picker("Conversation Retention", selection: $settings.retentionDays) {
       Text("30 days").tag(30)
       Text("60 days").tag(60)
       Text("90 days").tag(90)
       Text("180 days").tag(180)
       Text("1 year").tag(365)
       Text("Keep all").tag(-1) // Never delete
   }
   ```

3. **Automatic Cleanup** (Backend)
   ```clojure
   ; Run daily at startup + scheduled task
   (defn cleanup-old-sessions! [retention-days]
     "Archive or delete session files older than retention period"
     ; 1. Find expired sessions
     ; 2. Optionally export to archive (ZIP)
     ; 3. Delete from active storage
     ; 4. Update index
   )
   ```

4. **Storage Monitoring**
   ```swift
   // Warn user when approaching limits
   func checkStorageUsage() {
       let sessionSize = calculateSessionStorageSize()
       if sessionSize > 500_000_000 { // 500 MB
           showAlert("Your conversations are using 500 MB. Consider archiving old sessions.")
       }
   }
   ```

5. **Export/Archive Feature**
   ```swift
   // Allow users to download conversation archives
   Button("Export Conversations") {
       // Generate ZIP of JSONL files
       // Offer share sheet (email, Files app, etc.)
   }
   ```

6. **Privacy Policy Update**
   - Document retention periods
   - Explain automatic cleanup
   - Detail user export options

---

## 6. User Data Deletion Capability

### Current Deletion Mechanisms

**iOS App (Local Data)**:
```swift
// From SessionSyncManager.swift - Deletes CoreData only, not backend files
func deleteSession(_ session: CDSession, context: NSManagedObjectContext) {
    context.delete(session)
    try? context.save()
}
```

**Backend (File System)**:
- ❌ No deletion API endpoint
- ❌ Manual file deletion only (user SSH access)
- ✅ Command history auto-deletes after 7 days

**Session Deletion Scope**:
- iOS local: ✅ Deletes CoreData session and messages
- Backend index: ❌ Session remains in `~/.claude/.session-index.edn`
- JSONL files: ❌ Conversation files persist on disk
- Command logs: ✅ Auto-deleted after 7 days

### Compliance Issues

**🚨 CRITICAL GAPS**:

**Apple Guidelines (5.1.1 - Privacy)**:
- ❌ Users cannot delete their data from backend
- ❌ No "Delete Account" or "Delete All Data" option
- ❌ No confirmation that data was deleted
- ❌ No timeline for deletion (should be immediate or within 30 days)

**GDPR Article 17 - Right to Erasure** (if applicable):
- ❌ No erasure request mechanism
- ❌ No deletion confirmation to user
- ❌ No third-party deletion (Claude API retains data per their policy)

**CCPA - Right to Delete** (if applicable):
- ❌ No verifiable deletion request process
- ❌ No disclosure of what can/cannot be deleted

### Current Deletion Flow (Incomplete)

```
User Deletes Session in iOS App
    ↓
CoreData session deleted ✅
    ↓
"session-deleted" message sent to backend
    ↓
Backend marks as deleted for client (in-memory only) ⚠️
    ↓
Backend unsubscribes from session ✅
    ↓
JSONL file persists on disk ❌
Index entry persists ❌
```

**Code Evidence**:
```clojure
; From server.clj - Only marks session as deleted for client, doesn't delete files
"session-deleted"
(let [session-id (:session-id data)]
  (when session-id
    (log/info "Client deleted session locally" {:session-id session-id})
    (mark-session-deleted-for-client! channel session-id)
    (repl/unsubscribe-from-session! session-id)))
```

### Recommendations

**REQUIRED**:

1. **Implement Backend Deletion API**
   ```clojure
   ; Add to server.clj
   "delete_session"
   (let [session-id (:session-id data)]
     ; 1. Remove from session-index.edn
     ; 2. Delete JSONL file from ~/.claude/projects/
     ; 3. Optionally create deletion tombstone
     ; 4. Send confirmation to client
   )
   ```

2. **Add iOS Deletion Confirmation**
   ```swift
   func deleteSession(_ session: CDSession, deleteFromBackend: Bool = true) {
       // 1. Delete from CoreData
       context.delete(session)

       // 2. Request backend deletion
       if deleteFromBackend {
           client.deleteSession(sessionId: session.backendSessionId) { success in
               if success {
                   showToast("Session permanently deleted")
               } else {
                   showAlert("Failed to delete from server. Data may remain on backend.")
               }
           }
       }
   }
   ```

3. **Add "Delete All Data" Option**
   ```swift
   // In Settings
   Section(header: Text("Data Management")) {
       Button("Delete All Conversations", role: .destructive) {
           showDeleteConfirmation()
       }
       .foregroundColor(.red)
   }

   func showDeleteConfirmation() {
       Alert(
           title: "Delete All Data",
           message: "This will permanently delete all conversations from this device and the backend. This cannot be undone.",
           primaryButton: .destructive(Text("Delete Everything")) {
               deleteAllData()
           },
           secondaryButton: .cancel()
       )
   }
   ```

4. **Deletion Confirmation**
   ```swift
   func deleteAllData() async {
       // 1. Delete local CoreData
       let allSessions = fetchAllSessions()
       for session in allSessions {
           context.delete(session)
       }
       try? context.save()

       // 2. Request backend deletion
       let response = await client.deleteAllSessions()

       // 3. Confirm to user
       if response.success {
           showToast("All data deleted successfully")
       } else {
           showAlert("Deleted from device. Backend deletion status: \(response.message)")
       }
   }
   ```

5. **Audit Trail** (For compliance)
   ```clojure
   ; Log deletions for audit purposes (not user-accessible)
   (defn log-deletion! [session-id user-requested?]
     (log/info "Session deleted"
               {:session-id session-id
                :timestamp (Instant/now)
                :user-requested user-requested?
                :retention "none"}))
   ```

6. **Privacy Policy Update**
   ```
   ## Data Deletion

   You can delete your data at any time:

   - **Individual Sessions**: Swipe to delete in the session list
   - **All Data**: Use "Delete All Conversations" in Settings

   Deleted data is removed from:
   - Your iOS device (immediately)
   - Backend storage (within 24 hours)

   Note: Data sent to Claude AI (Anthropic) is subject to their
   retention policy. We cannot delete data from third-party services.
   ```

7. **Third-Party Deletion Disclosure**
   - Clarify that Claude API data is governed by Anthropic's policy
   - Link to Anthropic's data deletion process (if available)
   - Disclose retention limitations

---

## 7. Service Terms and SLA

### Current Status

**Terms of Service**: ❌ None exist
**Privacy Policy**: ❌ None exist
**SLA Documentation**: ❌ None exist
**Support Channels**: ❌ None documented

**App Store Requirements**:
- Guideline 5.1.1: Privacy policy required for all apps
- Guideline 5.1.2: Terms of service recommended for service-based apps
- Metadata Rejection: Missing required legal documents

### Self-Hosted Service Implications

**Current Model**:
- Users operate their own backend
- No centralized service provided by developer
- No SLA possible (developer doesn't control uptime)

**Legal Implications**:
1. **Limited Liability**: Developer not responsible for user's backend
2. **No Service Guarantees**: Cannot promise uptime/performance
3. **Support Scope**: Limited to app functionality, not infrastructure

### App Store Expectations

**What Apple Expects**:
1. Privacy policy (required)
2. Terms of service (strongly recommended)
3. Support URL (required in App Store Connect)
4. SLA disclosure (if offering hosted service)

**Current Gaps**:
- ❌ No legal agreements
- ❌ No support documentation
- ❌ No liability disclaimers
- ❌ No user responsibilities outlined

### Recommendations

**REQUIRED FOR SUBMISSION**:

1. **Privacy Policy** (Detailed in Section 4)
   - Must be publicly accessible URL
   - Cannot be "coming soon" or placeholder
   - Must accurately describe data practices

2. **Terms of Service** (Create Document)
   ```
   Untethered Terms of Service

   1. Acceptance of Terms
      By using Untethered, you agree to these terms.

   2. Service Description
      - Voice interface for Claude Code CLI
      - Requires self-hosted backend OR hosted service
      - Third-party services (Anthropic Claude API)

   3. User Responsibilities
      - Self-hosted users: Operate backend, maintain security
      - Hosted users: Comply with usage limits
      - All users: Provide valid Claude API credentials

   4. Service Availability
      - Self-hosted: No uptime guarantees (user-managed)
      - Hosted: 99.9% uptime SLA (if offering hosted service)

   5. Data & Privacy
      - See Privacy Policy for details
      - User responsible for data in self-hosted mode

   6. Prohibited Uses
      - No illegal content
      - No abuse of Claude API
      - No reverse engineering

   7. Liability Limitations
      - Provided "as is" without warranties
      - Not liable for data loss (user backups recommended)
      - Not liable for Claude API costs

   8. Termination
      - User can delete account/data at any time
      - Developer reserves right to suspend service (if hosted)

   9. Changes to Terms
      - Notify users 30 days before material changes

   10. Contact
       - Email: legal@910labs.dev
   ```

3. **Service Level Agreement** (If Offering Hosted Service)
   ```
   Untethered SLA (Hosted Service Only)

   Uptime Commitment: 99.9% (approximately 43 minutes downtime/month)

   Support Response Times:
   - Critical (service down): 1 hour
   - High (major feature broken): 4 hours
   - Medium (minor issue): 24 hours
   - Low (general question): 48 hours

   Planned Maintenance:
   - Scheduled during low-traffic hours (2-4 AM PST)
   - Announced 48 hours in advance
   - Maximum 2 hours per maintenance window

   Performance Targets:
   - WebSocket connection: <500ms latency (95th percentile)
   - Message delivery: <1 second (90th percentile)
   - Session loading: <2 seconds for 100 messages

   Service Credits:
   - <99.9% uptime: 10% monthly credit
   - <99.0% uptime: 25% monthly credit
   - <95.0% uptime: 100% monthly credit

   Exclusions:
   - User's network connectivity
   - Claude API availability (Anthropic-controlled)
   - Force majeure events
   ```

4. **Support Documentation**
   ```
   Create support.md with:
   - Getting Started guide
   - Troubleshooting common issues
   - Contact information (email: support@910labs.dev)
   - Known limitations
   - FAQ

   Host at: https://910labs.dev/untethered/support
   Link from App Store Connect "Support URL" field
   ```

5. **Disclaimers** (Add to App Store Description)
   ```
   REQUIREMENTS:
   - Self-hosted backend (setup guide included) OR subscription to hosted service
   - Valid Claude API credentials (paid separately via Anthropic)
   - Local network or remote access (self-hosted mode)

   DISCLAIMERS:
   - Not affiliated with Anthropic (Claude AI provider)
   - API usage costs billed by Anthropic directly to user
   - Self-hosted mode requires technical setup
   ```

6. **Implementation Steps**
   - Write privacy policy (legal review recommended)
   - Write terms of service (legal review recommended)
   - Host documents at permanent URLs (e.g., 910labs.dev/untethered/)
   - Update App Store Connect metadata:
     - Privacy Policy URL
     - Terms of Service URL
     - Support URL
   - Add in-app links:
     - Settings → Legal → Privacy Policy
     - Settings → Legal → Terms of Service
     - Help → Support

**Timeline**: 1-2 weeks (including legal review)

---

## 8. Subscription/Payment Integration

### Current Status

**Monetization Model**: ❌ None implemented
**Payment Processing**: ❌ Not applicable (no paid features)
**Subscription Status**: ❌ Not implemented

**Current App Characteristics**:
- Free app (no in-app purchases)
- No subscription requirement
- No feature gating
- No payment collection

### Third-Party Costs (User's Responsibility)

**Claude API Costs** (Anthropic):
- User provides own API credentials
- Billed directly by Anthropic
- Developer receives no revenue
- Not managed through Apple ecosystem

**Code Evidence**:
```
// No payment code exists in codebase
// No StoreKit integration
// No subscription validation
// No receipt verification
```

### App Store Compliance

**Guideline 3.1.1 - In-App Purchase**:
- ✅ No digital goods sold (compliant)
- ✅ No subscription required (compliant)
- ✅ API credentials = user's external account (compliant)

**Guideline 3.1.3(b) - Multiplatform Services**:
- ⚠️ If offering hosted backend as subscription:
  - Must use Apple In-App Purchase
  - Cannot direct users to external payment
  - 15-30% commission to Apple

### Future Monetization Considerations

**If Adding Hosted Backend Subscription**:

1. **Apple In-App Purchase Required**
   ```swift
   // Must implement StoreKit
   import StoreKit

   // Product IDs
   let monthlySubscription = "dev.910labs.untethered.monthly"
   let yearlySubscription = "dev.910labs.untethered.yearly"

   // Pricing examples
   Monthly: $9.99 (after Apple's 30% cut: $6.99 to developer)
   Yearly: $99.99 (after Apple's 15% cut for year 2+: $84.99 to developer)
   ```

2. **Subscription Management**
   - Settings → Manage Subscription (link to Apple subscription settings)
   - Display subscription status in app
   - Validate receipts on backend
   - Handle subscription expiration gracefully

3. **Free Tier Considerations**
   - Offer limited free usage (e.g., 100 messages/month)
   - Require subscription for unlimited access
   - OR keep self-hosted option free, hosted option paid

4. **Revenue Split**
   - Apple: 30% year 1, 15% year 2+ (for auto-renewing subscriptions)
   - Developer: 70% year 1, 85% year 2+
   - Claude API costs: Developer's expense (must price accordingly)

### Recommendations

**CURRENT STATE** (No Action Required):
- ✅ App is compliant as free app with user-provided API credentials
- ✅ No payment integration needed for self-hosted model

**IF ADDING HOSTED SERVICE** (Future):

1. **Implement StoreKit**
   - Add subscription products in App Store Connect
   - Integrate StoreKit 2 (modern API)
   - Validate receipts on backend
   - Handle subscription lifecycle (trial, active, expired, canceled)

2. **Pricing Strategy**
   ```
   Free Tier:
   - Self-hosted backend (forever free)
   - Bring your own Claude API credentials

   Hosted Pro (Subscription):
   - $14.99/month or $149.99/year
   - Managed backend service
   - 99.9% uptime SLA
   - Priority support
   - Includes $10/month Claude API credits
   ```

3. **Compliance**
   - Use Apple In-App Purchase (required)
   - Cannot mention pricing outside app (rejection risk)
   - Cannot link to web signup (rejection risk)
   - Must offer subscription management via Apple

4. **Implementation Effort**
   - StoreKit integration: 1 week
   - Backend receipt validation: 1 week
   - Subscription management UI: 3 days
   - Testing: 1 week
   - **Total**: ~3-4 weeks

**Decision Point**: Determine monetization strategy before App Store submission
- Self-hosted only (free): No changes needed ✅
- Hosted service (paid): Implement subscriptions (3-4 weeks effort)

---

## 9. Overall Compliance Summary

### Critical Blockers for App Store Submission

**🚨 WILL CAUSE REJECTION**:

1. **Non-Functional for Review Team** (Guideline 2.1)
   - App requires user-hosted backend
   - Apple reviewers cannot access backend
   - App will crash/error during review
   - **Impact**: Immediate rejection
   - **Fix Required**: Deploy hosted backend OR provide demo credentials

2. **Missing Privacy Policy** (Guideline 5.1.1)
   - No privacy policy URL
   - No data collection disclosure
   - **Impact**: Automatic rejection
   - **Fix Required**: Create and host privacy policy (1 week)

3. **Unencrypted WebSocket** (Guideline 2.5.3 - Software Requirements)
   - Using `ws://` instead of `wss://`
   - Sensitive data transmitted in plain text
   - **Impact**: Security rejection risk
   - **Fix Required**: Implement TLS (3 days)

### High-Priority Issues

**⚠️ LIKELY TO CAUSE PROBLEMS**:

1. **No User Data Deletion** (Guideline 5.1.1)
   - Backend files persist after iOS deletion
   - No "Delete All Data" option
   - **Fix Required**: Implement deletion API (1 week)

2. **Unbounded Data Retention** (Guideline 5.1.1)
   - Conversation history never expires
   - No storage limit warnings
   - **Fix Required**: Define retention policy + cleanup (1 week)

3. **No Terms of Service**
   - No user agreement
   - No liability disclaimers
   - **Fix Required**: Legal document + hosting (1 week with legal review)

### Medium-Priority Issues

**⚠️ MAY CAUSE DELAYS OR QUESTIONS**:

1. **Complex Setup Process**
   - Requires Clojure/Java installation
   - Network configuration
   - **Fix**: Provide hosted option + improved documentation

2. **No Service Monitoring**
   - No uptime tracking
   - No error reporting
   - **Fix**: Add monitoring when offering hosted service

3. **No Offline Mode**
   - App useless when backend unavailable
   - **Fix**: Cache sessions for read-only access

### Compliance Matrix

| Requirement | Status | Evidence | Recommendation |
|-------------|--------|----------|----------------|
| **Functional during review** | ❌ Fail | Requires user backend | Deploy hosted backend |
| **Privacy policy** | ❌ Fail | None exists | Create + host policy |
| **Data deletion** | ❌ Fail | CoreData only, not backend | Implement deletion API |
| **Terms of service** | ⚠️ Missing | None exists | Create + host ToS |
| **Encryption (TLS)** | ❌ Fail | ws:// not wss:// | Implement TLS |
| **Data retention policy** | ⚠️ Partial | Commands only (7d) | Define for all data types |
| **SLA documentation** | ⚠️ N/A | Self-hosted | Required if offering hosted service |
| **Subscription compliance** | ✅ Pass | No subscriptions | Use IAP if adding paid tier |
| **Third-party disclosure** | ❌ Fail | Claude API not disclosed | Add to privacy policy |
| **Support documentation** | ⚠️ Missing | No support URL | Create support page |

---

## 10. Recommended Action Plan

### Phase 1: Immediate Blockers (2-3 weeks)

**Priority 1 - Deploy Hosted Backend**
- Set up cloud infrastructure (AWS/GCP/Heroku)
- Deploy Clojure backend with TLS (wss://)
- Configure load balancer + health checks
- Provide demo credentials for App Store review
- **Effort**: 2 weeks
- **Cost**: ~$50-100/month infrastructure

**Priority 2 - Privacy Policy**
- Draft privacy policy (legal review recommended)
- Host at permanent URL (https://910labs.dev/untethered/privacy)
- Update App Store Connect metadata
- Add in-app link in Settings
- **Effort**: 1 week (including legal review)
- **Cost**: $500-1000 legal review (optional but recommended)

**Priority 3 - Data Deletion**
- Implement backend deletion API endpoint
- Update iOS app to call deletion API
- Add "Delete All Data" in Settings
- Test and verify deletion completeness
- **Effort**: 1 week

### Phase 2: High-Priority Compliance (1-2 weeks)

**Terms of Service**
- Draft ToS document
- Host at permanent URL
- Link from app and App Store
- **Effort**: 1 week

**Data Retention**
- Define retention policies
- Implement automatic cleanup
- Add retention controls to Settings
- Update privacy policy
- **Effort**: 1 week

**Encryption**
- Generate TLS certificate (Let's Encrypt)
- Update backend to support wss://
- Update iOS app WebSocket URL scheme
- Test secure connection
- **Effort**: 3 days

### Phase 3: Polish & Launch (1 week)

**Support Documentation**
- Create getting started guide
- Write troubleshooting docs
- Set up support email (support@910labs.dev)
- Add FAQ
- **Effort**: 3 days

**Testing**
- End-to-end testing with hosted backend
- Privacy policy compliance verification
- Data deletion testing
- TLS/security validation
- **Effort**: 4 days

### Total Timeline: 4-6 weeks

**Critical Path**:
```
Week 1-2: Deploy hosted backend + TLS
Week 3:   Privacy policy + data deletion
Week 4:   Terms of service + retention
Week 5:   Support docs + testing
Week 6:   App Store submission
```

### Cost Estimate

**One-Time Costs**:
- Legal review (privacy policy + ToS): $500-1000 (optional)
- TLS certificate: $0 (Let's Encrypt)
- Development time: 4-6 weeks

**Recurring Costs** (Monthly):
- Cloud infrastructure: $50-100/month
- Domain/hosting for legal docs: $10/month
- Monitoring tools: $0-50/month (free tier available)

**Total Initial Investment**: $500-1000 + development time
**Total Monthly**: $60-160/month

### Alternative: Self-Hosted Only Submission

**If not deploying hosted backend**:
1. Submit as developer tool (requires localhost-only mode)
2. Provide detailed setup instructions in App Store description
3. Disclose technical requirements prominently
4. **Likely outcome**: Rejection due to non-demonstrable functionality

**Not recommended** - Apple expects apps to work during review.

---

## 11. Conclusion

The voice-code app (Untethered) has a novel architecture but **critical compliance gaps** that will prevent App Store approval without significant changes. The self-hosted backend model is fundamentally incompatible with Apple's review process.

### Must-Fix Issues (Blockers)

1. **Deploy hosted backend** - App must work for reviewers
2. **Create privacy policy** - Legal requirement for all apps
3. **Implement data deletion** - User rights requirement
4. **Enable TLS encryption** - Security requirement

### Key Decision

**Deploy hosted backend** (recommended) or **redesign app architecture** (high risk of rejection).

Estimated effort: **4-6 weeks** of development + infrastructure setup.

---

**Document Status**: Final
**Next Review**: After hosted backend deployment
**Contact**: REDACTED_EMAIL for questions
