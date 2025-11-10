# Resources Feature - Manual Integration Testing

This document describes manual integration tests for the Resources feature that validate the full Swift → WebSocket → Clojure stack.

## Why Manual Testing?

While we have comprehensive automated tests, manual integration tests are valuable for:

1. **End-to-end validation**: Testing the actual WebSocket protocol between layers
2. **Visual inspection**: Seeing files created on disk to verify behavior
3. **Debugging**: Interactive testing when something goes wrong
4. **Documentation**: Executable examples of how the protocol works

## Quick Start

### 1. Start the Backend Server

```bash
make backend-run
```

Leave this running in a separate terminal.

### 2. Run the Manual Integration Test

```bash
make backend-test-manual-resources
```

This will:
- Connect to the WebSocket server
- Test upload, list, delete operations
- Create test files in `~/Desktop/voice-code-resources-manual-test/`
- Display all WebSocket messages sent and received
- Prompt you to inspect files before cleanup

### 3. What Gets Tested

The manual test validates:

**Upload Operations:**
- ✓ Upload single file
- ✓ Upload multiple files
- ✓ Handle filename conflicts (timestamp appending)
- ✓ Path traversal protection
- ✓ Base64 encoding/decoding

**List Operations:**
- ✓ List empty directory
- ✓ List multiple files
- ✓ Metadata accuracy (filename, path, size, timestamp)
- ✓ Sorting by timestamp (most recent first)

**Delete Operations:**
- ✓ Delete existing file
- ✓ Error handling for non-existent files
- ✓ Filesystem verification after deletion

**Protocol Validation:**
- ✓ WebSocket connection
- ✓ Message format (snake_case JSON)
- ✓ Error responses
- ✓ Response timing

## Test Output

The test outputs color-coded WebSocket messages:

```
=== STEP 3: Upload File ===

→ Sending: {
  "type" : "upload_file",
  "filename" : "test-resource.txt",
  "content" : "VGhpcyBpcyBhIHRlc3QgcmVzb3VyY2UgZmlsZQ==",
  "storage_location" : "/Users/you/Desktop/voice-code-resources-manual-test"
}

← Received: {
  "type" : "file_uploaded",
  "filename" : "test-resource.txt",
  "path" : ".untethered/resources/test-resource.txt",
  "size" : 42,
  "timestamp" : "2025-11-10T14:30:00.123Z"
}

✓ File uploaded successfully
```

## Manual Inspection

When the test pauses, you can inspect the files:

```bash
# View test directory structure
tree ~/Desktop/voice-code-resources-manual-test/

# Read uploaded files
cat ~/Desktop/voice-code-resources-manual-test/.untethered/resources/test-resource.txt

# Check file metadata
ls -lah ~/Desktop/voice-code-resources-manual-test/.untethered/resources/
```

Press Enter when done to cleanup.

## Testing with iOS Simulator

For true end-to-end testing with the iOS app:

### 1. Start Backend
```bash
make backend-run
```

### 2. Update iOS App Settings

In the iOS Simulator:
1. Open VoiceCode app
2. Go to Settings
3. Set "Backend URL" to `ws://localhost:8080`
4. Set "Resource Storage Location" to a test directory (e.g., `~/Desktop/ios-resources-test`)

### 3. Manual Test Flow

**A. Upload via Share Extension:**
1. Open Files app in Simulator
2. Long-press a file → Share
3. Select "Untethered"
4. Switch to VoiceCode app (triggers upload processing)
5. Check backend logs for upload confirmation

**B. View Resources:**
1. Open VoiceCode app
2. Navigate to Resources section
3. Verify files are listed with correct metadata

**C. Share with Session:**
1. Tap a resource
2. Select a recent session
3. Add optional message
4. Tap "Share"
5. Check session conversation for the prompt

**D. Delete Resource:**
1. Swipe left on a resource
2. Tap "Delete"
3. Confirm deletion
4. Verify file removed from filesystem

**E. Verify on Filesystem:**
```bash
# Check actual files on disk
ls -la ~/Desktop/ios-resources-test/.untethered/resources/

# Watch backend logs
tail -f backend/server.log
```

## Common Issues

### WebSocket Connection Failed
- Ensure backend is running: `make backend-run`
- Check no firewall blocking port 8080
- Verify URL is `ws://localhost:8080` (not `wss://`)

### Files Not Appearing
- Check storage location in test output
- Verify `.untethered/resources/` subdirectory created
- Check backend logs for upload errors

### Test Hangs
- Press Ctrl+C to abort
- Cleanup manually: `rm -rf ~/Desktop/voice-code-resources-manual-test/`

## Automated Tests vs Manual Tests

**Automated Tests (`backend/test/voice_code/resources_integration_test.clj`):**
- Fast (no human interaction)
- Run in temp directories (auto cleanup)
- Part of CI/CD pipeline
- Mock WebSocket connections

**Manual Tests (`backend/test/manual_test/voice_code/test_resources_integration.clj`):**
- Slower (human inspection)
- Create visible files (Desktop)
- Not in CI/CD
- Real WebSocket connections
- Interactive debugging

Use manual tests when developing new features or debugging issues. Use automated tests for regression prevention.

## Adding New Manual Tests

To add a new manual test scenario:

1. **Edit the test file:**
   ```clojure
   ;; backend/test/manual_test/voice_code/test_resources_integration.clj

   (testing "New scenario description"
     (println "\n=== STEP N: New Test ===")
     (reset! received-messages [])

     ;; Send message
     (send-message! @socket {:type "..."})
     (Thread/sleep 500)

     ;; Verify response
     (let [response (first @received-messages)]
       (is (= "expected_type" (:type response)))
       (println "✓ New test passed")))
   ```

2. **Run the updated test:**
   ```bash
   make backend-test-manual-resources
   ```

3. **Document in this file** if the scenario is valuable for others

## Related Documentation

- Design doc: `RESOURCES_DESIGN.md`
- WebSocket protocol: `STANDARDS.md` (WebSocket Protocol section)
- Automated tests: `backend/test/voice_code/resources_integration_test.clj`
- iOS tests: `ios/VoiceCodeTests/Resources*Tests.swift`
