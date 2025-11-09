# Legal Compliance Assessment - Untethered (Voice-Code)

**Generated**: 2025-11-08
**App Name**: Untethered (formerly Voice-Code)
**Bundle ID**: dev.910labs.voice-code
**Version**: 1.0 (Build 18)
**Developer**: 910 Labs, LLC
**Contact**: dev@910labs.dev

---

## Executive Summary

**Overall Compliance Status**: ❌ **CRITICAL GAPS - NOT READY FOR SUBMISSION**

The Untethered iOS app has sound technical implementation but lacks essential legal documentation required for App Store approval. Multiple critical legal requirements must be addressed before submission.

**Compliance Breakdown**:
- End User License Agreement (EULA): ⚠️ Optional (using Apple Standard EULA)
- Terms of Service: ❌ Missing (REQUIRED)
- Privacy Policy: ❌ Missing (REQUIRED - BLOCKER)
- Open Source License Compliance: ⚠️ Partial (needs attribution screen)
- Copyright Notices: ⚠️ Minimal (needs enhancement)
- Trademark Considerations: ⚠️ Needs documentation
- Export Compliance: ✅ Declared (needs verification)
- Region-Specific Requirements: ⚠️ Needs GDPR/CCPA compliance

**Critical Blockers**:
1. No Privacy Policy (mandatory for App Store submission)
2. No Terms of Service (required for developer tools with AI/command execution)
3. No open source attribution screen (EPL, Apache 2.0, MIT licenses require it)
4. No contact/support information in-app

**Estimated Time to Compliance**: 40-60 hours (including legal review)

---

## 1. End User License Agreement (EULA)

### Status: ⚠️ USING APPLE STANDARD EULA (Acceptable but Custom EULA Recommended)

**Current State**:
- No custom EULA found in codebase
- No EULA configuration in App Store Connect documentation
- By default, Apple's Standard Licensed Application End User License Agreement (EULA) will apply

**Apple Standard EULA Coverage**:
The Apple Standard EULA provides basic terms covering:
- License grant (non-transferable, non-exclusive)
- Restrictions on use
- Intellectual property rights
- Warranty disclaimers
- Limitation of liability
- Export restrictions
- Third-party beneficiary rights (Apple)

**Analysis**:
For most apps, Apple's Standard EULA is sufficient. However, for a developer tool like Untethered that:
- Executes shell commands on user's behalf
- Interfaces with AI services (Claude/Anthropic)
- Accesses file systems
- Stores conversation history indefinitely
- Processes voice data

A **custom EULA is strongly recommended** to:
- Clarify user responsibilities for command execution
- Disclaim liability for AI-generated code accuracy
- Address data retention and deletion rights
- Specify acceptable use restrictions (no illegal prompts)
- Clarify intellectual property ownership of AI outputs

### Required Actions

**RECOMMENDED (High Priority)**:

1. **Create Custom EULA** following Apple's 10 minimum requirements:
   - Agreement between developer and end-user (not Apple)
   - Limited, revocable, non-transferable license
   - Developer responsibility for maintenance/support
   - Developer responsibility for warranties
   - Developer handles product claims (not Apple)
   - Developer handles IP infringement claims
   - User compliance with export restrictions
   - Developer contact information
   - Third-party agreement compliance
   - Apple as third-party beneficiary

2. **EULA Sections Specific to Untethered**:

```
1. GRANT OF LICENSE
   - Single-user license for personal/professional development use
   - Non-transferable, revocable at developer's discretion
   - Requires user's own Claude API access via backend server

2. RESTRICTIONS
   - No use for illegal activities or malicious code generation
   - No prompts designed to circumvent AI safety features
   - No use to violate third-party intellectual property rights
   - No reverse engineering of app or backend protocol

3. USER RESPONSIBILITIES
   - User solely responsible for executed commands and their effects
   - User responsible for validating AI-generated code before use
   - User responsible for securing backend server access
   - User acknowledges file system access and data storage implications

4. AI SERVICE DISCLAIMER
   - App interfaces with Anthropic Claude AI (user must comply with Anthropic ToS)
   - Developer not responsible for AI output accuracy, completeness, or safety
   - AI-generated code may contain errors or security vulnerabilities
   - User must review all AI suggestions before implementation

5. COMMAND EXECUTION DISCLAIMER
   - App executes shell commands based on user instructions
   - Developer not liable for data loss, corruption, or system damage
   - User responsible for reviewing commands before execution
   - No warranty of command safety or system compatibility

6. DATA RETENTION AND PRIVACY
   - Conversation history stored indefinitely until user deletion
   - Command history retained for 7 days (configurable)
   - User may delete sessions and data at any time
   - See Privacy Policy for detailed data handling practices

7. INTELLECTUAL PROPERTY
   - App and backend software remain developer's property
   - User retains rights to their prompts and code
   - AI-generated content subject to Anthropic's terms
   - Open source components retain original licenses (EPL, Apache 2.0, MIT)

8. WARRANTY DISCLAIMER
   - App provided "AS IS" without warranties of any kind
   - No guarantee of uninterrupted service or error-free operation
   - No warranty that AI outputs meet user requirements
   - No warranty of compatibility with user's development environment

9. LIMITATION OF LIABILITY
   - Developer not liable for consequential, incidental, or indirect damages
   - No liability for data loss, business interruption, or lost profits
   - Maximum liability limited to amount paid for app (if any)

10. TERMINATION
    - License terminates upon violation of terms
    - User must cease use and delete app upon termination
    - Provisions regarding warranty disclaimer and liability survive termination

11. EXPORT COMPLIANCE
    - User confirms not under US embargo or designated as prohibited party
    - User responsible for compliance with local export laws
    - App uses standard encryption (SSL/TLS) for network communication

12. GOVERNING LAW
    - Agreement governed by laws of [Your State/Country]
    - Disputes subject to exclusive jurisdiction of [Your Courts]

13. THIRD-PARTY BENEFICIARY
    - Apple and subsidiaries are third-party beneficiaries
    - Apple may enforce this EULA against user
    - Developer relationship is with end-user, not Apple

14. CONTACT INFORMATION
    - Developer: 910 Labs, LLC
    - Email: dev@910labs.dev
    - Support: [Support URL]
```

3. **Upload to App Store Connect**:
   - During app submission, select "Custom EULA"
   - Paste EULA text into designated field
   - EULA will be presented to users before download

**ALTERNATIVE (Acceptable but Riskier)**:

Continue using Apple Standard EULA BUT add comprehensive Terms of Service (see Section 2) and strong in-app disclaimers for command execution and AI content.

### Legal Review Recommendation

**CRITICAL**: Have custom EULA reviewed by attorney familiar with:
- Software licensing
- App Store requirements
- AI/ML service integration
- Developer tools liability

**Estimated Cost**: $1,000-$3,000 for initial draft and review
**Timeline**: 1-2 weeks

---

## 2. Terms of Service

### Status: ❌ MISSING (REQUIRED)

**Current State**:
- No Terms of Service document found
- No in-app links to ToS
- No acceptance flow on first launch
- Content policy assessment identified this as critical blocker

**Why ToS is Required for Untethered**:

Unlike consumer apps, developer tools that execute code and interface with AI services require explicit Terms of Service to:
- Define acceptable use boundaries
- Limit developer liability for user actions
- Comply with third-party service requirements (Anthropic Claude)
- Meet App Store Review Guidelines 1.2 (user-generated content)
- Protect against misuse for illegal activities

**Apple Requirements**:
App Store Review Guideline 5.1.1 requires privacy policies for apps that collect data. While ToS is not explicitly required, apps with UGC or risky functionality (command execution) need acceptable use policies.

### Required Actions

**CRITICAL - MUST COMPLETE BEFORE SUBMISSION**:

1. **Create Terms of Service Document** covering:

```
TERMS OF SERVICE - UNTETHERED APP

Last Updated: [Date]

1. ACCEPTANCE OF TERMS
   By downloading, installing, or using Untethered, you agree to these Terms.
   If you do not agree, do not use the app.

2. DESCRIPTION OF SERVICE
   Untethered is a voice-controlled interface for Claude AI, enabling iOS-based
   interaction with coding assistance. The app requires:
   - Your own backend server running the Untethered backend
   - Access to Anthropic Claude via Claude CLI
   - Network connectivity between iOS device and backend

3. USER ELIGIBILITY
   - Minimum age: 17 years old
   - Must have legal capacity to enter binding agreements
   - Must not be prohibited from using the service under applicable laws

4. ACCEPTABLE USE POLICY
   You agree NOT to use Untethered to:
   - Generate code for illegal activities or malicious purposes
   - Circumvent security measures or access systems without authorization
   - Violate intellectual property rights of third parties
   - Harass, threaten, or harm others
   - Distribute malware, viruses, or harmful code
   - Violate Anthropic's Claude Acceptable Use Policy
   - Attempt to reverse engineer or compromise the app or backend

5. USER RESPONSIBILITIES
   You are solely responsible for:
   - Commands executed via the app on your systems
   - Accuracy and safety of AI-generated code before use
   - Security of your backend server and network communication
   - Compliance with Anthropic's Terms of Service
   - Backup of important data before using command execution features
   - Validating working directories before running commands
   - Understanding implications of Makefile targets and git commands

6. AI-GENERATED CONTENT DISCLAIMER
   - AI responses are generated by Anthropic Claude, not by 910 Labs
   - AI outputs may contain errors, inaccuracies, or security vulnerabilities
   - Developer makes no warranties about AI output quality or fitness
   - User must review and validate all AI suggestions before implementation
   - AI training and content policies are controlled by Anthropic

7. COMMAND EXECUTION RISKS
   - App can execute shell commands via Makefile targets and git
   - Destructive commands (deletion, modification) are possible
   - Developer not responsible for data loss or system damage
   - User should preview commands before execution when possible
   - No sandbox or safety validation beyond what user configures

8. DATA COLLECTION AND PRIVACY
   See Privacy Policy at [URL] for detailed information.
   Summary:
   - Voice data processed via Apple Speech Framework
   - Transcriptions sent to your configured backend server
   - Conversation history stored locally in CoreData
   - Command history retained for 7 days
   - No data sold or shared with third parties (except Apple, Anthropic)

9. THIRD-PARTY SERVICES
   - Claude AI: Subject to Anthropic's Terms (https://www.anthropic.com/legal/aup)
   - Apple Speech Recognition: Subject to Apple's terms
   - User's backend server: User's responsibility to secure and maintain

10. INTELLECTUAL PROPERTY
    - App and backend software: © 2025 910 Labs, LLC. All rights reserved.
    - User prompts and code: Owned by user
    - AI responses: Subject to Anthropic's terms
    - Open source components: See Acknowledgments (EPL, Apache 2.0, MIT licenses)

11. WARRANTY DISCLAIMER
    UNTETHERED IS PROVIDED "AS IS" WITHOUT WARRANTIES OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, FITNESS
    FOR A PARTICULAR PURPOSE, AND NON-INFRINGEMENT. DEVELOPER DOES NOT WARRANT
    THAT THE APP WILL BE ERROR-FREE, SECURE, OR UNINTERRUPTED.

12. LIMITATION OF LIABILITY
    TO THE MAXIMUM EXTENT PERMITTED BY LAW, 910 LABS SHALL NOT BE LIABLE FOR:
    - Indirect, incidental, consequential, or punitive damages
    - Data loss, business interruption, or lost profits
    - Damages arising from AI-generated code or executed commands
    - Unauthorized access to user's systems or data
    - Failures of third-party services (Claude, Apple Speech)

    MAXIMUM LIABILITY LIMITED TO $50 OR AMOUNT PAID FOR APP (if any).

13. INDEMNIFICATION
    You agree to indemnify 910 Labs against claims arising from:
    - Your use of the app in violation of these Terms
    - Your violation of third-party rights
    - Code or commands generated/executed through the app
    - Your failure to secure backend server or network

14. MODIFICATIONS TO SERVICE AND TERMS
    - Developer may modify Terms at any time
    - Continued use constitutes acceptance of modified Terms
    - Material changes will be notified via in-app notice or email
    - Developer may discontinue service at any time without liability

15. TERMINATION
    - Developer may terminate your access for Terms violations
    - You may stop using the app at any time
    - Upon termination, delete app and all associated data
    - Sections 6, 11, 12, 13, and 16 survive termination

16. EXPORT COMPLIANCE
    You confirm that:
    - You are not located in a country subject to US embargo
    - You are not on US Treasury Dept. prohibited parties list
    - You will comply with export restrictions on encryption software

17. DISPUTE RESOLUTION
    - Governed by laws of [State/Country]
    - Disputes resolved in courts of [Jurisdiction]
    - No class action lawsuits permitted
    - Arbitration clause (optional, consult attorney)

18. MISCELLANEOUS
    - Entire agreement between user and developer
    - Severability: invalid provisions don't affect remainder
    - No waiver of rights by developer inaction
    - Assignment: developer may assign; user may not

19. CONTACT INFORMATION
    Developer: 910 Labs, LLC
    Email: dev@910labs.dev
    Address: [Physical address for legal notices]
    Support: [Support URL]

20. APPLE-SPECIFIC TERMS
    - Agreement is between you and 910 Labs, not Apple
    - Apple not responsible for app or content
    - Apple not obligated to provide maintenance or support
    - Apple not liable for claims related to the app
    - Apple is third-party beneficiary with enforcement rights
    - You confirm compliance with Apple EULA and export restrictions
```

2. **Host ToS Publicly**:
   - Publish at stable URL (e.g., https://untethered.910labs.dev/terms)
   - Ensure URL remains accessible long-term
   - Include "Last Updated" date and version history

3. **Implement In-App Links**:

   **File**: `/Users/travisbrown/code/mono/active/voice-code/ios/VoiceCode/Views/SettingsView.swift`

   Add section to Settings:
   ```swift
   Section("Legal") {
       Link("Terms of Service", destination: URL(string: "https://untethered.910labs.dev/terms")!)
       Link("Privacy Policy", destination: URL(string: "https://untethered.910labs.dev/privacy")!)
       Link("Open Source Licenses", destination: ...)
   }
   ```

4. **Consider First-Launch Acceptance** (Optional but Recommended):
   - Show ToS and Privacy Policy on first app launch
   - Require user tap "Accept" to continue
   - Store acceptance flag in UserDefaults
   - Particularly important for command execution features

5. **App Store Connect**:
   - Add "Terms of Service URL" in App Information section
   - Include in app description/notes to reviewer

### Legal Review Recommendation

**CRITICAL**: Terms of Service should be reviewed by attorney, especially sections on:
- Liability limitations (varies by jurisdiction)
- Indemnification clauses (some states restrict)
- Arbitration/dispute resolution (requires careful drafting)
- Export compliance (US regulations apply)

**Estimated Cost**: $1,500-$4,000 for draft and review
**Timeline**: 2-3 weeks

---

## 3. Privacy Policy

### Status: ❌ MISSING (REQUIRED - CRITICAL BLOCKER)

**Current State**:
- No privacy policy document found anywhere in codebase
- Privacy compliance report (app-store-readiness/privacy-compliance.md) identifies this as critical blocker
- No URL configured in App Store Connect
- This is **mandatory** per App Store Review Guidelines 5.1.1

**Apple Requirements**:
- ALL apps must have publicly accessible privacy policy
- URL must be provided during App Store submission
- Policy must clearly describe data collection, use, sharing, and retention
- Must comply with applicable privacy laws (GDPR, CCPA, COPPA)
- Privacy Nutrition Labels in App Store Connect must match policy

**Legal Requirements**:
- **GDPR** (EU): Transparency, purpose limitation, data minimization, user rights
- **CCPA/CPRA** (California): Right to know, delete, opt-out, non-discrimination
- **COPPA** (US, children <13): Parental consent, data minimization (NOT applicable if 17+ age rating)
- **CalOPPA** (California): Mandatory privacy policy for California users

### Data Collection Analysis

Based on code review, Untethered collects/processes:

**1. Voice Audio Data**:
- Source: Microphone via AVFoundation
- Processing: Apple Speech Framework (SFSpeechRecognizer)
- Location: On-device (iOS 13+) or Apple servers
- Retention: Not stored (only transcription kept)
- Privacy key: NSMicrophoneUsageDescription, NSSpeechRecognitionUsageDescription

**2. Text Transcriptions**:
- Source: Speech recognition output
- Transmission: Sent to user's backend server via WebSocket
- Storage: CoreData (local), backend session files
- Retention: Indefinite (until user deletes session)

**3. Conversation History**:
- Content: User prompts and Claude AI responses
- Storage: CoreData (iOS), ~/.claude/projects/*.jsonl (backend)
- Retention: Indefinite (until user deletes)
- Sync: Between iOS and backend via WebSocket

**4. Command History**:
- Content: Shell commands, output, exit codes, timestamps
- Storage: ~/.voice-code/command-history/ (backend)
- Retention: 7 days (configurable)
- Includes: Working directory, command IDs, execution metadata

**5. Network Data**:
- WebSocket communication with user's backend server
- Session IDs (UUIDs), working directories, timestamps
- Transmitted via WSS (WebSocket Secure) if user configures HTTPS

**6. Configuration Data**:
- Backend server URL (stored in UserDefaults)
- App settings (auto-read, voice rate, etc.)
- No account credentials stored in app

**7. File System Access**:
- Working directories for command execution
- Project paths for session organization
- Read-only access to Makefile for command discovery

**Third-Party Data Sharing**:
- **Apple**: Voice data (if using server-based speech recognition)
- **Anthropic**: Text prompts sent via backend to Claude CLI
- **User's backend**: All conversation and command data
- **NO analytics, advertising, or tracking services**

### Required Actions

**CRITICAL - MUST COMPLETE BEFORE SUBMISSION**:

1. **Create Comprehensive Privacy Policy** with these sections:

```
PRIVACY POLICY - UNTETHERED APP

Effective Date: [Date]
Last Updated: [Date]

1. INTRODUCTION

   910 Labs, LLC ("we," "our," "us") operates the Untethered mobile application
   (the "App"). This Privacy Policy explains how we collect, use, disclose, and
   protect information when you use our App.

   By using Untethered, you agree to this Privacy Policy. If you do not agree,
   please do not use the App.

2. INFORMATION WE COLLECT

   2.1 Voice Data
   - What: Audio recordings from your microphone for speech-to-text
   - How: Via Apple's Speech Recognition framework
   - Processing: On-device (iOS 13+) or Apple servers (earlier iOS versions)
   - Retention: Audio not stored; only text transcription retained
   - Control: You can revoke microphone permission in iOS Settings

   2.2 Text Input and Transcriptions
   - What: Voice transcriptions and text you type
   - Purpose: Sent to your backend server for AI processing
   - Storage: Stored locally on your device (CoreData) and your backend server
   - Retention: Indefinite, until you delete the session

   2.3 Conversation History
   - What: Complete record of prompts and AI responses
   - Storage: Local (CoreData) and backend (~/.claude/projects/*.jsonl)
   - Sync: Automatically synchronized between iOS and backend
   - Retention: Indefinite, until you manually delete sessions
   - Control: Delete sessions via app UI or backend filesystem

   2.4 Command Execution Data
   - What: Shell commands, output, exit codes, working directories
   - Storage: Backend server (~/.voice-code/command-history/)
   - Retention: 7 days (configurable)
   - Purpose: Command history and output retrieval
   - Cleanup: Automated deletion after retention period

   2.5 Configuration and Settings
   - What: Backend server URL, voice settings, preferences
   - Storage: Local device (UserDefaults)
   - Transmission: Server URL sent to backend during connection
   - No account credentials stored

   2.6 Technical Data
   - Session IDs (randomly generated UUIDs)
   - Working directory paths
   - Timestamps for messages and commands
   - WebSocket connection metadata
   - No device identifiers collected

   2.7 Information We DO NOT Collect
   - No email addresses or contact information
   - No location data
   - No advertising identifiers
   - No analytics or tracking
   - No payment information
   - No user accounts or profiles
   - No biometric data beyond voice transcription

3. HOW WE USE YOUR INFORMATION

   3.1 Primary Purpose
   - Provide voice-controlled interface to Claude AI
   - Execute shell commands on your behalf
   - Store and synchronize conversation history
   - Display command history and output

   3.2 We DO NOT Use Data For
   - Advertising or marketing
   - Selling to third parties
   - Training AI models
   - Analytics or usage tracking
   - Profiling or automated decision-making

4. HOW WE SHARE YOUR INFORMATION

   4.1 Apple Inc.
   - Voice audio sent to Apple for speech recognition (if using server-based)
   - Subject to Apple's Privacy Policy
   - User can check on-device vs server in iOS Settings > Siri & Search

   4.2 Anthropic (Claude AI)
   - Your text prompts sent via backend to Claude CLI
   - Subject to Anthropic's Privacy Policy and Commercial Terms
   - Required for AI functionality
   - No direct connection from iOS app to Anthropic

   4.3 Your Backend Server
   - All conversation data, commands, and configuration
   - You control and operate this server
   - You are responsible for securing server access
   - Data transmitted via WebSocket (use WSS for encryption)

   4.4 We Do NOT Share With
   - Advertisers or data brokers
   - Social media platforms
   - Analytics services
   - Other third-party services
   - Law enforcement (unless legally required)

5. DATA SECURITY

   5.1 Transmission Security
   - Recommend WSS (WebSocket Secure) with TLS encryption
   - Server URL and security controlled by you
   - No end-to-end encryption between iOS and backend (implement if needed)

   5.2 Storage Security
   - Local data protected by iOS sandbox and device encryption
   - Backend data security is your responsibility
   - No cloud backups unless you enable iCloud for app data

   5.3 Authentication
   - Session-based, no passwords stored
   - Backend authentication is your responsibility

6. DATA RETENTION

   6.1 Conversation History
   - Retained: Indefinitely until you delete
   - Location: CoreData (iOS), ~/.claude/projects/ (backend)
   - Deletion: Manual via app UI or backend filesystem

   6.2 Command History
   - Retained: 7 days (default, configurable)
   - Location: ~/.voice-code/command-history/ (backend)
   - Deletion: Automatic after retention period

   6.3 Voice Audio
   - Retained: Not stored (only transcription kept)
   - Apple may retain for quality improvement (see Apple Privacy Policy)

   6.4 App Deletion
   - Deleting app removes CoreData but NOT backend data
   - To fully delete data, delete backend session files manually

7. YOUR PRIVACY RIGHTS

   7.1 Access
   - View conversation history in app
   - Export sessions as plain text
   - Access backend files directly

   7.2 Deletion
   - Delete individual sessions via app
   - Delete all app data by uninstalling
   - Delete backend data by removing session files

   7.3 Correction
   - Edit session names
   - Delete and recreate sessions
   - No "edit history" feature (delete and regenerate instead)

   7.4 Portability
   - Export sessions as plain text via copy/paste
   - Backend data in JSONL format (easily parseable)

   7.5 Region-Specific Rights

   GDPR (European Union):
   - Right to access, rectification, erasure, restriction
   - Right to data portability
   - Right to object to processing
   - Right to withdraw consent
   - Right to lodge complaint with supervisory authority
   Contact: dev@910labs.dev

   CCPA/CPRA (California):
   - Right to know what personal information is collected
   - Right to delete personal information
   - Right to opt-out of sale (NOT APPLICABLE - we don't sell data)
   - Right to non-discrimination
   - Right to correct inaccurate information
   Contact: dev@910labs.dev

   Other US States (Virginia, Colorado, Connecticut, Utah, etc.):
   - Similar rights to CCPA
   - Contact dev@910labs.dev for requests

8. CHILDREN'S PRIVACY (COPPA Compliance)

   Untethered is NOT intended for children under 17.

   We do not knowingly collect personal information from children under 13.
   If we become aware that a child under 13 has provided personal information,
   we will delete it immediately.

   Parents: If you believe your child has provided information, contact
   dev@910labs.dev immediately.

9. INTERNATIONAL DATA TRANSFERS

   - Backend server location controlled by you
   - If server outside your country, you control transfer
   - Apple services may transfer voice data internationally
   - Anthropic Claude may process data in US (check Anthropic policy)

10. CHANGES TO THIS PRIVACY POLICY

    We may update this policy periodically. Changes will be posted at:
    [Privacy Policy URL]

    Material changes will be notified via:
    - In-app notice
    - Email (if we have contact information)

    Last Updated date shown at top of policy.
    Continued use after changes constitutes acceptance.

11. DO NOT TRACK

    The app does not respond to Do Not Track signals because we do not track users.

12. CALIFORNIA SHINE THE LIGHT LAW

    We do not share personal information with third parties for their direct
    marketing purposes. California residents may request confirmation by
    contacting dev@910labs.dev.

13. NEVADA PRIVACY RIGHTS

    Nevada residents: We do not sell personal information. You may still request
    confirmation by contacting dev@910labs.dev.

14. CONTACT US

    Questions about this Privacy Policy? Contact:

    910 Labs, LLC
    Email: dev@910labs.dev
    Address: [Physical address for legal correspondence]

    Data Protection Officer (if applicable): [Name/Email]

    GDPR Representative (EU): [If offering service in EU]
    CCPA Contact: dev@910labs.dev

15. EFFECTIVE DATE AND ACKNOWLEDGMENT

    This Privacy Policy is effective as of [Date].
    By using Untethered, you acknowledge you have read and understood this policy.
```

2. **Host Privacy Policy Publicly**:
   - URL: https://untethered.910labs.dev/privacy (or similar)
   - Must be accessible without app installation
   - Include version history for GDPR compliance
   - Ensure long-term availability

3. **Add to Info.plist** (Optional but Recommended):
   ```xml
   <key>NSPrivacyPolicyURL</key>
   <string>https://untethered.910labs.dev/privacy</string>
   ```

4. **Implement In-App Access**:
   - Add link in SettingsView.swift
   - Consider first-launch display
   - Make easily discoverable

5. **Complete App Store Connect Privacy Nutrition Labels**:

   **Data Types to Declare**:

   - **Audio Data**:
     - Used for: App Functionality (speech recognition)
     - Linked to User: No
     - Used for Tracking: No
     - Data Not Collected if using on-device only

   - **Other Diagnostic Data** (Session IDs, timestamps):
     - Used for: App Functionality
     - Linked to User: No
     - Used for Tracking: No

   **Data Not Collected**:
   - Contact Info
   - Location
   - User Content (stored locally, not collected by developer)
   - Identifiers
   - Usage Data
   - Health & Fitness
   - Financial Info
   - Purchases
   - Browsing History
   - Search History
   - Sensitive Info

6. **Create Privacy Manifest** (PrivacyInfo.xcprivacy):

   As identified in privacy-compliance.md, create:
   `/Users/travisbrown/code/mono/active/voice-code/ios/VoiceCode/PrivacyInfo.xcprivacy`

   See privacy-compliance.md for full template.

### Legal Review Recommendation

**CRITICAL**: Privacy Policy must be reviewed by privacy attorney familiar with:
- GDPR (if any EU users)
- CCPA/CPRA (if any California users)
- Multi-state US privacy laws (21 states as of 2025)
- App Store requirements

**Estimated Cost**: $2,000-$5,000 for comprehensive multi-jurisdiction policy
**Timeline**: 2-4 weeks

### Testing Requirements

Before submission:
1. Verify privacy policy URL loads correctly
2. Test in-app links on physical device
3. Ensure Privacy Nutrition Labels match actual data collection
4. Confirm PrivacyInfo.xcprivacy is included in bundle
5. Review with team to ensure accuracy

---

## 4. Open Source License Compliance

### Status: ⚠️ PARTIAL COMPLIANCE (Attribution Required)

**Current State**:
- Dependencies analysis completed (app-store-readiness/dependencies-licenses.md)
- All dependencies use App Store-compatible licenses
- **NO open source attribution screen implemented**
- License texts not included in app bundle

**Licenses in Use**:

**Backend (Clojure)**:
- Eclipse Public License 1.0 (EPL): Clojure, core.async, tools.logging, timbre
- Apache License 2.0: http-kit, Jackson libraries
- MIT License: Cheshire
- BSD-3-Clause: ASM (transitive)

**iOS**:
- All Apple frameworks (no attribution required)
- No third-party iOS dependencies

**Attribution Requirements**:

| License | Attribution Required | License Text Required | Source Code Disclosure |
|---------|---------------------|----------------------|----------------------|
| EPL 1.0 | ✅ Yes | ✅ Yes | Only if modified |
| Apache 2.0 | ✅ Yes | ✅ Yes | No |
| MIT | ✅ Yes | ✅ Yes | No |
| BSD-3-Clause | ✅ Yes | ✅ Yes | No |

### Required Actions

**HIGH PRIORITY**:

1. **Create Open Source Acknowledgments Screen**:

   **New File**: `/Users/travisbrown/code/mono/active/voice-code/ios/VoiceCode/Views/OpenSourceLicensesView.swift`

   ```swift
   import SwiftUI

   struct OpenSourceLicensesView: View {
       var body: some View {
           List {
               Section {
                   Text("Untethered uses the following open source software:")
                       .font(.subheadline)
                       .foregroundColor(.secondary)
               }

               // Clojure
               NavigationLink(destination: LicenseDetailView(
                   title: "Clojure",
                   copyright: "Copyright © Rich Hickey. All rights reserved.",
                   licenseType: "Eclipse Public License 1.0",
                   licenseURL: "http://opensource.org/licenses/eclipse-1.0.php"
               )) {
                   LicenseRow(name: "Clojure", license: "EPL 1.0")
               }

               // http-kit
               NavigationLink(destination: LicenseDetailView(
                   title: "http-kit",
                   copyright: "Copyright © 2012-2024 http-kit contributors",
                   licenseType: "Apache License 2.0",
                   licenseURL: "http://www.apache.org/licenses/LICENSE-2.0"
               )) {
                   LicenseRow(name: "http-kit", license: "Apache 2.0")
               }

               // Cheshire
               NavigationLink(destination: LicenseDetailView(
                   title: "Cheshire",
                   copyright: "Copyright © 2012-2024 Lee Hinman",
                   licenseType: "MIT License",
                   licenseURL: "https://opensource.org/licenses/MIT"
               )) {
                   LicenseRow(name: "Cheshire", license: "MIT")
               }

               // Timbre
               NavigationLink(destination: LicenseDetailView(
                   title: "Timbre",
                   copyright: "Copyright © 2014-2025 Peter Taoussanis",
                   licenseType: "Eclipse Public License 1.0",
                   licenseURL: "http://opensource.org/licenses/eclipse-1.0.php"
               )) {
                   LicenseRow(name: "Timbre", license: "EPL 1.0")
               }

               // Jackson
               NavigationLink(destination: LicenseDetailView(
                   title: "Jackson JSON Processor",
                   copyright: "Copyright © 2007-2024 Tatu Saloranta and contributors",
                   licenseType: "Apache License 2.0",
                   licenseURL: "http://www.apache.org/licenses/LICENSE-2.0"
               )) {
                   LicenseRow(name: "Jackson", license: "Apache 2.0")
               }
           }
           .navigationTitle("Open Source Licenses")
       }
   }

   struct LicenseRow: View {
       let name: String
       let license: String

       var body: some View {
           VStack(alignment: .leading) {
               Text(name)
                   .font(.headline)
               Text(license)
                   .font(.caption)
                   .foregroundColor(.secondary)
           }
       }
   }

   struct LicenseDetailView: View {
       let title: String
       let copyright: String
       let licenseType: String
       let licenseURL: String

       var body: some View {
           ScrollView {
               VStack(alignment: .leading, spacing: 16) {
                   Text(title)
                       .font(.title)

                   Text(copyright)
                       .font(.subheadline)

                   Text(licenseType)
                       .font(.headline)

                   Link("View License", destination: URL(string: licenseURL)!)
                       .font(.subheadline)

                   Divider()

                   // Include full license text here or link to it
                   Text(getLicenseText(for: licenseType))
                       .font(.caption)
                       .monospaced()
               }
               .padding()
           }
           .navigationTitle(title)
           .navigationBarTitleDisplayMode(.inline)
       }

       func getLicenseText(for type: String) -> String {
           // Return full license text from bundle resources
           // See step 2 below
           return "Loading..."
       }
   }
   ```

2. **Add Full License Text Files to Bundle**:

   Create: `/Users/travisbrown/code/mono/active/voice-code/ios/VoiceCode/Resources/Licenses/`

   Files needed:
   - `EPL-1.0.txt` (Eclipse Public License full text)
   - `APACHE-2.0.txt` (Apache License 2.0 full text)
   - `MIT.txt` (MIT License full text)
   - `BSD-3-Clause.txt` (BSD 3-Clause full text)

   Download from:
   - EPL: https://www.eclipse.org/legal/epl-v10.html
   - Apache 2.0: https://www.apache.org/licenses/LICENSE-2.0.txt
   - MIT: https://opensource.org/licenses/MIT
   - BSD-3: https://opensource.org/licenses/BSD-3-Clause

3. **Add Link to SettingsView**:

   **File**: `/Users/travisbrown/code/mono/active/voice-code/ios/VoiceCode/Views/SettingsView.swift`

   ```swift
   Section("Legal") {
       Link("Terms of Service", destination: URL(string: "https://untethered.910labs.dev/terms")!)
       Link("Privacy Policy", destination: URL(string: "https://untethered.910labs.dev/privacy")!)
       NavigationLink("Open Source Licenses") {
           OpenSourceLicensesView()
       }
   }
   ```

4. **Add Copyright Notice to About Section**:

   ```swift
   Section("About") {
       HStack {
           Text("Version")
           Spacer()
           Text("1.0 (18)")
               .foregroundColor(.secondary)
       }
       HStack {
           Text("Copyright")
           Spacer()
           Text("© 2025 910 Labs, LLC")
               .foregroundColor(.secondary)
       }
   }
   ```

5. **Create Repository LICENSE File** (Optional but Recommended):

   **File**: `/Users/travisbrown/code/mono/active/voice-code/LICENSE`

   ```
   Untethered (Voice-Code)
   Copyright (c) 2025 910 Labs, LLC. All rights reserved.

   This software is proprietary and confidential. Unauthorized copying,
   distribution, or use is strictly prohibited.

   === Third-Party Software ===

   This software incorporates the following open source libraries:

   - Clojure (EPL 1.0)
   - http-kit (Apache 2.0)
   - Cheshire (MIT)
   - Timbre (EPL 1.0)
   - Jackson (Apache 2.0)

   See app-store-readiness/licenses/ for full license texts.
   ```

### Compliance Checklist

- [ ] Open source attribution screen implemented
- [ ] Full license texts included in app bundle
- [ ] Link added to Settings view
- [ ] Copyright notice displayed in app
- [ ] LICENSE file added to repository
- [ ] Attribution accurately lists all dependencies
- [ ] Links to license URLs functional

---

## 5. Copyright Notices

### Status: ⚠️ MINIMAL (Needs Enhancement)

**Current State**:
- No copyright notices in source code headers
- No copyright screen in app UI
- App Store Connect may have copyright in metadata (not verified)
- Backend code lacks copyright headers

**Copyright Law Basics**:
- Copyright exists upon creation (no registration required in US)
- Notice not legally required but provides benefits:
  - Establishes ownership
  - Prevents "innocent infringement" defense
  - Identifies rights holder for licensing inquiries

**Standard Copyright Notice Format**:
```
Copyright © [Year] [Owner Name]. All rights reserved.
```

### Required Actions

**RECOMMENDED**:

1. **Add Copyright to App UI**:
   - Already covered in Section 4 (About screen in Settings)
   - Also add to app launch screen or first-launch welcome

2. **Add Copyright to Source Code**:

   **Swift Files** (example header):
   ```swift
   //
   // [FileName].swift
   // Untethered
   //
   // Copyright © 2025 910 Labs, LLC. All rights reserved.
   //
   ```

   **Clojure Files** (example header):
   ```clojure
   ;;;
   ;;; Copyright © 2025 910 Labs, LLC. All rights reserved.
   ;;;
   ```

   Use script or find/replace to add to all project files (not test files).

3. **App Store Connect Metadata**:
   - Ensure copyright field shows: "© 2025 910 Labs, LLC"
   - Updated annually (change to "© 2025-2026" in 2026)

4. **Add to README** (if making repository public):
   ```markdown
   ## Copyright and License

   Copyright © 2025 910 Labs, LLC. All rights reserved.

   This software is proprietary. See LICENSE file for details.
   ```

5. **Consider Copyright Registration** (Optional):
   - US Copyright Office registration provides additional legal benefits
   - Allows statutory damages and attorney's fees in infringement suits
   - Cost: $65-$125 per registration
   - Timeline: 6-12 months
   - Not required for protection but recommended for commercial software

### Trademark Considerations

See Section 6 below.

---

## 6. Trademark Considerations

### Status: ⚠️ NEEDS DOCUMENTATION (No Registered Trademarks)

**Current State**:
- App name: "Untethered"
- No trademark search results found in codebase
- No evidence of trademark registration
- No trademark symbols (™ or ®) used

**Trademark Analysis**:

**App Name**: "Untethered"
- Common English word (may be difficult to trademark alone)
- Used in productivity/developer tools context
- May have existing trademarks in other classes

**Risk Assessment**:
- **Likelihood of confusion**: Low (generic term)
- **Prior art**: Likely many uses of "Untethered" in tech
- **Distinctive elements**: Winged icon design (more trademarkable than name)

**Trademark Law Basics**:
- ™ symbol: Unregistered trademark (common law rights)
- ® symbol: Registered with USPTO (federal protection)
- Registration provides nationwide rights and legal presumption of ownership
- Software typically falls under Class 009 (computer software)

### Required Actions

**HIGH PRIORITY**:

1. **Conduct Trademark Search**:
   - USPTO TESS database: https://tmsearch.uspto.gov/
   - Search for "Untethered" in Class 009 (computer software)
   - Search for similar names: "Untether," "Untethered AI," etc.
   - Check App Store for existing apps with similar names
   - Estimated cost: $0 (DIY) or $500-$1,500 (professional search)

2. **Document Findings**:
   Create: `/Users/travisbrown/code/mono/active/voice-code/app-store-readiness/trademark-search.md`

   Document:
   - Search date and databases checked
   - Existing trademarks found (if any)
   - Risk assessment
   - Decision on registration

3. **Use Proper Trademark Symbols** (if proceeding with unregistered mark):

   **App UI**:
   - First prominent use: "Untethered™"
   - Subsequent uses: "Untethered" (without symbol)
   - App Store description: Include ™ in first mention

   **SettingsView About Section**:
   ```swift
   Text("Untethered™")
       .font(.title2)
   ```

4. **Consider Trademark Registration** (Optional but Recommended):

   **Benefits**:
   - Nationwide protection (not just where you use it)
   - Legal presumption of ownership
   - Right to use ® symbol
   - Easier to enforce against infringers
   - Increases brand value

   **Process**:
   - File application with USPTO ($250-$350 per class)
   - Respond to office actions (6-12 months)
   - Achieve registration (~12-18 months total)
   - Maintain with renewal filings (every 10 years)

   **Estimated Total Cost**: $1,500-$3,000 (including attorney fees)
   **Timeline**: 12-18 months

   **Recommendation**: Consult trademark attorney before investing in registration.
   Generic terms like "Untethered" may not qualify without showing acquired distinctiveness.

5. **Add Trademark Notice to App**:

   **SettingsView or About Screen**:
   ```swift
   Text("Untethered is a trademark of 910 Labs, LLC.")
       .font(.caption)
       .foregroundColor(.secondary)
   ```

6. **Third-Party Trademarks**:

   The app references these third-party marks:
   - **Claude™** - Trademark of Anthropic, PBC
   - **Apple**, **iOS**, **iPhone**, **iPad**, **Siri** - Trademarks of Apple Inc.

   **Required**:
   - Add disclaimer in app and marketing materials:

   ```
   "Claude" is a trademark of Anthropic, PBC.
   "Apple," "iOS," "iPhone," "iPad," and "Siri" are trademarks of Apple Inc.,
   registered in the U.S. and other countries and regions.
   ```

   **App Store Description**:
   Include disclaimer:
   ```
   Untethered is not affiliated with, endorsed by, or sponsored by Anthropic, PBC.
   Claude is a trademark of Anthropic, PBC.
   ```

### Compliance Checklist

- [ ] USPTO trademark search completed and documented
- [ ] Decision made on trademark registration
- [ ] Trademark symbols used correctly (™ or ® if registered)
- [ ] Third-party trademark disclaimers added
- [ ] Trademark notice included in app About section
- [ ] App Store description includes necessary disclaimers

---

## 7. Export Compliance

### Status: ⚠️ DECLARED BUT NEEDS VERIFICATION

**Current State**:
- **Info.plist** declares: `ITSAppUsesNonExemptEncryption = false`
- **Meaning**: App claims to NOT use non-exempt encryption
- Dependencies analysis (dependencies-licenses.md) flags this for review

**Encryption Analysis**:

**What the App Uses**:
1. **WebSocket Communication**:
   - Protocol: WS or WSS (WebSocket Secure)
   - WSS uses TLS/SSL (standard HTTPS encryption)
   - Encryption provided by URLSessionWebSocketTask (Apple framework)

2. **Apple Frameworks**:
   - Speech recognition (may use HTTPS to Apple servers)
   - All Apple framework encryption is exempt

3. **No Custom Encryption**:
   - No proprietary encryption algorithms
   - No custom cryptographic implementations
   - No encryption of local data beyond iOS system encryption

**Export Administration Regulations (EAR) Analysis**:

**Exempt Categories** (no reporting required):
- Encryption that's part of the operating system (iOS, Apple frameworks)
- Standard SSL/TLS for HTTPS/WSS connections
- Mass market software with publicly available encryption

**Non-Exempt** (requires reporting):
- Proprietary encryption algorithms
- Custom cryptographic implementations
- Encryption exceeding certain key lengths (no longer common issue)

**Current Declaration Analysis**:
```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

This declaration states the app does NOT use non-exempt encryption, implying:
- All encryption is exempt (OS-provided, standard SSL/TLS)
- No custom crypto implementations
- No proprietary algorithms

**Accuracy**: LIKELY CORRECT
- App uses standard URLSessionWebSocketTask (Apple-provided)
- WSS/TLS is exempt under EAR 740.17(b)
- No evidence of custom encryption in codebase

### Required Actions

**CRITICAL - VERIFY BEFORE SUBMISSION**:

1. **Verify Backend Encryption**:

   Check backend WebSocket implementation:
   ```bash
   cd /Users/travisbrown/code/mono/active/voice-code/backend
   grep -r "ssl\|tls\|encrypt\|crypto" src/
   ```

   **If backend uses standard SSL/TLS**: Current declaration is correct.
   **If backend has custom encryption**: Change to `<true/>` and provide ERN.

2. **Determine Correct Answer for App Store Connect**:

   During submission, Apple asks:
   > "Is your app designed to use cryptography or does it contain or incorporate cryptography?"

   **Answer**: YES (because of WSS/HTTPS)

   Then asks:
   > "Does your app qualify for any of the exemptions provided in Category 5, Part 2 of the U.S. Export Administration Regulations?"

   **Answer**: YES (standard encryption exemption)

   Select exemption:
   - [✓] (e) Encryption (limited to operating system or encryption items in publicly available encryption source code not subject to the EAR)

3. **Update Info.plist if Needed**:

   **If using ONLY standard SSL/TLS** (current state):
   ```xml
   <key>ITSAppUsesNonExemptEncryption</key>
   <false/>
   ```
   Status: ✅ Correct

   **If using custom encryption**:
   ```xml
   <key>ITSAppUsesNonExemptEncryption</key>
   <true/>
   ```
   Then provide Encryption Registration Number (ERN) in App Store Connect.

4. **Document Encryption Use**:

   Create: `/Users/travisbrown/code/mono/active/voice-code/app-store-readiness/export-compliance.md`

   ```markdown
   # Export Compliance Documentation

   ## Encryption Usage

   ### iOS App
   - URLSessionWebSocketTask (Apple framework) - EXEMPT
   - Standard WSS/TLS for WebSocket communication - EXEMPT
   - No custom encryption algorithms
   - No proprietary cryptographic implementations

   ### Backend
   - [Document backend encryption use]
   - If using standard SSL/TLS: EXEMPT
   - If custom crypto: DOCUMENT ERN

   ## EAR Classification

   ECCN: 5D992 (standard encryption, publicly available)
   Exemption: EAR 740.17(b)(1) - Mass market encryption

   ## Export Compliance Declaration

   ITSAppUsesNonExemptEncryption: false

   ## Rationale
   App uses only standard, publicly available encryption provided by
   Apple's iOS frameworks and standard SSL/TLS protocols. No custom
   cryptographic implementations exist in the codebase.

   ## Last Reviewed
   Date: 2025-11-08
   Reviewer: [Name]
   Next Review: Before each App Store submission
   ```

5. **Annual Self-Classification Report**:

   **Status**: NOT REQUIRED for mass-market software (as of 2024 update)

   Per dependencies-licenses.md: "Mac and iOS apps available to the mass market do not require annual self-classification report under EAR Section 740.17(b)(1)."

   **Action**: None required (monitor for regulation changes)

6. **Verify User Eligibility**:

   Terms of Service (Section 2) should include:
   ```
   16. EXPORT COMPLIANCE
       You confirm that:
       - You are not located in a country subject to US embargo
       - You are not on US Treasury Dept. prohibited parties list
       - You will comply with export restrictions on encryption software
   ```

### Compliance Checklist

- [ ] Backend encryption usage verified and documented
- [ ] Info.plist ITSAppUsesNonExemptEncryption value confirmed accurate
- [ ] Export compliance documentation created
- [ ] App Store Connect encryption questions answered correctly
- [ ] Terms of Service includes export restrictions
- [ ] No custom encryption algorithms implemented
- [ ] Annual review process established

**Recommendation**: Current declaration (`false`) is likely correct. Verify backend does not implement custom encryption beyond standard SSL/TLS.

---

## 8. Region-Specific Legal Requirements

### Status: ⚠️ NEEDS GDPR/CCPA COMPLIANCE

**Current State**:
- No region-specific privacy compliance documented
- Privacy Policy not yet created (see Section 3)
- No GDPR-specific user rights implementation
- No CCPA-specific disclosures
- No geo-blocking or region detection

**Applicable Regulations**:

**1. GDPR (European Union + EEA)**
- Applies if: Any EU/EEA users (even one user triggers compliance)
- Requirements: See detailed breakdown below

**2. CCPA/CPRA (California, USA)**
- Applies if: California users AND meet revenue/data thresholds
- Thresholds: $25M revenue OR 100K+ CA consumers OR 50%+ revenue from selling data
- Likely: NOT applicable initially (small user base, no revenue from data sales)
- Future: May apply as user base grows

**3. Multi-State US Privacy Laws (21 states as of 2025)**
- States: Virginia, Colorado, Connecticut, Utah, Montana, Oregon, Texas, Delaware, Iowa, Indiana, Tennessee, Florida, Nebraska, New Hampshire, New Jersey, Kentucky, Maryland, Minnesota, Rhode Island, Arizona, Maine
- Requirements: Similar to CCPA (right to know, delete, opt-out)
- Thresholds vary by state
- Likely: NOT applicable initially

**4. UK GDPR (Post-Brexit)**
- Similar to EU GDPR
- Separate compliance if targeting UK users

**5. Other Jurisdictions**
- Canada (PIPEDA)
- Brazil (LGPD)
- Australia (Privacy Act)
- China (PIPL)
- South Korea (PIPA)
- Japan (APPI)

**Current Risk Assessment**:
- **GDPR**: MEDIUM-HIGH (if any EU users)
- **CCPA**: LOW (unlikely to meet thresholds initially)
- **Other US states**: LOW (thresholds protect small apps)
- **International**: LOW (unless specifically targeting those markets)

### GDPR Compliance Requirements

**If app will have EU/EEA users, must comply with**:

**1. Legal Basis for Processing**:
- **Consent**: For non-essential processing (e.g., analytics) - NOT applicable
- **Contract**: For service delivery (conversation storage) - APPLICABLE
- **Legitimate Interest**: For security, debugging - APPLICABLE

**2. Transparency (Articles 13-14)**:
- ✅ Covered by Privacy Policy (Section 3)
- Must disclose: purposes, legal basis, recipients, retention, rights

**3. User Rights (Articles 15-22)**:

**Right to Access** (Article 15):
- User can request all personal data held
- **Implementation**: Export sessions feature (already exists ✅)
- **Enhancement needed**: Formal request process

**Right to Rectification** (Article 16):
- User can correct inaccurate data
- **Implementation**: Session rename, delete/recreate (partial ✅)

**Right to Erasure** ("Right to be Forgotten") (Article 17):
- User can request deletion of personal data
- **Implementation**: Session deletion (exists ✅)
- **Enhancement needed**: Delete backend data, confirm deletion

**Right to Restriction** (Article 18):
- User can limit processing while disputing accuracy
- **Implementation**: NOT IMPLEMENTED ❌
- **Workaround**: Session deletion achieves similar outcome

**Right to Data Portability** (Article 20):
- User can receive data in machine-readable format
- **Implementation**: Export as plain text (exists ✅)
- **Enhancement**: Provide JSON export of full session data

**Right to Object** (Article 21):
- User can object to processing based on legitimate interest
- **Implementation**: NOT APPLICABLE (processing based on contract)

**Automated Decision-Making** (Article 22):
- No automated decisions with legal/significant effects
- **Status**: NOT APPLICABLE (AI suggestions, not decisions)

**4. Data Protection by Design (Article 25)**:
- Minimize data collection: ✅ (only essential data)
- Pseudonymization: ⚠️ (UUIDs used, but not full anonymization)
- Encryption: ⚠️ (recommend WSS, not enforced)

**5. Data Breach Notification (Article 33-34)**:
- Notify authorities within 72 hours of breach
- Notify users if high risk to rights/freedoms
- **Implementation**: Incident response plan needed ❌

**6. Data Protection Officer (DPO)**:
- Required if: Large-scale processing of special categories
- **Status**: NOT REQUIRED (small scale, no special categories)

**7. GDPR Representative (Article 27)**:
- Required if: Processing EU data but NOT established in EU
- **Status**: REQUIRED if offering to EU users ❌
- **Cost**: €1,500-€5,000/year for representative service

### CCPA/CPRA Compliance Requirements

**Applicability Thresholds** (must meet ONE):
- Annual revenue > $25 million, OR
- Buy/sell/share personal info of 100,000+ CA consumers, OR
- Derive 50%+ revenue from selling personal info

**If thresholds met, must provide**:

**1. Privacy Policy Disclosures**:
- Categories of personal information collected
- Purposes for collection
- Categories shared with third parties
- Consumer rights under CCPA
- ✅ Covered in Privacy Policy template (Section 3)

**2. Consumer Rights**:

**Right to Know**: What personal info is collected
- **Implementation**: Privacy Policy + export feature ✅

**Right to Delete**: Request deletion of personal info
- **Implementation**: Session deletion ✅

**Right to Opt-Out of Sale**: No sale of personal info
- **Status**: NOT APPLICABLE (we don't sell data) ✅

**Right to Non-Discrimination**: Can't deny service for exercising rights
- **Status**: COMPLIANT ✅

**Right to Correct**: Fix inaccurate information (CPRA addition)
- **Implementation**: Edit/delete/recreate ⚠️

**3. "Do Not Sell" Link**:
- Required on homepage/privacy policy
- **Status**: NOT APPLICABLE (we don't sell data)
- **Can add**: "We do not sell your personal information" statement

**4. Verifiable Consumer Requests**:
- Method to verify identity before fulfilling rights requests
- **Implementation**: Email verification needed ❌

### Required Actions

**CRITICAL (if targeting EU/EEA users)**:

1. **Add GDPR Compliance Section to Privacy Policy**:
   - Already included in Section 3 template ✅
   - Specify legal basis for each processing activity
   - List all user rights with instructions to exercise

2. **Implement Data Export Enhancement**:

   **Current**: Copy/paste plain text export ✅
   **Enhancement**: Add JSON export for data portability

   **SettingsView.swift** addition:
   ```swift
   Section("Data Management") {
       Button("Export All Data (JSON)") {
           // Export all sessions as JSON
       }
       Button("Request Data Deletion") {
           // Formal deletion request flow
       }
   }
   ```

3. **Create Data Deletion Workflow**:
   - Confirm deletion of iOS data (CoreData) ✅ (already exists)
   - Confirm deletion of backend data (session files) ❌ (needs implementation)
   - Send deletion confirmation email (if email available)

4. **Appoint GDPR Representative** (if offering to EU):
   - Contract with GDPR representative service
   - List representative contact in Privacy Policy
   - Estimated cost: €1,500-€5,000/year

5. **Create Incident Response Plan**:

   `/Users/travisbrown/code/mono/active/voice-code/app-store-readiness/incident-response-plan.md`

   ```markdown
   # Data Breach Incident Response Plan

   ## Trigger Events
   - Unauthorized access to backend server
   - Exposure of session data or user information
   - Backend server compromise
   - App vulnerability exploitation

   ## Response Steps

   ### Within 24 Hours
   1. Contain breach (shut down affected systems)
   2. Assess scope (how many users affected, what data exposed)
   3. Document incident (timeline, root cause, data affected)

   ### Within 72 Hours (GDPR Requirement)
   4. Notify supervisory authority (EU) if GDPR applicable
   5. Prepare user notification if high risk

   ### Within 30 Days
   6. Notify affected users (email if available, in-app notice)
   7. Implement remediation measures
   8. Conduct post-incident review

   ## Contact Information
   - Internal: dev@910labs.dev
   - Legal Counsel: [Attorney contact]
   - GDPR Representative: [If applicable]
   - Supervisory Authority: [Relevant EU DPA]

   ## User Notification Template
   [Draft notification email/in-app message]
   ```

6. **Add Cookie/Tracking Consent** (if using any):
   - **Current**: NO cookies, tracking, or analytics ✅
   - **Action**: None needed unless adding analytics

7. **Update Terms of Service**:
   - Section 7.5 in Privacy Policy template includes GDPR/CCPA rights ✅
   - Ensure ToS references Privacy Policy prominently

**MODERATE PRIORITY (if targeting California users)**:

8. **Add CCPA Disclosures**:
   - Already in Privacy Policy template (Section 3) ✅
   - Add "Do Not Sell My Personal Information" link (can state "We do not sell data")

9. **Implement Verifiable Request Process**:
   - Email-based verification for data requests
   - Respond within 45 days (CCPA requirement)

**LOW PRIORITY (unless targeting specific markets)**:

10. **Other Jurisdictions**:
    - Canada (PIPEDA): Similar to GDPR, less strict
    - Brazil (LGPD): GDPR-like, requires consent or legal basis
    - Australia: Thresholds protect small apps
    - China (PIPL): Requires local data storage (major barrier)

### Geo-Blocking Considerations

**Option 1: No Geo-Blocking (Recommended for MVP)**:
- Offer app worldwide
- Comply with strictest regulations (GDPR)
- Accept some over-compliance for simplicity

**Option 2: Restrict to Specific Regions**:
- App Store Connect: Select countries/regions
- Pros: Limit compliance burden
- Cons: Smaller user base, complex for VPN users

**Recommendation**: Launch worldwide with GDPR compliance. Most regulations (CCPA, state laws) have revenue/scale thresholds protecting small apps.

### Compliance Checklist

**GDPR (if EU users)**:
- [ ] Privacy Policy includes GDPR-specific disclosures
- [ ] User rights documented with exercise instructions
- [ ] Data export feature tested and functional
- [ ] Data deletion workflow includes backend cleanup
- [ ] GDPR representative appointed (if no EU establishment)
- [ ] Incident response plan created
- [ ] Legal basis for processing documented

**CCPA (if California users + thresholds met)**:
- [ ] Privacy Policy includes CCPA disclosures
- [ ] Consumer rights section added
- [ ] Verifiable request process implemented
- [ ] "Do Not Sell" disclosure added (even if N/A)

**General**:
- [ ] Privacy Policy covers all applicable jurisdictions
- [ ] In-app data management features functional
- [ ] Contact information for privacy requests published
- [ ] Team trained on privacy request handling

### Legal Review Recommendation

**CRITICAL if targeting EU/EEA**: GDPR compliance review by attorney familiar with:
- GDPR requirements
- Cross-border data transfers
- Representative appointment
- Data protection agreements

**Estimated Cost**: $3,000-$7,000 for GDPR compliance review
**Timeline**: 2-4 weeks

---

## Critical Action Items Summary

### BLOCKERS (Must complete before App Store submission):

1. **Privacy Policy** ❌
   - Create comprehensive policy (Section 3 template)
   - Host at public URL
   - Add to Info.plist and App Store Connect
   - Estimated effort: 16-24 hours + legal review
   - **Cost**: $2,000-$5,000 (legal review)
   - **Timeline**: 2-4 weeks

2. **Terms of Service** ❌
   - Create ToS document (Section 2 template)
   - Host at public URL
   - Add in-app links
   - Estimated effort: 16-24 hours + legal review
   - **Cost**: $1,500-$4,000 (legal review)
   - **Timeline**: 2-3 weeks

3. **Open Source Attribution** ⚠️
   - Implement in-app licenses screen (Section 4)
   - Add license text files to bundle
   - Link from Settings
   - Estimated effort: 8-12 hours
   - **Cost**: $0
   - **Timeline**: 1-2 days

4. **Privacy Manifest** ❌
   - Create PrivacyInfo.xcprivacy file
   - See privacy-compliance.md for template
   - Estimated effort: 2-4 hours
   - **Cost**: $0
   - **Timeline**: 1 day

### HIGH PRIORITY (Strongly recommended):

5. **Custom EULA** ⚠️
   - Create EULA with AI/command disclaimers (Section 1)
   - Alternative: Use Apple Standard EULA + comprehensive ToS
   - Estimated effort: 12-16 hours + legal review
   - **Cost**: $1,000-$3,000 (legal review)
   - **Timeline**: 1-2 weeks

6. **Export Compliance Verification** ⚠️
   - Verify backend encryption usage (Section 7)
   - Document compliance
   - Confirm Info.plist declaration accuracy
   - Estimated effort: 4-6 hours
   - **Cost**: $0
   - **Timeline**: 1 day

7. **GDPR Compliance** (if EU users) ⚠️
   - Enhanced data export (JSON)
   - Backend data deletion
   - Incident response plan
   - GDPR representative (if needed)
   - Estimated effort: 16-24 hours + representative
   - **Cost**: €1,500-€5,000/year (representative)
   - **Timeline**: 1-2 weeks

8. **Copyright Notices** ⚠️
   - Add to app UI (About screen)
   - Add to source code headers (optional)
   - Add to README
   - Estimated effort: 4-6 hours
   - **Cost**: $0
   - **Timeline**: 1 day

### MODERATE PRIORITY (Quality improvements):

9. **Trademark Search and Protection**
   - USPTO search for "Untethered"
   - Document findings
   - Add ™ symbol to branding
   - Consider registration
   - Estimated effort: 4-8 hours (search) + attorney time (registration)
   - **Cost**: $1,500-$3,000 (registration)
   - **Timeline**: 1 week (search), 12-18 months (registration)

10. **First-Launch Legal Acceptance**
    - Show ToS and Privacy Policy on first launch
    - Require acceptance to continue
    - Store acceptance flag
    - Estimated effort: 6-8 hours
    - **Cost**: $0
    - **Timeline**: 1-2 days

### LOW PRIORITY (Future enhancements):

11. **Copyright Registration**
    - US Copyright Office registration
    - Provides enhanced legal protections
    - **Cost**: $65-$125
    - **Timeline**: 6-12 months

12. **Multi-Jurisdiction Privacy Compliance**
    - CCPA (if thresholds met)
    - Other US state laws
    - International (Canada, Brazil, Australia, etc.)
    - Triggered by growth, not immediate

---

## Estimated Total Effort and Cost

### Development Effort

| Task | Estimated Hours | Priority |
|------|----------------|----------|
| Privacy Policy creation | 16-24 | CRITICAL |
| Terms of Service creation | 16-24 | CRITICAL |
| Open Source Licenses screen | 8-12 | CRITICAL |
| Privacy Manifest | 2-4 | CRITICAL |
| Custom EULA | 12-16 | HIGH |
| Export compliance docs | 4-6 | HIGH |
| GDPR enhancements | 16-24 | HIGH |
| Copyright notices | 4-6 | HIGH |
| Trademark search | 4-8 | MODERATE |
| First-launch acceptance | 6-8 | MODERATE |
| **TOTAL** | **88-132 hours** | - |

**Developer Time**: 2-3 weeks full-time or 4-6 weeks part-time

### Legal Costs

| Service | Estimated Cost | Priority |
|---------|---------------|----------|
| Privacy Policy review | $2,000-$5,000 | CRITICAL |
| Terms of Service review | $1,500-$4,000 | CRITICAL |
| Custom EULA review | $1,000-$3,000 | HIGH |
| GDPR representative (annual) | €1,500-€5,000 | HIGH (if EU) |
| Trademark search (professional) | $500-$1,500 | MODERATE |
| Trademark registration | $1,500-$3,000 | MODERATE |
| Copyright registration | $65-$125 | LOW |
| **TOTAL (without GDPR/TM)** | **$5,000-$12,000** | - |
| **TOTAL (with GDPR + TM)** | **$10,000-$22,000** | - |

### Recommended Approach

**Phase 1: Critical Blockers (Weeks 1-3)**
- Focus: Privacy Policy, Terms of Service, Open Source Licenses, Privacy Manifest
- Effort: 42-64 hours development + legal review
- Cost: $5,000-$12,000 (legal)
- **Outcome**: App Store submission-ready

**Phase 2: High Priority (Weeks 4-5)**
- Focus: GDPR compliance, export compliance, copyright notices
- Effort: 24-36 hours development
- Cost: €1,500-€5,000 (if GDPR representative needed)
- **Outcome**: EU-compliant and well-documented

**Phase 3: Future Enhancements (Post-Launch)**
- Focus: Trademark registration, copyright registration, multi-jurisdiction compliance
- Effort: Ongoing as user base grows
- Cost: Variable based on growth and expansion

---

## Legal Review Checklist

Before submission, ensure legal review of:

- [ ] Privacy Policy (multi-jurisdiction compliance)
- [ ] Terms of Service (liability limitations, enforceability)
- [ ] EULA (if creating custom)
- [ ] Export compliance declaration
- [ ] GDPR compliance (if targeting EU)
- [ ] Trademark search results
- [ ] Third-party trademark usage (Claude, Apple)
- [ ] Open source license compliance
- [ ] Data breach notification procedures
- [ ] User rights exercise workflows

**Recommended Attorney Specializations**:
- Software licensing
- Privacy law (GDPR, CCPA)
- Intellectual property (trademarks, copyright)
- App Store compliance

**Estimated Total Legal Cost**: $7,000-$15,000 for comprehensive review

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation Status |
|------|-----------|--------|-------------------|
| App rejection (no Privacy Policy) | HIGH | CRITICAL | ❌ Not mitigated |
| App rejection (no ToS) | MEDIUM | HIGH | ❌ Not mitigated |
| GDPR fine (if EU users) | MEDIUM | HIGH | ❌ Not mitigated |
| Open source license violation claim | LOW | MEDIUM | ⚠️ Partial (need attribution screen) |
| Export compliance violation | LOW | MEDIUM | ⚠️ Partial (need verification) |
| Trademark infringement claim | LOW | LOW | ⚠️ Needs search |
| CCPA fine (unlikely to meet thresholds) | LOW | LOW | ✅ Protected by thresholds |
| User liability claim (AI/commands) | MEDIUM | MEDIUM | ⚠️ Needs ToS/EULA |

**Overall Risk Level**: HIGH (due to missing Privacy Policy and ToS)

---

## Conclusion

The Untethered (Voice-Code) iOS app has strong technical foundations but lacks essential legal documentation required for App Store approval and regulatory compliance.

### Strengths:
- Sound architecture with privacy-conscious design
- Minimal third-party dependencies (all App Store-compatible)
- No tracking, analytics, or advertising
- Local data storage with user control
- Export compliance mostly correct

### Critical Gaps:
- **No Privacy Policy** (mandatory for App Store)
- **No Terms of Service** (required for developer tools)
- **No open source attribution screen** (required by licenses)
- **No Privacy Manifest file** (required for iOS 17+)
- Incomplete GDPR compliance (if targeting EU)

### Recommended Path Forward:

**Immediate (Week 1-2)**:
1. Draft Privacy Policy and Terms of Service using templates provided
2. Engage privacy attorney for review ($5,000-$9,000)
3. Host legal documents at public URLs

**Short-term (Week 3-4)**:
4. Implement open source licenses screen
5. Create Privacy Manifest file
6. Add in-app legal links
7. Verify export compliance

**Before Submission (Week 5-6)**:
8. Complete App Store Connect privacy labels
9. Final legal review
10. Test all legal workflows

**Post-Launch**:
11. Monitor for GDPR/CCPA threshold triggers
12. Consider trademark registration
13. Implement enhanced user rights features

### Approval Likelihood:

**With legal documentation**: 85-90% (standard app review)
**Without legal documentation**: 0% (immediate rejection)

**Bottom Line**: Invest 2-3 weeks and $5,000-$12,000 in legal compliance to unlock App Store approval. This is non-negotiable for commercial app distribution.

---

## Document Information

**Generated**: 2025-11-08
**Version**: 1.0
**Author**: AI Analysis (requires legal review)
**Next Review**: Before App Store submission
**Owner**: 910 Labs, LLC
**Contact**: dev@910labs.dev

**Disclaimer**: This document provides technical analysis and suggestions but does not constitute legal advice. Consult qualified legal counsel before making legal compliance decisions.

---

## References

- [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Apple Privacy Requirements](https://developer.apple.com/app-store/app-privacy-details/)
- [GDPR Official Text](https://gdpr-info.eu/)
- [CCPA/CPRA Text](https://oag.ca.gov/privacy/ccpa)
- [USPTO Trademark Search](https://tmsearch.uspto.gov/)
- [Export Administration Regulations](https://www.bis.doc.gov/index.php/regulations/export-administration-regulations-ear)
- [Apple Developer Program License Agreement](https://developer.apple.com/support/terms/)
- [Anthropic Claude Acceptable Use Policy](https://www.anthropic.com/legal/aup)

**Related Project Documents**:
- `/Users/travisbrown/code/mono/active/voice-code/app-store-readiness/content-policy.md`
- `/Users/travisbrown/code/mono/active/voice-code/app-store-readiness/privacy-compliance.md`
- `/Users/travisbrown/code/mono/active/voice-code/app-store-readiness/dependencies-licenses.md`
- `/Users/travisbrown/code/mono/active/voice-code/app-store-readiness/metadata-completeness.md`
