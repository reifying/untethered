# API Key Authentication Design

## 1. Overview

### Problem Statement
The voice-code WebSocket protocol currently has no authentication. Anyone who knows the backend IP and port can connect and access all sessions, execute commands, and invoke Claude. While Tailscale provides network-level encryption, it doesn't authenticate the application itself.

### Goals
- Authenticate iOS app to backend using a pre-shared key (PSK)
- Store keys securely on both ends (filesystem permissions + Keychain)
- Provide user-friendly pairing flow (QR code + manual entry)
- Reject all unauthenticated requests

### Non-Goals
- Multi-user support (single user only)
- Token refresh/rotation (manual key regeneration only)
- TLS at application layer (Tailscale handles encryption)
- Rate limiting (out of scope for initial implementation)

## 2. Background & Context

### Current State
- Backend listens on `ws://0.0.0.0:8080` (configurable)
- iOS connects via WebSocket, sends `connect` message
- No credentials required - immediate access to all sessions
- Tailscale encrypts traffic but doesn't verify application identity

### Why Now
Adding security before broader deployment. Currently works only on trusted Tailscale network, but defense-in-depth requires application-level auth.

### Related Work
- @STANDARDS.md - WebSocket protocol specification
- `backend/src/voice_code/server.clj` - Message handling
- `ios/VoiceCode/Managers/VoiceCodeClient.swift` - WebSocket client
- `ios/VoiceCode/Managers/AppSettings.swift` - Settings storage

## 3. Detailed Design

### 3.1 Data Model

#### API Key Format
```
voice-code-<32-random-hex-characters>
```
Example: `voice-code-a1b2c3d4e5f678901234567890ab`

- Prefix `voice-code-` for easy identification (11 characters)
- 32 hex characters = 128 bits of entropy
- Total length: 43 characters (11 + 32)

#### Backend Storage
**File:** `~/.voice-code/api-key`
```
voice-code-a1b2c3d4e5f678901234567890ab
```
- Plain text, single line
- File permissions: `chmod 600` (owner read/write only)
- Directory permissions: `chmod 700` on `~/.voice-code/`

#### iOS Storage
**Keychain item:**
- Service: `dev.910labs.voice-code`
- Account: `api-key`
- Value: The API key string
- Accessibility: `kSecAttrAccessibleAfterFirstUnlock`

### 3.2 API Design

#### Protocol Change: Authentication in Every Message

**Current message (no auth):**
```json
{
  "type": "connect"
}
```

**New message (with auth):**
```json
{
  "type": "connect",
  "api_key": "voice-code-a1b2c3d4e5f678901234567890ab"
}
```

All message types include `api_key` field. Backend validates before processing.

#### New Message Types

**Authentication Error Response:**
```json
{
  "type": "auth_error",
  "message": "Invalid or missing API key"
}
```

Backend closes WebSocket connection after sending this.

**Key Display Request (CLI only):**
```bash
# Terminal command to display key
make show-key

# Output:
API Key: voice-code-a1b2c3d4e5f678901234567890ab

# Or with QR code:
make show-key-qr
```

#### Error Cases

| Scenario | Response | Connection |
|----------|----------|------------|
| Missing `api_key` | `auth_error` | Closed |
| Invalid `api_key` | `auth_error` | Closed |
| Valid `api_key` | Normal processing | Kept open |

### 3.3 Code Examples

#### Backend: Key Generation and Storage

```clojure
(ns voice-code.auth
  "API key authentication for voice-code backend."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.tools.logging :as log])
  (:import [java.security SecureRandom]
           [java.nio.file Files]
           [java.nio.file.attribute PosixFilePermissions]))

(def ^:private key-file-path
  (str (System/getProperty "user.home") "/.voice-code/api-key"))

(defn generate-api-key
  "Generate a new API key with 128 bits of entropy."
  []
  (let [random (SecureRandom.)
        bytes (byte-array 16)]
    (.nextBytes random bytes)
    (str "voice-code-"
         (apply str (map #(format "%02x" (bit-and % 0xff)) bytes)))))

(defn ensure-key-file!
  "Ensure API key file exists with correct permissions.
  Creates new key if file doesn't exist."
  []
  (let [file (io/file key-file-path)
        parent (.getParentFile file)]
    ;; Create directory with 700 permissions
    (when-not (.exists parent)
      (.mkdirs parent)
      (let [path (.toPath parent)
            perms (PosixFilePermissions/fromString "rwx------")]
        (Files/setPosixFilePermissions path perms)))
    ;; Create key file with 600 permissions
    (when-not (.exists file)
      (let [key (generate-api-key)]
        (spit file key)
        (let [path (.toPath file)
              perms (PosixFilePermissions/fromString "rw-------")]
          (Files/setPosixFilePermissions path perms))
        (log/info "Generated new API key")))
    ;; Return the key
    (str/trim (slurp file))))

(defn read-api-key
  "Read the current API key from file."
  []
  (let [file (io/file key-file-path)]
    (when (.exists file)
      (str/trim (slurp file)))))

(defn constant-time-equals?
  "Compare two strings in constant time to prevent timing attacks."
  [^String a ^String b]
  (if (or (nil? a) (nil? b))
    false
    (let [a-bytes (.getBytes a "UTF-8")
          b-bytes (.getBytes b "UTF-8")
          len (max (alength a-bytes) (alength b-bytes))]
      (loop [i 0
             result (if (= (alength a-bytes) (alength b-bytes)) 0 1)]
        (if (>= i len)
          (zero? result)
          (let [a-byte (if (< i (alength a-bytes)) (aget a-bytes i) 0)
                b-byte (if (< i (alength b-bytes)) (aget b-bytes i) 0)]
            (recur (inc i) (bit-or result (bit-xor a-byte b-byte)))))))))

(defn validate-api-key
  "Validate an API key against the stored key.
  Returns true if valid, false otherwise."
  [provided-key]
  (when-let [stored-key (read-api-key)]
    (constant-time-equals? stored-key provided-key)))
```

#### Backend: Authentication Middleware

```clojure
;; In voice-code.server namespace

(defn authenticate-message
  "Check if message contains valid API key.
  Returns {:authenticated true} or {:authenticated false :error \"message\"}."
  [data stored-key]
  (let [provided-key (:api-key data)]
    (cond
      (nil? provided-key)
      {:authenticated false :error "Missing API key"}

      (not (auth/constant-time-equals? stored-key provided-key))
      {:authenticated false :error "Invalid API key"}

      :else
      {:authenticated true})))

;; Stored key loaded once at startup (in -main)
(defonce api-key (atom nil))

(defn handle-message
  "Handle incoming WebSocket message with authentication."
  [channel msg]
  (try
    (let [data (parse-json msg)
          auth-result (authenticate-message data @api-key)]
      (if (:authenticated auth-result)
        ;; Process message normally (existing code)
        (let [msg-type (:type data)]
          (case msg-type
            "connect" (handle-connect channel data)
            ;; ... rest of handlers
            ))
        ;; Authentication failed
        (do
          (log/warn "Authentication failed" {:error (:error auth-result)})
          (http/send! channel
                      (generate-json {:type :auth-error
                                      :message (:error auth-result)}))
          (http/close channel))))
    (catch Exception e
      ;; ... error handling
      )))
```

#### Backend: QR Code Display

```clojure
(ns voice-code.qr
  "QR code generation for API key display."
  (:require [voice-code.auth :as auth])
  (:import [com.google.zxing BarcodeFormat]
           [com.google.zxing.qrcode QRCodeWriter]
           [com.google.zxing.common BitMatrix]))

(defn generate-qr-matrix
  "Generate QR code bit matrix for the given text."
  [^String text size]
  (let [writer (QRCodeWriter.)]
    (.encode writer text BarcodeFormat/QR_CODE size size)))

(defn render-qr-terminal
  "Render QR code to terminal using Unicode block characters."
  [^BitMatrix matrix]
  (let [width (.getWidth matrix)
        height (.getHeight matrix)]
    ;; Use Unicode block characters for compact display
    ;; Top half block: ▀ (U+2580), Bottom half block: ▄ (U+2584)
    ;; Full block: █ (U+2588), Space for white
    (doseq [y (range 0 height 2)]
      (doseq [x (range width)]
        (let [top (.get matrix x y)
              bottom (if (< (inc y) height) (.get matrix x (inc y)) false)]
          (print
           (cond
             (and top bottom) "█"
             top "▀"
             bottom "▄"
             :else " "))))
      (println))))

(defn display-api-key
  "Display API key with optional QR code."
  [show-qr?]
  (let [key (auth/read-api-key)]
    (println)
    (println "╔══════════════════════════════════════════════════╗")
    (println "║            Voice-Code API Key                    ║")
    (println "╠══════════════════════════════════════════════════╣")
    (when show-qr?
      (println "║  Scan with iOS camera or paste manually:         ║")
      (println "║                                                  ║")
      (let [matrix (generate-qr-matrix key 25)]
        (render-qr-terminal matrix))
      (println "║                                                  ║"))
    (println (str "║  " key "  ║"))
    (println "╚══════════════════════════════════════════════════╝")
    (println)))
```

#### iOS: Keychain Storage

```swift
// KeychainManager.swift
import Foundation
import Security

enum KeychainError: Error {
    case duplicateItem
    case itemNotFound
    case unexpectedStatus(OSStatus)
    case invalidData
}

class KeychainManager {
    static let shared = KeychainManager()

    private let service = "dev.910labs.voice-code"
    private let account = "api-key"

    private init() {}

    /// Save API key to Keychain
    func saveAPIKey(_ key: String) throws {
        guard let data = key.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        // Try to add, if exists then update
        var status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data
            ]
            status = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Retrieve API key from Keychain
    func getAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }

        return key
    }

    /// Delete API key from Keychain
    func deleteAPIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Check if API key exists
    var hasAPIKey: Bool {
        getAPIKey() != nil
    }

    /// Validate API key format before saving
    /// Key must start with "voice-code-" and be exactly 43 characters
    func isValidAPIKeyFormat(_ key: String) -> Bool {
        key.hasPrefix("voice-code-") && key.count == 43
    }
}
```

#### iOS: Updated VoiceCodeClient

```swift
// In VoiceCodeClient.swift

class VoiceCodeClient: ObservableObject {
    // ... existing properties ...

    @Published var isAuthenticated = false
    @Published var authenticationError: String?

    private var apiKey: String? {
        KeychainManager.shared.getAPIKey()
    }

    // Updated sendMessage to include API key
    func sendMessage(_ message: [String: Any]) {
        // Inject API key into every message
        var authenticatedMessage = message
        if let key = apiKey {
            authenticatedMessage["api_key"] = key
        }

        guard let data = try? JSONSerialization.data(withJSONObject: authenticatedMessage),
              let text = String(data: data, encoding: .utf8) else {
            LogManager.shared.log("Failed to serialize message", category: "VoiceCodeClient")
            return
        }

        // ... rest of existing send logic ...
    }

    // Handle auth_error message type
    func handleMessage(_ text: String) {
        // ... existing parsing ...

        switch type {
        case "auth_error":
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isAuthenticated = false
                self.authenticationError = json["message"] as? String ?? "Authentication failed"
                self.disconnect()
            }

        case "hello":
            // If we receive hello, we're connected but not yet authenticated
            // Authentication happens on first message send
            self.sendConnectMessage()

        case "connected":
            // Successfully authenticated
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isAuthenticated = true
                self.authenticationError = nil
            }
            // ... rest of existing connected handling ...

        // ... rest of existing cases ...
        }
    }
}
```

#### iOS: Settings View for API Key Entry

```swift
// In SettingsView.swift (additions)

struct APIKeySection: View {
    @EnvironmentObject var voiceCodeClient: VoiceCodeClient
    @State private var apiKeyInput = ""
    @State private var showingScanner = false
    @State private var showingKey = false
    @State private var validationError: String?

    var body: some View {
        Section("Authentication") {
            if KeychainManager.shared.hasAPIKey {
                // Key is configured
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("API Key Configured")
                    Spacer()
                    Button("Change") {
                        showingKey = true
                    }
                }
            } else {
                // Key not configured
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("API Key Required")
                }

                TextField("Paste API key or scan QR", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()

                if let error = validationError {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }

                HStack {
                    Button("Scan QR Code") {
                        showingScanner = true
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Save Key") {
                        saveAPIKey()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKeyInput.isEmpty)
                }
            }
        }
        .sheet(isPresented: $showingScanner) {
            QRScannerView { scannedKey in
                apiKeyInput = scannedKey
                saveAPIKey()
                showingScanner = false
            }
        }
        .sheet(isPresented: $showingKey) {
            APIKeyManagementView()
        }
    }

    private func saveAPIKey() {
        validationError = nil

        // Validate key format before saving
        guard KeychainManager.shared.isValidAPIKeyFormat(apiKeyInput) else {
            validationError = "Invalid API key format. Must start with 'voice-code-' and be 43 characters."
            return
        }

        do {
            try KeychainManager.shared.saveAPIKey(apiKeyInput)
            apiKeyInput = ""
            // Trigger reconnection with new key
            voiceCodeClient.disconnect()
            voiceCodeClient.connect()
        } catch {
            validationError = "Failed to save API key: \(error.localizedDescription)"
        }
    }
}
```

#### iOS: QR Scanner View

```swift
// QRScannerView.swift
import SwiftUI
import AVFoundation

struct QRScannerView: UIViewControllerRepresentable {
    let onCodeScanned: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCodeScanned: onCodeScanned)
    }

    class Coordinator: NSObject, QRScannerViewControllerDelegate {
        let onCodeScanned: (String) -> Void

        init(onCodeScanned: @escaping (String) -> Void) {
            self.onCodeScanned = onCodeScanned
        }

        func didScanCode(_ code: String) {
            // Validate it looks like our API key before accepting
            if code.hasPrefix("voice-code-") && code.count == 43 {
                onCodeScanned(code)
            }
        }
    }
}

protocol QRScannerViewControllerDelegate: AnyObject {
    func didScanCode(_ code: String)
}

class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: QRScannerViewControllerDelegate?

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        setupCamera()
    }

    private func setupCamera() {
        let session = AVCaptureSession()

        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video),
              let videoInput = try? AVCaptureDeviceInput(device: videoCaptureDevice),
              session.canAddInput(videoInput) else {
            return
        }

        session.addInput(videoInput)

        let metadataOutput = AVCaptureMetadataOutput()
        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.qr]
        }

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = view.layer.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)

        self.captureSession = session
        self.previewLayer = previewLayer

        DispatchQueue.global(qos: .background).async {
            session.startRunning()
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let stringValue = metadataObject.stringValue else {
            return
        }

        // Stop scanning
        captureSession?.stopRunning()

        // Haptic feedback
        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))

        // Notify delegate
        delegate?.didScanCode(stringValue)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSession?.stopRunning()
    }
}
```

#### iOS: API Key Management View

```swift
// APIKeyManagementView.swift
import SwiftUI

struct APIKeyManagementView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var voiceCodeClient: VoiceCodeClient
    @State private var showDeleteConfirmation = false
    @State private var newKeyInput = ""
    @State private var validationError: String?

    var body: some View {
        NavigationView {
            Form {
                Section("Current Key") {
                    if let key = KeychainManager.shared.getAPIKey() {
                        HStack {
                            Text(maskedKey(key))
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Button {
                                UIPasteboard.general.string = key
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                        }
                    }
                }

                Section("Update Key") {
                    TextField("New API key", text: $newKeyInput)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()

                    if let error = validationError {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }

                    Button("Update Key") {
                        updateKey()
                    }
                    .disabled(newKeyInput.isEmpty)
                }

                Section {
                    Button("Delete Key", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                }
            }
            .navigationTitle("API Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Delete API Key?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    try? KeychainManager.shared.deleteAPIKey()
                    voiceCodeClient.disconnect()
                    dismiss()
                }
            } message: {
                Text("You will need to re-enter the API key to connect to the backend.")
            }
        }
    }

    private func maskedKey(_ key: String) -> String {
        // Show first 15 chars, mask rest: "voice-code-a1b2...****"
        let prefix = String(key.prefix(15))
        return "\(prefix)...****"
    }

    private func updateKey() {
        validationError = nil

        guard KeychainManager.shared.isValidAPIKeyFormat(newKeyInput) else {
            validationError = "Invalid format. Must start with 'voice-code-' and be 43 characters."
            return
        }

        do {
            try KeychainManager.shared.saveAPIKey(newKeyInput)
            newKeyInput = ""
            voiceCodeClient.disconnect()
            voiceCodeClient.connect()
            dismiss()
        } catch {
            validationError = "Failed to save: \(error.localizedDescription)"
        }
    }
}
```

### 3.4 Dependencies and Configuration

#### Backend: deps.edn Addition

Add ZXing dependency for QR code generation:

```clojure
;; In backend/deps.edn, add to :deps map:
com.google.zxing/core {:mvn/version "3.5.3"}
```

#### Backend: Makefile Targets

```makefile
# Add to Makefile

# Display API key (text only)
show-key:
	@cd backend && clojure -M -e "(require '[voice-code.auth :as auth]) (println (str \"API Key: \" (auth/read-api-key)))"

# Display API key with QR code
show-key-qr:
	@cd backend && clojure -M -e "(require '[voice-code.qr :as qr]) (qr/display-api-key true)"

# Regenerate API key (creates new key, invalidates old)
regenerate-key:
	@echo "WARNING: This will invalidate your current API key."
	@echo "You will need to re-pair your iOS device."
	@read -p "Continue? [y/N] " confirm && [ "$$confirm" = "y" ] || exit 1
	@rm -f ~/.voice-code/api-key
	@cd backend && clojure -M -e "(require '[voice-code.auth :as auth]) (auth/ensure-key-file!) (println \"New API key generated. Run 'make show-key' to display.\")"
```

#### Backend: Startup Integration

Modify `-main` in `server.clj` to initialize authentication:

```clojure
;; In voice-code.server namespace, update -main function:

(defn -main
  "Start the WebSocket server"
  [& args]
  (let [config (load-config)
        port (get-in config [:server :port] 8080)
        host (get-in config [:server :host] "0.0.0.0")]

    ;; Initialize API key (creates if missing)
    (log/info "Initializing API key authentication")
    (let [key (auth/ensure-key-file!)]
      (reset! api-key key)
      (log/info "API key loaded successfully")
      (println "✓ API key ready. Run 'make show-key' to display."))

    ;; Initialize replication system
    (log/info "Initializing session replication system")
    (repl/initialize-index!)

    ;; ... rest of existing startup code ...

    (println (format "✓ Voice-code WebSocket server running on ws://%s:%d" host port))
    (println "  Authentication: ENABLED")
    (println "  Ready for connections. Press Ctrl+C to stop.")

    @(promise)))
```

### 3.5 Share Extension Authentication

The HTTP `/upload` endpoint also requires authentication. Modify `handle-http-upload`:

```clojure
(defn handle-http-upload
  "Handle HTTP POST /upload requests with API key authentication."
  [req channel]
  (try
    (let [body (slurp (:body req))
          data (parse-json body)
          ;; Check API key first
          auth-result (authenticate-message data @api-key)]
      (if-not (:authenticated auth-result)
        ;; Authentication failed
        (http/send! channel
                    {:status 401
                     :headers {"Content-Type" "application/json"}
                     :body (generate-json
                            {:success false
                             :error (:error auth-result)})})
        ;; Authenticated - proceed with upload
        (let [filename (:filename data)
              content (:content data)
              storage-location (:storage-location data)]
          ;; ... rest of existing upload logic ...
          )))
    (catch Exception e
      ;; ... error handling ...
      )))
```

iOS Share Extension must include API key in upload request:

```swift
// In ShareViewController.swift or similar
func uploadFile(filename: String, content: Data, storageLocation: String) async throws {
    guard let apiKey = KeychainManager.shared.getAPIKey() else {
        throw ShareError.notAuthenticated
    }

    let payload: [String: Any] = [
        "api_key": apiKey,
        "filename": filename,
        "content": content.base64EncodedString(),
        "storage_location": storageLocation
    ]

    // ... make HTTP request with payload ...
}
```

### 3.6 Component Interactions

```
┌─────────────────────────────────────────────────────────────┐
│                    First-Time Setup                          │
└─────────────────────────────────────────────────────────────┘

1. Backend starts
   └─> Checks ~/.voice-code/api-key
       └─> If missing: generates key, creates file with chmod 600
       └─> Logs: "API key ready. Run 'make show-key' to display."

2. User runs: make show-key-qr
   └─> Backend displays QR code in terminal

3. iOS app opens Settings
   └─> Shows "API Key Required" warning
   └─> User taps "Scan QR Code"
   └─> Camera scans QR
   └─> Key saved to Keychain

4. iOS connects to backend
   └─> Sends: {"type": "connect", "api_key": "voice-code-..."}
   └─> Backend validates key
   └─> Sends: {"type": "connected", ...}
   └─> iOS sets isAuthenticated = true


┌─────────────────────────────────────────────────────────────┐
│                    Normal Operation                          │
└─────────────────────────────────────────────────────────────┘

iOS                                              Backend
 │                                                   │
 │  ──── WebSocket connect ────>                     │
 │                                                   │
 │  <──── {"type": "hello"} ────                     │
 │                                                   │
 │  ──── {"type": "connect",  ────>                  │
 │        "api_key": "..."}                          │
 │                                     ┌─────────────┤
 │                                     │ Validate    │
 │                                     │ api_key     │
 │                                     └─────────────┤
 │  <──── {"type": "connected"} ────                 │
 │                                                   │
 │  ──── {"type": "prompt",   ────>                  │
 │        "api_key": "...",                          │
 │        "text": "..."}                             │
 │                                     ┌─────────────┤
 │                                     │ Validate    │
 │                                     │ api_key     │
 │                                     └─────────────┤
 │  <──── {"type": "ack"} ────                       │
 │                                                   │


┌─────────────────────────────────────────────────────────────┐
│                    Authentication Failure                    │
└─────────────────────────────────────────────────────────────┘

iOS                                              Backend
 │                                                   │
 │  ──── {"type": "connect"} ────>                   │
 │        (no api_key!)                              │
 │                                     ┌─────────────┤
 │                                     │ Missing key │
 │                                     └─────────────┤
 │  <──── {"type": "auth_error",  ────               │
 │         "message": "Missing API key"}             │
 │                                                   │
 │  <──── WebSocket close ────                       │
 │                                                   │
```

## 4. Verification Strategy

### Unit Tests

#### Backend Tests (`test/voice_code/auth_test.clj`)

```clojure
(ns voice-code.auth-test
  (:require [clojure.test :refer :all]
            [clojure.string :as str]
            [clojure.java.io :as io]
            [voice-code.auth :as auth]))

(deftest generate-api-key-test
  (testing "generates key with correct format"
    (let [key (auth/generate-api-key)]
      (is (string? key))
      (is (str/starts-with? key "voice-code-"))
      (is (= 43 (count key)))))  ; "voice-code-" (11) + 32 hex chars

  (testing "generates unique keys"
    (let [keys (repeatedly 100 auth/generate-api-key)]
      (is (= 100 (count (set keys)))))))

(deftest constant-time-equals-test
  (testing "returns true for equal strings"
    (is (auth/constant-time-equals? "abc" "abc"))
    (is (auth/constant-time-equals? "voice-code-123" "voice-code-123")))

  (testing "returns false for different strings"
    (is (not (auth/constant-time-equals? "abc" "abd")))
    (is (not (auth/constant-time-equals? "abc" "ab")))
    (is (not (auth/constant-time-equals? "abc" "abcd"))))

  (testing "handles nil safely"
    (is (not (auth/constant-time-equals? nil "abc")))
    (is (not (auth/constant-time-equals? "abc" nil)))
    (is (not (auth/constant-time-equals? nil nil)))))

(deftest validate-api-key-test
  (testing "validates correct key"
    (with-redefs [auth/read-api-key (constantly "voice-code-test123")]
      (is (auth/validate-api-key "voice-code-test123"))))

  (testing "rejects incorrect key"
    (with-redefs [auth/read-api-key (constantly "voice-code-test123")]
      (is (not (auth/validate-api-key "voice-code-wrong"))))))

(deftest ensure-key-file-permissions-test
  (testing "creates key file with correct permissions"
    (let [temp-dir (str (System/getProperty "java.io.tmpdir")
                        "/voice-code-auth-test-" (System/currentTimeMillis))
          test-key-path (str temp-dir "/api-key")]
      (try
        ;; Override key-file-path for testing
        (with-redefs [auth/key-file-path test-key-path]
          (auth/ensure-key-file!)
          ;; Verify file exists
          (is (.exists (io/file test-key-path)))
          ;; Verify permissions are 600 (owner read/write only)
          (let [path (.toPath (io/file test-key-path))
                perms (java.nio.file.Files/getPosixFilePermissions path)]
            (is (= #{"OWNER_READ" "OWNER_WRITE"}
                   (set (map str perms))))))
        (finally
          ;; Cleanup
          (io/delete-file test-key-path true)
          (io/delete-file temp-dir true))))))
```

#### Backend Integration Tests (`test/voice_code/server_auth_test.clj`)

```clojure
(ns voice-code.server-auth-test
  (:require [clojure.test :refer :all]
            [voice-code.server :as server]
            [voice-code.auth :as auth]))

(deftest authenticate-message-test
  (let [stored-key "voice-code-testkey123"]

    (testing "authenticates valid key"
      (let [result (server/authenticate-message
                     {:type "connect" :api-key stored-key}
                     stored-key)]
        (is (:authenticated result))))

    (testing "rejects missing key"
      (let [result (server/authenticate-message
                     {:type "connect"}
                     stored-key)]
        (is (not (:authenticated result)))
        (is (= "Missing API key" (:error result)))))

    (testing "rejects invalid key"
      (let [result (server/authenticate-message
                     {:type "connect" :api-key "wrong-key"}
                     stored-key)]
        (is (not (:authenticated result)))
        (is (= "Invalid API key" (:error result)))))))
```

#### iOS Tests (`VoiceCodeTests/KeychainManagerTests.swift`)

```swift
import XCTest
@testable import VoiceCode

class KeychainManagerTests: XCTestCase {

    override func tearDown() {
        // Clean up after each test
        try? KeychainManager.shared.deleteAPIKey()
        super.tearDown()
    }

    func testSaveAndRetrieveAPIKey() throws {
        let testKey = "voice-code-test1234567890abcdef12345678"

        try KeychainManager.shared.saveAPIKey(testKey)

        let retrieved = KeychainManager.shared.getAPIKey()
        XCTAssertEqual(retrieved, testKey)
    }

    func testHasAPIKeyReturnsFalseWhenEmpty() {
        XCTAssertFalse(KeychainManager.shared.hasAPIKey)
    }

    func testHasAPIKeyReturnsTrueWhenSet() throws {
        try KeychainManager.shared.saveAPIKey("voice-code-test")
        XCTAssertTrue(KeychainManager.shared.hasAPIKey)
    }

    func testDeleteAPIKey() throws {
        try KeychainManager.shared.saveAPIKey("voice-code-test")
        try KeychainManager.shared.deleteAPIKey()
        XCTAssertNil(KeychainManager.shared.getAPIKey())
    }

    func testUpdateExistingKey() throws {
        try KeychainManager.shared.saveAPIKey("voice-code-first")
        try KeychainManager.shared.saveAPIKey("voice-code-second")

        XCTAssertEqual(KeychainManager.shared.getAPIKey(), "voice-code-second")
    }
}
```

### Acceptance Criteria

1. **Backend generates key on first startup**
   - Verify: `ls -la ~/.voice-code/api-key` shows `-rw-------` (600 permissions)
   - Verify: `cat ~/.voice-code/api-key | wc -c` outputs 43 (correct length)
   - Verify: Key starts with `voice-code-`

2. **Backend validates every message**
   - Test: Send `{"type": "connect"}` (no key) → receive `auth_error`, connection closes
   - Test: Send `{"type": "connect", "api_key": "wrong"}` → receive `auth_error`
   - Test: Send with valid key → receive `connected`

3. **iOS stores key in Keychain**
   - Verify: Key persists after app termination and restart
   - Verify: Key accessible via `KeychainManager.shared.getAPIKey()`

4. **QR code displays correctly**
   - Verify: `make show-key-qr` renders scannable QR in terminal
   - Verify: iOS can scan and decode to correct key string

5. **Manual entry works**
   - Verify: Paste valid key in Settings → saves successfully
   - Verify: Paste invalid key → shows validation error

6. **Connection fails without key**
   - Verify: iOS with no key in Keychain → shows "API Key Required"
   - Verify: Attempting connection → receives `auth_error`

7. **Connection succeeds with key**
   - Verify: After key configured → normal session list loads
   - Verify: Can send prompts and receive responses

8. **Key validation uses constant-time comparison**
   - Verify: Code review confirms `constant-time-equals?` used in validation path
   - Verify: Unit test covers `constant-time-equals?` function behavior

9. **Share extension includes API key**
   - Verify: HTTP `/upload` without key returns 401
   - Verify: HTTP `/upload` with valid key returns 200

## 5. Alternatives Considered

### JWT Tokens
- **Pros**: Industry standard, supports expiration
- **Cons**: Overkill for single-user, requires token refresh logic
- **Decision**: Rejected - unnecessary complexity

### mTLS (Mutual TLS)
- **Pros**: Very secure, certificate-based
- **Cons**: Complex setup, certificate management overhead
- **Decision**: Rejected - Tailscale already provides encryption

### OAuth 2.0
- **Pros**: Standard flow, supports third-party auth
- **Cons**: Requires auth server, way overkill for single-user
- **Decision**: Rejected - no third-party auth needed

### WebSocket Subprotocol
- **Pros**: Auth in handshake, cleaner protocol
- **Cons**: Harder to implement, less flexible
- **Decision**: Rejected - per-message auth is simpler

## 6. Risks & Mitigations

### Risk: Key Leaked in Logs
**Mitigation**: Never log the full API key. Log only "API key validated" or "API key invalid".

### Risk: Timing Attacks
**Mitigation**: Use constant-time string comparison for key validation.

### Risk: Key Stored Insecurely on macOS
**Mitigation**: File permissions (chmod 600) + directory permissions (chmod 700). Consider Keychain for backend in future.

### Risk: User Loses API Key
**Mitigation**: `make regenerate-key` command to generate new key. User must re-pair iOS app.

### Rollback Strategy
1. Remove `api_key` validation from `handle-message`
2. iOS continues sending `api_key` (ignored by backend)
3. No breaking changes - backward compatible

## 7. Implementation Checklist

### Backend
- [ ] Create `voice-code.auth` namespace with key generation/validation
- [ ] Add ZXing dependency to deps.edn: `com.google.zxing/core {:mvn/version "3.5.3"}`
- [ ] Create `voice-code.qr` namespace for terminal QR display
- [ ] Add `api-key` atom and load key in `-main` startup
- [ ] Modify `handle-message` to validate `api_key` on every message
- [ ] Modify `handle-http-upload` to validate `api_key` (returns 401 if invalid)
- [ ] Add `auth_error` message type
- [ ] Add Makefile targets: `show-key`, `show-key-qr`, `regenerate-key`
- [ ] Write unit tests for auth functions (including file permission test)
- [ ] Write integration tests for auth flow

### iOS
- [ ] Create `KeychainManager` class with `isValidAPIKeyFormat` validation
- [ ] Update `VoiceCodeClient.sendMessage` to include `api_key`
- [ ] Handle `auth_error` message type
- [ ] Add `isAuthenticated` and `authenticationError` published properties
- [ ] Create `APIKeySection` for SettingsView (with validation error display)
- [ ] Create `QRScannerView` using AVFoundation
- [ ] Create `APIKeyManagementView` for viewing/updating/deleting key
- [ ] Update Share Extension to include `api_key` in upload requests
- [ ] Write unit tests for KeychainManager
- [ ] Write UI tests for key entry flow

### Documentation
- [ ] Update @STANDARDS.md with `api_key` field in protocol
- [ ] Update @STANDARDS.md with `auth_error` message type
- [ ] Add setup instructions to README
