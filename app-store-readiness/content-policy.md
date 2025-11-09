# Apple App Store Content Policy Compliance Review

**App Name:** Untethered (formerly Voice-Code)
**Review Date:** 2025-11-08
**Reviewer:** AI Analysis
**Target Platform:** iOS 18.5+

## Executive Summary

**Overall Compliance Status:** ⚠️ NEEDS ATTENTION

The voice-code app is a developer tool that provides voice-controlled access to Claude AI for coding assistance. While the app does not directly violate major content policy areas, there are critical gaps in legal documentation and content handling that must be addressed before App Store submission.

---

## 1. User-Generated Content (UGC)

### Current State
**Status:** ⚠️ MODERATE RISK

**Findings:**
- Users can create and send text/voice prompts to Claude AI
- Conversation history is stored locally in CoreData
- Messages can be copied to clipboard and exported as plain text
- No content originates from other users - all content is AI-generated responses or user's own input

**Content Flow:**
```
User Voice/Text Input
  → iOS App (transcription via Apple Speech Framework)
  → WebSocket to Backend
  → Claude AI CLI
  → AI Response
  → Stored in CoreData & displayed in app
```

**Concerns:**
1. **No Content Moderation**: The app passes user prompts directly to Claude AI without any filtering
2. **No Profanity Filter**: User can input any text/speech, including inappropriate language
3. **Export Functionality**: Users can export conversations containing potentially inappropriate content
4. **Clipboard Access**: Error messages and full conversations can be copied without sanitization

### Apple Requirements
Per App Store Review Guidelines 1.2, apps with user-generated content must:
- Filter objectionable material
- Provide mechanism for reporting offensive content
- Block abusive users
- Remove objectionable content within 24 hours

### Recommendations
**CRITICAL:**
1. **Add Disclaimer**: Include clear statement that app is for developer use and user is responsible for appropriate prompts
2. **Terms of Acceptable Use**: Implement terms prohibiting illegal or harmful prompts
3. **Consider Age Rating**: App should be rated 17+ due to unfiltered AI responses

**OPTIONAL (if targeting general audience):**
1. Implement basic profanity filter on input prompts
2. Add reporting mechanism for problematic AI responses
3. Content warnings for code that might be malicious

---

## 2. Content Moderation Mechanisms

### Current State
**Status:** ❌ MISSING

**Findings:**
- **No moderation system exists**
- App relies entirely on Claude AI's built-in safety features
- No logging of inappropriate content attempts
- No user blocking or restriction mechanisms
- No content reporting features

**AI Provider Responsibility:**
- Claude AI (Anthropic) has Constitutional AI safety measures
- However, developer bears App Store compliance responsibility
- Cannot delegate all moderation to third-party AI service

### Apple Requirements
1.2.1: Apps with UGC must have mechanisms for:
- Filtering objectionable content
- Reporting concerns to app developer
- Ability to block abusive users
- Removing problematic content within 24 hours

### Recommendations
**CRITICAL:**
1. **Add Terms of Service** (see section 4 below)
2. **Implement Logging**: Track prompts that trigger Claude safety responses
3. **Add Report Feature**: Allow users to report problematic AI responses

**MODERATE PRIORITY:**
1. Basic input validation to reject obviously inappropriate prompts
2. Content warning system for potentially sensitive code (e.g., cryptography, network attacks)

---

## 3. Inappropriate Content Prevention

### Current State
**Status:** ⚠️ RELIES ON THIRD-PARTY

**Findings:**
- **No app-level filtering**: All content filtering delegated to Claude AI
- **Voice Input**: Apple's Speech Recognition API used - no additional filtering
- **Code Content**: App displays code without syntax-based filtering for malicious patterns
- **Command Execution**: App can execute arbitrary shell commands via Makefile integration

**Potentially Sensitive Features:**
1. **Command Execution** (`CommandExecutionView.swift`):
   - Executes make targets and git commands
   - No validation of command safety
   - Could potentially execute destructive commands
   - Example: User could create Makefile with `rm -rf` commands

2. **File System Access**:
   - App accesses user's file system via working directories
   - No sandboxing beyond iOS system-level protections

3. **WebSocket Communication**:
   - Unencrypted communication with backend (if not using wss://)
   - No mention of SSL/TLS requirements in config

### Apple Requirements
- Apps must not facilitate illegal activities
- Developer tools must have appropriate safeguards
- Apps cannot execute arbitrary code from untrusted sources

### Recommendations
**CRITICAL:**
1. **Document Command Safety**: Add warning in UI that users are responsible for command safety
2. **Require wss://**: Enforce encrypted WebSocket connections
3. **Add Age Rating Justification**: Include "Unrestricted Web Access" and "Developer Tool" in App Store metadata

**MODERATE PRIORITY:**
1. Command preview/confirmation for destructive operations
2. Whitelist of "safe" commands vs. requiring user confirmation for others

---

## 4. Terms of Service & Privacy Policy

### Current State
**Status:** ❌ MISSING (CRITICAL BLOCKER)

**Findings:**
- **No Terms of Service**
- **No Privacy Policy**
- **No End User License Agreement (EULA)**
- **No in-app links to legal documents**

**Data Collection Identified:**
1. **Microphone Access**: For voice input
2. **Speech Recognition**: Transcription via Apple frameworks
3. **File System Access**: Working directories, session files
4. **Network Data**: WebSocket communication with backend server
5. **User Content**: Conversation history stored in CoreData
6. **Persistent Storage**: Sessions stored at `~/.claude/projects/`

### Apple Requirements
**MANDATORY per 5.1.1:**
- Privacy Policy must be available during app review
- Link must be entered in App Store Connect
- Must clearly disclose data collection practices
- Must explain how data is used, shared, and retained

### Recommendations
**CRITICAL - MUST COMPLETE BEFORE SUBMISSION:**

1. **Create Privacy Policy** covering:
   - Microphone and speech recognition usage
   - Data storage (local CoreData + backend)
   - Third-party services (Claude AI/Anthropic)
   - Data retention (7-day command history, indefinite conversation storage)
   - User rights (data deletion, export)
   - Server communication (WebSocket to user's own backend)

2. **Create Terms of Service** including:
   - Acceptable use policy (no illegal prompts, no harmful code generation requests)
   - Age restriction (13+ or 17+ recommended)
   - Disclaimer of liability for AI-generated code
   - User responsibility for executed commands
   - Anthropic's Claude AI terms (pass-through compliance)

3. **Add In-App Links**:
   - Privacy Policy link in Settings view
   - Terms of Service link in Settings view
   - Consider showing on first launch

4. **App Store Connect Metadata**:
   - Add Privacy Policy URL
   - Add Support URL
   - Complete Privacy Nutrition Labels accurately

**Template Sections Needed:**

**Privacy Policy Must Include:**
```
- What data is collected (voice, text, file paths, session data)
- How it's used (AI interaction, conversation history)
- Where it's stored (local device, user's own backend server)
- Third parties (Anthropic/Claude AI)
- User control (session deletion, data export)
- Children's privacy (COPPA - see section 5)
- Contact information for privacy inquiries
```

**Terms of Service Must Include:**
```
- Prohibited uses (illegal activity, harassment, harmful code)
- Age requirements (minimum age 13 or 17)
- Intellectual property (code ownership, AI output rights)
- Disclaimer (AI accuracy, code safety)
- Limitation of liability
- Termination rights
- Governing law
```

---

## 5. COPPA Compliance (Children's Privacy)

### Current State
**Status:** ⚠️ NEEDS CLARITY

**Findings:**
- **No age gate**: App does not verify user age
- **No parental consent mechanism**
- **Deployment Target**: iOS 18.5+ (implicitly limits to users with newer devices)
- **Content**: Developer tool with unfiltered AI responses

**Data Collection from Children (if allowed):**
- Voice recordings (speech recognition)
- Text input
- File system data
- Conversation history

### Apple Requirements (1.3)
- Apps targeted at children must comply with COPPA
- Cannot include analytics, advertising, or behavioral targeting for children
- Must have privacy policy addressing children's data
- Parental gate required for data collection from children under 13

### Current Age Rating Analysis
**Likely Rating: 17+** due to:
- Unfiltered AI content
- Developer tool (technical complexity)
- Command execution capabilities
- Unrestricted web access (Claude AI API)

### Recommendations
**CRITICAL:**
1. **Set Minimum Age**: Configure App Store rating as 17+ (simplest approach)
2. **Alternative**: If targeting 13+, add parental consent mechanism and COPPA-compliant privacy policy
3. **Do NOT target children under 13**: App is inappropriate for young children

**Privacy Policy Section for Children:**
```
"This app is not intended for use by children under 17. We do not knowingly
collect personal information from children under 13. If we become aware that
a child under 13 has provided us with personal information, we will delete
it immediately."
```

---

## 6. Gambling/Betting Restrictions

### Current State
**Status:** ✅ COMPLIANT

**Findings:**
- No gambling functionality
- No betting mechanisms
- No in-app purchases for chance-based rewards
- No loot boxes or random rewards

**Assessment:** Not applicable to this app.

---

## 7. Medical/Health Claims Compliance

### Current State
**Status:** ✅ COMPLIANT

**Findings:**
- No health or medical features
- No health data collection (HealthKit not used)
- No medical advice or diagnosis functionality
- Voice input is for control purposes only, not health monitoring

**Assessment:** Not applicable to this app.

---

## 8. Prohibited Content Types

### Analysis by Category

#### 8.1 Defamatory/Discriminatory Content
**Status:** ⚠️ INDIRECT RISK
- App does not create such content directly
- Claude AI could potentially generate problematic responses
- Risk mitigated by Claude's Constitutional AI safeguards
- **Action**: Add disclaimer that AI responses may require user judgment

#### 8.2 Violence/Graphic Content
**Status:** ⚠️ LOW RISK
- Developer tool unlikely to generate violent content
- Code examples could theoretically describe violent scenarios
- **Action**: None required, covered by 17+ age rating

#### 8.3 Sexual/Adult Content
**Status:** ⚠️ LOW RISK
- AI could generate inappropriate code examples or comments
- No explicit adult content features
- **Action**: 17+ age rating recommended

#### 8.4 Illegal Activities
**Status:** ⚠️ MODERATE RISK
- Command execution could be used for malicious purposes
- AI could generate code for illegal activities if prompted
- No app-level prevention beyond Claude AI's safeguards
- **Action Required**:
  - Terms of Service prohibiting illegal use
  - Warning in UI about user responsibility for commands

#### 8.5 Malware/Malicious Code
**Status:** ⚠️ MODERATE RISK
- App displays and can execute code without sandboxing
- User could generate malicious scripts via AI
- Command history feature stores executed commands
- **Action Required**:
  - Prominent disclaimer about code execution risks
  - User confirmation for command execution
  - Clear indication of what commands will do

#### 8.6 Harassment/Bullying
**Status:** ✅ LOW RISK
- Single-user app (no multi-user interaction)
- Cannot target other users
- **Action**: None required

#### 8.7 Privacy Violations
**Status:** ⚠️ MODERATE RISK
- App accesses file system (could read sensitive files)
- No file content filtering
- Command execution could access private data
- **Action Required**:
  - Privacy policy explaining file access
  - User responsibility disclaimer

---

## 9. Additional Compliance Considerations

### 9.1 Encryption Export Compliance
**Current State:** Info.plist declares `ITSAppUsesNonExemptEncryption = false`

**Review Required:**
- WebSocket communication may use SSL/TLS (standard encryption)
- If using https:// or wss://, this may need to be `true`
- Standard encryption is typically exempt, but declaration must be accurate

**Recommendation:** Verify encryption usage in backend communication and update if necessary.

### 9.2 Background Modes
**Current State:** Audio background mode enabled

**Purpose:** Allows voice input/output to continue in background
**Compliance:** ✅ Legitimate use case

### 9.3 Data Retention
**Current State:**
- Conversation history: Indefinite (until user deletes)
- Command history: 7 days (per `commands_history.clj`)
- Session files: Indefinite (at `~/.claude/projects/`)

**Recommendation:** Document retention policy in Privacy Policy

### 9.4 Third-Party Services
**Services Used:**
- **Anthropic Claude AI**: Primary AI provider
- **Apple Speech Recognition**: Voice transcription
- **User's own backend**: WebSocket server

**Compliance Requirements:**
- Must disclose Claude AI usage in Privacy Policy
- Must ensure compliance with Anthropic's Terms of Service
- User's backend is their own responsibility (document this)

---

## 10. App Store Metadata Recommendations

### 10.1 Age Rating
**Recommended:** 17+

**Rationale:**
- Unrestricted web access (Claude AI)
- Unfiltered AI content
- Developer tool with command execution
- No content moderation

**Rating Questionnaire Answers:**
- Alcohol, Tobacco, or Drug Use: None
- Contests: None
- Gambling: None
- Horror/Fear Themes: None (Infrequent/Mild for code errors)
- Medical/Treatment Information: None
- Profanity or Crude Humor: Infrequent/Mild (possible in AI responses)
- Sexual Content or Nudity: None
- Unrestricted Web Access: **YES** (Claude AI API)
- Violence: None
- Mature/Suggestive Themes: None

### 10.2 App Category
**Primary:** Developer Tools
**Secondary:** Productivity

### 10.3 Content Description
Ensure App Store description clearly states:
- "Professional developer tool for software engineers"
- "Requires technical knowledge to use"
- "Users are responsible for validating AI-generated code"
- "Executes commands on your behalf - use with caution"

---

## Critical Action Items Summary

### BLOCKERS (Must complete before submission):

1. **Create Privacy Policy** ✅ REQUIRED
   - Cover all data collection practices
   - Include third-party services (Anthropic)
   - Address children's privacy (COPPA)
   - Provide contact information
   - Host on accessible URL

2. **Create Terms of Service** ✅ REQUIRED
   - Acceptable use policy
   - Age restrictions (17+)
   - Liability disclaimers
   - AI output accuracy disclaimer
   - Command execution warnings

3. **Add Legal Links to App** ✅ REQUIRED
   - Settings view must link to Privacy Policy
   - Settings view must link to Terms of Service
   - Consider first-launch acceptance screen

4. **App Store Connect Metadata** ✅ REQUIRED
   - Add Privacy Policy URL
   - Complete Privacy Nutrition Labels
   - Set age rating to 17+
   - Add appropriate content descriptors

### HIGH PRIORITY (Strongly recommended):

5. **User Responsibility Disclaimers**
   - Warning before executing commands
   - Disclaimer about AI-generated code accuracy
   - Notice about file system access

6. **Enhanced Command Safety**
   - Preview commands before execution
   - Confirmation for potentially destructive operations
   - Clear indication of working directory

7. **Encryption Compliance**
   - Verify SSL/TLS usage in backend communication
   - Update Info.plist encryption declaration if needed
   - Export compliance documentation

### MODERATE PRIORITY (Quality improvements):

8. **Basic Input Validation**
   - Character limits on prompts
   - Reject empty/whitespace-only inputs
   - Basic profanity filter (optional)

9. **Logging for Safety**
   - Log prompts that trigger Claude safety responses
   - Error tracking for failed commands
   - Audit trail for data export operations

10. **User Controls**
    - Session data export feature (already implemented ✅)
    - Session deletion (already implemented ✅)
    - Clear all data option
    - Account deletion process (if applicable)

---

## Risk Assessment Matrix

| Category | Risk Level | Impact | Probability | Mitigation Status |
|----------|-----------|--------|-------------|-------------------|
| UGC Moderation | MEDIUM | HIGH | MEDIUM | ⚠️ Needs Attention |
| Missing Privacy Policy | CRITICAL | HIGH | CERTAIN | ❌ Not Started |
| Missing Terms of Service | CRITICAL | HIGH | CERTAIN | ❌ Not Started |
| COPPA Compliance | MEDIUM | MEDIUM | LOW | ⚠️ Set age 17+ |
| Content Filtering | MEDIUM | MEDIUM | MEDIUM | ⚠️ Rely on Claude AI |
| Command Execution Safety | MEDIUM | HIGH | MEDIUM | ⚠️ Add warnings |
| Encryption Export | LOW | LOW | LOW | ⚠️ Verify declaration |
| Third-Party AI | LOW | MEDIUM | LOW | ⚠️ Document in policy |

---

## Timeline Recommendations

**Before Submission (Critical Path):**
- Week 1: Draft Privacy Policy and Terms of Service
- Week 1: Review with legal counsel (recommended)
- Week 2: Implement in-app legal links
- Week 2: Add user disclaimers/warnings
- Week 2: Complete App Store Connect metadata
- Week 3: Final testing and compliance verification
- Week 4: Submit for App Review

**Estimated Effort:**
- Privacy Policy creation: 8-16 hours (including legal review)
- Terms of Service creation: 8-16 hours (including legal review)
- UI implementation (legal links, warnings): 4-8 hours
- Testing and documentation: 4-8 hours
- **Total: 24-48 hours of work**

---

## Conclusion

The voice-code app is a sophisticated developer tool that does not inherently violate Apple's content policies. However, it currently lacks essential legal documentation (Privacy Policy and Terms of Service) that are mandatory for App Store approval.

**Key Strengths:**
- No gambling, medical claims, or inappropriate content features
- Single-user app (no UGC sharing or social features)
- Legitimate developer tool use case
- Claude AI provides baseline content safety

**Critical Gaps:**
- No Privacy Policy (BLOCKER)
- No Terms of Service (BLOCKER)
- No in-app legal links
- No content moderation strategy
- Incomplete encryption export compliance

**Recommended Path Forward:**
1. Create comprehensive Privacy Policy and Terms of Service
2. Add legal documentation links to Settings view
3. Set age rating to 17+
4. Add user responsibility disclaimers for commands and AI content
5. Complete App Store Connect privacy labels accurately
6. Consider legal counsel review before submission

**Approval Likelihood:**
- With legal documentation: HIGH (85%+)
- Without legal documentation: REJECTION (100%)

The app's technical implementation is sound, but legal compliance documentation is essential for App Store approval. Prioritize Privacy Policy and Terms of Service creation immediately.

---

## References

- [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- Section 1.2: User-Generated Content
- Section 1.3: Kids Category
- Section 5.1.1: Privacy - Data Collection and Storage
- [COPPA Compliance Guide](https://www.ftc.gov/business-guidance/resources/complying-coppa-frequently-asked-questions)
- [Apple Privacy Requirements](https://developer.apple.com/app-store/app-privacy-details/)

**Document Version:** 1.0
**Last Updated:** 2025-11-08
**Next Review:** Before App Store submission
