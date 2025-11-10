# File Sharing Feature Design

## Overview
Enable users to share any file from iPhone (Settings, Mail, Files, etc.) to Untethered app, making files accessible to Claude sessions through a minimal-touch interface optimized for voice/driving scenarios.

## Key Design Decisions

### Global Storage (Not Project-Specific)
Resources are stored in a **single global location**, not per-project:
- Default location: User's default working directory from AppSettings
- Path: `<resource-storage-location>/.untethered/resources/`
- User can configure storage location in Settings
- All resources are accessible to any Claude session regardless of project
- Simplifies management and avoids duplicate uploads across projects

### Resource List Loading
- `list_resources` is called **when user navigates to Resources view**
- Not automatically sent on connection (unlike `recent_sessions`)
- Reduces unnecessary network traffic
- Resources view shows loading state while fetching

### File Path Format in Prompts
When sharing a resource with a session, use **absolute path** for clarity:
```
A file has been shared: /Users/user/project/.untethered/resources/crash.ips

[optional user message]
```
This is clearer for AI agents than relative paths.

## User Flow

### 1. Share File to Untethered
**Trigger:** User taps Share button in any iOS app
**Action:**
- iOS share sheet appears
- User selects "Untethered"
- Share Extension saves file to App Group container
- Shows confirmation: "Saved [filename] - will upload when app opens"
- User returns to originating app
- Next time main app launches: processes pending uploads in background
- Once uploaded: notification or badge update (optional)

### 2. Access Resources in Untethered
**Location:** Home page (DirectoryListView)
**UI Elements:**
- New "Resources" section (alongside Directories/Recent sections)
- Shows list of uploaded files
- Each file shows: filename, file size, upload timestamp
- Sorted by most recent first
- Swipe to delete (with confirmation)

### 3. Share Resource with Session
**Flow:**
- Tap resource → Navigate to recent sessions list
- Recent sessions shown using existing user config limit
- Tap session → Message compose screen
- Optional text/voice input field (can be empty)
- "Share" button sends notification to session

**Message sent to backend:**
```json
{
  "type": "prompt",
  "session_id": "abc-123",
  "text": "A file has been shared: /Users/user/project/.untethered/resources/crash.ips\n\n[optional user message if provided]"
}
```
Note: Uses absolute path for clarity to AI agent.

### 4. Delete Resource
**Trigger:** Swipe left on resource → Delete button
**Action:**
- Show confirmation: "Delete [filename] from backend storage?"
- If confirmed: Send delete request to backend
- Backend deletes file from `~/.untethered/resources/`
- Frontend removes from resources list

## Backend Implementation

### Storage Location
**Path:** `<resource-storage-location>/.untethered/resources/`

**Configuration:**
- **Global storage** (not per-project)
- Default: User's default working directory from AppSettings
- User can change in Settings → Resource Storage Location
- Path stored in AppSettings as `resourceStorageLocation`
- All Claude sessions can access all resources regardless of their working directory

### Share Extension Architecture

**Key Constraint:** Share Extensions have limited lifecycle and cannot perform long-running network operations directly.

**Solution:** Two-stage upload process:
1. **Share Extension (immediate):** Save file to App Group shared container
2. **Main App (deferred):** Process pending uploads when app launches/resumes

**Why this approach:**
- Share Extensions must complete quickly (system enforces time limits)
- Network requests in extensions are unreliable (may be terminated mid-upload)
- App Group provides persistent storage accessible to both extension and main app
- Main app can use background URLSession for reliable uploads
- User gets immediate feedback without waiting for network

**Implementation Details:**
- Share Extension writes to: `group.com.travisbrown.untethered/pending-uploads/`
- Each pending upload: `<uuid>.json` (metadata) + `<uuid>.data` (file contents)
- Main app checks pending uploads on:
  - App launch
  - App enters foreground (user returns from share sheet)
  - WebSocket connection established
- Failed uploads remain in queue for retry
- Successful uploads removed from App Group storage

### WebSocket Protocol

#### Upload File (Client → Backend)
```json
{
  "type": "upload_file",
  "filename": "crash.ips",
  "content": "<base64-encoded-file-content>",
  "working_directory": "/Users/user/project"
}
```

**Backend Response:**
```json
{
  "type": "file_uploaded",
  "filename": "crash.ips",
  "path": "/Users/user/project/.untethered/resources/crash.ips",
  "size": 12345,
  "timestamp": "2025-11-10T10:30:00Z"
}
```

**Error Response:**
```json
{
  "type": "error",
  "message": "Failed to upload file: [error details]"
}
```

#### List Resources (Client → Backend)
**When called:** User navigates to Resources view (on-demand, not automatic on connection)

```json
{
  "type": "list_resources",
  "working_directory": "/Users/user/project"
}
```

Note: `working_directory` parameter will be removed once global storage is implemented. For now, pass the user's configured resource storage location.

**Backend Response:**
```json
{
  "type": "resources_list",
  "resources": [
    {
      "filename": "crash.ips",
      "path": ".untethered/resources/crash.ips",
      "size": 12345,
      "timestamp": "2025-11-10T10:30:00Z"
    },
    {
      "filename": "screenshot.png",
      "path": ".untethered/resources/screenshot.png",
      "size": 67890,
      "timestamp": "2025-11-09T15:20:00Z"
    }
  ],
  "working_directory": "/Users/user/project"
}
```

#### Delete Resource (Client → Backend)
```json
{
  "type": "delete_resource",
  "filename": "crash.ips",
  "working_directory": "/Users/user/project"
}
```

**Backend Response:**
```json
{
  "type": "resource_deleted",
  "filename": "crash.ips",
  "path": "/Users/user/project/.untethered/resources/crash.ips"
}
```

**Error Response:**
```json
{
  "type": "error",
  "message": "Failed to delete resource: [error details]"
}
```

### Backend Message Handlers

**File Upload Handler:**
1. Validate `filename` and `working_directory` present
2. Decode base64 content
3. Ensure `.untethered/resources/` directory exists
4. Handle filename conflicts:
   - If file exists, append timestamp: `crash-20251110103000.ips`
   - Return actual filename used in response
5. Write file to disk
6. Return success response with metadata

**List Resources Handler:**
1. Validate `working_directory` present
2. Check if `.untethered/resources/` exists
3. List all files in directory
4. Collect metadata (filename, size, modification timestamp)
5. Sort by timestamp descending (most recent first)
6. Return resources list

**Delete Resource Handler:**
1. Validate `filename` and `working_directory` present
2. Construct full path: `<working-directory>/.untethered/resources/<filename>`
3. Verify file exists
4. Delete file from filesystem
5. Return success response

**Error Handling:**
- Missing required fields → `{type: "error", message: "..."}`
- File I/O errors → `{type: "error", message: "..."}`
- Invalid base64 → `{type: "error", message: "Invalid file content"}`

## iOS Frontend Implementation

### New Components

#### 1. Share Extension Target
**Name:** `UntetheredShareExtension`
**Capabilities:**
- Appears in iOS share sheet as "Untethered"
- Accepts all file types (no UTI restrictions for MVP)
- Extracts file data and metadata
- Communicates with main app via App Group

**App Group:**
- Identifier: `group.com.travisbrown.untethered`
- Shares data between Share Extension and main app
- Used for pending uploads queue

**Share Extension Flow:**
1. User selects "Untethered" from share sheet
2. Extension receives file URL
3. Reads file data into memory
4. Stores in App Group shared container:
   ```
   group.com.travisbrown.untethered/pending-uploads/
   - <uuid>.json (metadata: filename, size, timestamp)
   - <uuid>.data (file contents)
   ```
5. Shows alert: "Uploaded [filename] to Untethered"
6. Extension completes, returns to originating app

**Metadata JSON:**
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "filename": "crash.ips",
  "size": 12345,
  "timestamp": "2025-11-10T10:30:00Z"
}
```

#### 2. ResourcesManager
**Responsibilities:**
- Process pending uploads from App Group
- Send `upload_file` messages to backend via WebSocket
- Maintain local cache of resources list
- Handle delete operations

**State:**
```swift
@Published var resources: [Resource] = []
@Published var isLoading: Bool = false
```

**Methods:**
```swift
func processPendingUploads()  // Called on app launch
func listResources(workingDirectory: String)
func deleteResource(_ resource: Resource, workingDirectory: String)
func shareResource(_ resource: Resource, toSession sessionId: String, message: String?)
```

**Processing Pending Uploads:**
1. On app launch, check App Group container for pending uploads
2. For each pending upload:
   - Read metadata and file data
   - Send `upload_file` WebSocket message
   - Wait for `file_uploaded` response
   - Delete from pending queue
   - Update resources cache
3. If upload fails, keep in pending queue for retry

#### 3. Resource Model
```swift
struct Resource: Identifiable, Codable {
    let id: UUID
    let filename: String
    let path: String  // Relative path: .untethered/resources/filename
    let size: Int64
    let timestamp: Date

    init(json: [String: Any]) {
        // Parse from backend JSON
    }
}
```

#### 4. ResourcesView
**Location:** New section in DirectoryListView (home page)

**UI Structure:**
```
Resources (Header)
├── Resource Row 1: crash.ips (12 KB, 2 min ago)
├── Resource Row 2: screenshot.png (68 KB, 1 day ago)
└── Resource Row 3: log.txt (5 KB, 2 days ago)
```

**Row UI:**
- Leading: File icon (SF Symbol based on extension)
- Title: Filename
- Subtitle: Size + relative timestamp ("2 min ago", "1 day ago")
- Trailing: Chevron
- Swipe actions: Delete (red, with confirmation)

**Navigation:**
- Tap row → Navigate to ResourceSessionPickerView

#### 5. ResourceSessionPickerView
**Purpose:** Select which session to share resource with

**UI:**
- Navigation title: resource filename
- List of recent sessions (using existing recent sessions data)
- Session limit: uses user's configured `recentSessionsLimit`
- Each row shows: session name, working directory, last modified
- Tap session → Navigate to ResourceShareView

#### 6. ResourceShareView
**Purpose:** Compose optional message and send to session

**UI:**
- Navigation title: "Share [filename]"
- Section 1: File info (readonly)
  - Filename
  - Size
  - Location: `.untethered/resources/[filename]`
- Section 2: Message (optional)
  - Text field / voice input
  - Placeholder: "Optional message to Claude..."
- Footer button: "Share" (primary action)

**Share Action:**
1. Construct prompt text:
   ```
   A file has been shared: .untethered/resources/[filename]

   [User message if provided]
   ```
2. Send via existing `sendPrompt()` logic
3. Show confirmation toast
4. Navigate back to home (pop to root)

#### 7. Settings Integration
**New Settings Section:** Resource Storage

**Fields:**
- **Storage Location:** Text field (default: user's default working directory)
  - Helper text: "Resources will be stored in <location>/.untethered/resources/"
  - Validation: must be absolute path
- **Clear All Resources:** Button (red, destructive)
  - Shows confirmation: "Delete all resources from backend?"
  - Sends delete for each resource
  - Clears local cache

### VoiceCodeClient Changes

**New WebSocket Message Handlers:**

```swift
// Send messages
func uploadFile(filename: String, content: Data, workingDirectory: String)
func listResources(workingDirectory: String)
func deleteResource(filename: String, workingDirectory: String)

// Receive handlers
case "file_uploaded":
    // Update ResourcesManager cache

case "resources_list":
    // Update ResourcesManager.resources

case "resource_deleted":
    // Remove from ResourcesManager cache
```

**Message Encoding:**
```swift
func uploadFile(filename: String, content: Data, workingDirectory: String) {
    let base64Content = content.base64EncodedString()
    let message: [String: Any] = [
        "type": "upload_file",
        "filename": filename,
        "content": base64Content,
        "working_directory": workingDirectory
    ]
    sendMessage(message)
}
```

### CoreData Integration

**New Entity: CDResource**
```swift
@Entity
class CDResource: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var filename: String
    @NSManaged var path: String
    @NSManaged var size: Int64
    @NSManaged var timestamp: Date
}
```

**Purpose:**
- Cache resources list locally
- Enables offline viewing
- Synced with backend on connection

**PersistenceController Methods:**
```swift
func saveResource(_ resource: Resource)
func deleteResource(_ resource: Resource)
func fetchResources() -> [Resource]
```

### Navigation Changes

**DirectoryListView:**
- Add new "Resources" section after "Recent" section
- Shows resources count badge
- Tap "Resources" header → Shows full list (or inline if < 5 resources)

**Navigation Stack:**
```
DirectoryListView (Home)
└── Tap Resource
    └── ResourceSessionPickerView
        └── Tap Session
            └── ResourceShareView
                └── Tap Share
                    └── ConversationView (with prompt sent)
```

## Backend Implementation Details

### Clojure Namespace: `voice-code.resources`

**Functions:**

```clojure
(defn ensure-resources-directory!
  "Ensures .untethered/resources directory exists in working directory"
  [working-directory]
  ...)

(defn upload-file!
  "Writes base64-encoded file to resources directory"
  [working-directory filename base64-content]
  ;; Returns: {:path "..." :size N :timestamp "..."}
  ...)

(defn list-resources
  "Lists all files in resources directory with metadata"
  [working-directory]
  ;; Returns: [{:filename "..." :path "..." :size N :timestamp "..."} ...]
  ...)

(defn delete-resource!
  "Deletes a resource file from backend storage"
  [working-directory filename]
  ;; Returns: {:deleted true :path "..."}
  ...)

(defn handle-filename-conflict
  "Appends timestamp if filename already exists"
  [working-directory filename]
  ;; Returns: unique filename
  ...)
```

**WebSocket Handler Updates:**

Add to `voice-code.websocket/handle-message` multimethod:

```clojure
(defmethod handle-message "upload_file"
  [{:keys [filename content working-directory]} channel]
  (try
    (let [result (resources/upload-file! working-directory filename content)]
      (send-message channel {:type "file_uploaded"
                            :filename (:filename result)
                            :path (:path result)
                            :size (:size result)
                            :timestamp (:timestamp result)}))
    (catch Exception e
      (send-error channel (str "Failed to upload file: " (.getMessage e))))))

(defmethod handle-message "list_resources"
  [{:keys [working-directory]} channel]
  (try
    (let [resources (resources/list-resources working-directory)]
      (send-message channel {:type "resources_list"
                            :resources resources
                            :working-directory working-directory}))
    (catch Exception e
      (send-error channel (str "Failed to list resources: " (.getMessage e))))))

(defmethod handle-message "delete_resource"
  [{:keys [filename working-directory]} channel]
  (try
    (let [result (resources/delete-resource! working-directory filename)]
      (send-message channel {:type "resource_deleted"
                            :filename filename
                            :path (:path result)}))
    (catch Exception e
      (send-error channel (str "Failed to delete resource: " (.getMessage e))))))
```

**File I/O:**

```clojure
(require '[clojure.java.io :as io])
(import '[java.util Base64])

(defn upload-file! [working-directory filename base64-content]
  (let [resources-dir (io/file working-directory ".untethered" "resources")
        _ (.mkdirs resources-dir)
        unique-filename (handle-filename-conflict working-directory filename)
        target-file (io/file resources-dir unique-filename)
        decoded-bytes (.decode (Base64/getDecoder) base64-content)]
    (with-open [out (io/output-stream target-file)]
      (.write out decoded-bytes))
    {:filename unique-filename
     :path (str ".untethered/resources/" unique-filename)
     :size (.length target-file)
     :timestamp (java.time.Instant/now)}))

(defn list-resources [working-directory]
  (let [resources-dir (io/file working-directory ".untethered" "resources")]
    (if (.exists resources-dir)
      (->> (.listFiles resources-dir)
           (filter #(.isFile %))
           (map (fn [f]
                  {:filename (.getName f)
                   :path (str ".untethered/resources/" (.getName f))
                   :size (.length f)
                   :timestamp (java.time.Instant/ofEpochMilli (.lastModified f))}))
           (sort-by :timestamp #(compare %2 %1)))  ;; Most recent first
      [])))

(defn delete-resource! [working-directory filename]
  (let [target-file (io/file working-directory ".untethered" "resources" filename)]
    (if (.exists target-file)
      (do
        (.delete target-file)
        {:deleted true
         :path (str working-directory "/.untethered/resources/" filename)})
      (throw (ex-info "Resource not found" {:filename filename})))))

(defn handle-filename-conflict [working-directory filename]
  (let [target-file (io/file working-directory ".untethered" "resources" filename)]
    (if (.exists target-file)
      (let [timestamp (-> (java.time.Instant/now)
                         (.toString)
                         (clojure.string/replace #"[:\-.]" "")
                         (subs 0 14))  ;; YYYYMMDDHHmmss
            [name ext] (split-filename filename)]
        (str name "-" timestamp (when ext (str "." ext))))
      filename)))

(defn split-filename [filename]
  (let [last-dot (.lastIndexOf filename ".")]
    (if (pos? last-dot)
      [(.substring filename 0 last-dot)
       (.substring filename (inc last-dot))]
      [filename nil])))
```

## Testing Requirements

### iOS Unit Tests

**ResourcesManagerTests.swift:**
- Test pending upload processing
- Test upload retry on failure
- Test resources list caching
- Test delete operations

**ShareExtensionTests.swift:**
- Test file data extraction
- Test App Group storage
- Test metadata JSON generation

**ResourcesViewTests.swift:**
- Test resources list rendering
- Test delete confirmation flow
- Test navigation to session picker

**ResourceShareViewTests.swift:**
- Test prompt construction
- Test with/without user message
- Test navigation after share

### Backend Unit Tests

**voice_code.resources_test.clj:**
- Test file upload with valid base64
- Test file upload with invalid base64
- Test filename conflict resolution
- Test list resources (empty, multiple files)
- Test delete existing resource
- Test delete non-existent resource

### Integration Tests

**File Upload Flow:**
1. Share Extension saves to App Group
2. Main app processes pending upload
3. Backend receives upload_file message
4. File written to disk
5. Frontend receives file_uploaded confirmation
6. Resources list updated

**Delete Flow:**
1. User swipes to delete
2. Confirmation shown
3. delete_resource message sent
4. Backend deletes file
5. resource_deleted confirmation
6. Frontend updates list

**Share with Session Flow:**
1. User selects resource
2. Picks recent session
3. Enters optional message
4. Prompt sent to backend
5. Claude receives notification
6. Claude can read file via normal file tools

## Security Considerations

**MVP (Current):**
- No file type restrictions
- No file size limits
- No authentication beyond existing WebSocket connection
- Files stored in plain text

**Future Enhancements (Deferred):**
- File size limits (10MB suggested)
- File type validation
- Malware scanning for executables
- Encryption at rest
- Per-user quotas

## File Naming Conventions

**iOS (Swift):**
- Classes: `ResourcesManager`, `ResourcesView`, `ResourceSessionPickerView`
- Models: `Resource`, `CDResource`
- Files: `ResourcesManager.swift`, `ResourcesView.swift`

**Backend (Clojure):**
- Namespace: `voice-code.resources`
- File: `backend/src/voice_code/resources.clj`
- Test: `backend/test/voice_code/resources_test.clj`

**WebSocket Messages:**
- snake_case: `upload_file`, `list_resources`, `delete_resource`, `file_uploaded`

## Implementation Order

### Phase 1: Backend Foundation
1. Create `voice-code.resources` namespace
2. Implement file upload/list/delete functions
3. Add WebSocket message handlers
4. Write unit tests

### Phase 2: iOS Share Extension
1. Create Share Extension target
2. Configure App Group
3. Implement file extraction and storage
4. Test share flow from Settings app

### Phase 3: iOS Resources Management
1. Create `ResourcesManager` and `Resource` model
2. Implement pending upload processing
3. Add CoreData entity and persistence
4. Write unit tests

### Phase 4: iOS UI
1. Create `ResourcesView` in DirectoryListView
2. Implement `ResourceSessionPickerView`
3. Implement `ResourceShareView`
4. Add Settings integration
5. Wire up navigation
6. Write UI tests

### Phase 5: Integration Testing
1. Test end-to-end upload flow
2. Test session sharing flow
3. Test delete flow
4. Test error handling
5. Test with various file types

### Phase 6: Documentation
1. Update STANDARDS.md with WebSocket protocol additions
2. Update README with resources feature
3. Add user-facing documentation

## Resolved Design Decisions

1. **Storage scope:** ✅ Global storage (single location for all resources, not per-project)
2. **Resource list loading:** ✅ On-demand when user opens Resources view (not automatic)
3. **File path format:** ✅ Absolute paths in prompts (clearer for AI agents)
4. **Share Extension upload:** ✅ Two-stage process (App Group → Main App → Backend)
5. **Offline support:** ✅ Yes, cached in CoreData
6. **Testing approach:** ✅ Test-driven development (write tests alongside implementation)

## Open Questions / Deferred Decisions

1. **File size limits:** Deferred - implement when needed (no hard limit for MVP)
2. **File retention policy:** Keep permanently for MVP (no auto-cleanup)
3. **Upload progress UI:** Basic feedback only ("Saved, will upload when app opens")
4. **Resource preview:** Deferred - MVP just shows metadata (filename, size, timestamp)
5. **Upload retry strategy:** Simple - keep in queue until successful, retry on app launch/foreground
