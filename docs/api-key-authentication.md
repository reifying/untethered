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
Example: `voice-code-a1b2c3d4e5f678901234567890abcdef`

- Prefix `voice-code-` for easy identification (11 characters)
- 32 hex characters = 128 bits of entropy
- Total length: 43 characters (11 + 32)

**Validation rules:**
- Must start with `voice-code-`
- Must be exactly 43 characters
- Characters after prefix must be lowercase hex (0-9, a-f)

#### Backend Storage
**File:** `~/.voice-code/api-key`
```
voice-code-a1b2c3d4e5f678901234567890abcdef
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

#### Protocol Change: Session-Based Authentication

Authentication happens once on the `connect` message. After successful authentication, the WebSocket session is marked as authenticated and subsequent messages don't require re-authentication.

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
  "api_key": "voice-code-a1b2c3d4e5f678901234567890abcdef"
}
```

Only the `connect` message includes `api_key`. Backend validates once and stores authenticated state in the `connected-clients` atom (`:authenticated true`). Subsequent messages are allowed without re-authentication for that session.

**Updated hello message (includes auth version):**
```json
{
  "type": "hello",
  "message": "Welcome to voice-code backend",
  "version": "0.1.0",
  "auth_version": 1,
  "instructions": "Send connect message with api_key"
}
```

The `auth_version` field allows future protocol changes while maintaining backward compatibility.

#### New Message Types

**Authentication Error Response:**
```json
{
  "type": "auth_error",
  "message": "Authentication failed"
}
```

Backend closes WebSocket connection after sending this.

**Key Display Request (CLI only):**
```bash
# Terminal command to display key
make show-key

# Output:
API Key: voice-code-a1b2c3d4e5f678901234567890abcdef

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

(def default-key-file-path
  "Default path for API key file. Can be overridden for testing."
  (str (System/getProperty "user.home") "/.voice-code/api-key"))

(def ^:dynamic *key-file-path*
  "Dynamic var for key file path, allows override in tests."
  nil)

(defn key-file-path
  "Get the current key file path. Uses *key-file-path* if bound, otherwise default."
  []
  (or *key-file-path* default-key-file-path))

(defn generate-api-key
  "Generate a new API key with 128 bits of entropy."
  []
  (let [random (SecureRandom.)
        bytes (byte-array 16)]
    (.nextBytes random bytes)
    (str "voice-code-"
         (apply str (map #(format "%02x" (bit-and % 0xff)) bytes)))))

(defn valid-key-format?
  "Check if a key string has valid format.
  Must be 43 chars: 'voice-code-' prefix + 32 lowercase hex chars."
  [key]
  (and (string? key)
       (= 43 (count key))
       (str/starts-with? key "voice-code-")
       (re-matches #"[0-9a-f]{32}" (subs key 11))))

(defn ensure-key-file!
  "Ensure API key file exists with correct permissions and valid format.
  Creates new key if file doesn't exist or contains invalid key."
  []
  (let [file (io/file (key-file-path))
        parent (.getParentFile file)]
    ;; Create directory with 700 permissions
    (when-not (.exists parent)
      (.mkdirs parent)
      (let [path (.toPath parent)
            perms (PosixFilePermissions/fromString "rwx------")]
        (Files/setPosixFilePermissions path perms)))
    ;; Check if existing key is valid
    (let [existing-key (when (.exists file) (str/trim (slurp file)))
          needs-regeneration (or (nil? existing-key)
                                  (not (valid-key-format? existing-key)))]
      (when needs-regeneration
        (when existing-key
          (log/warn "Existing API key has invalid format, regenerating"))
        (let [key (generate-api-key)]
          (spit file key)
          (let [path (.toPath file)
                perms (PosixFilePermissions/fromString "rw-------")]
            (Files/setPosixFilePermissions path perms))
          (log/info "Generated new API key"))))
    ;; Return the key
    (str/trim (slurp file))))

(defn read-api-key
  "Read the current API key from file."
  []
  (let [file (io/file (key-file-path))]
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

#### Backend: Session-Based Authentication

```clojure
;; In voice-code.server namespace

;; Stored key loaded once at startup (in -main)
(defonce api-key (atom nil))

;; connected-clients atom structure (existing, with auth state added):
;; {channel {:session-id "ios-uuid"
;;           :authenticated true}}
(defonce connected-clients (atom {}))

(defn channel-authenticated?
  "Check if a WebSocket channel has been authenticated."
  [channel]
  (get-in @connected-clients [channel :authenticated] false))

(defn authenticate-connect!
  "Validate API key on connect message and mark channel as authenticated.
  Returns {:authenticated true} or {:authenticated false :error \"message\" :log-reason \"...\"}."
  [channel data stored-key]
  (let [provided-key (:api-key data)]
    (cond
      (nil? provided-key)
      {:authenticated false
       :error "Authentication failed"  ; Generic message to client
       :log-reason "Missing API key"}  ; Detailed reason for logs

      (not (auth/constant-time-equals? stored-key provided-key))
      {:authenticated false
       :error "Authentication failed"
       :log-reason "Invalid API key"}

      :else
      (do
        ;; Mark channel as authenticated in connected-clients
        (swap! connected-clients assoc-in [channel :authenticated] true)
        {:authenticated true}))))

(defn handle-message
  "Handle incoming WebSocket message with session-based authentication."
  [channel msg]
  (try
    (let [data (parse-json msg)
          msg-type (:type data)]
      (case msg-type
        ;; connect requires authentication
        "connect"
        (let [auth-result (authenticate-connect! channel data @api-key)]
          (if (:authenticated auth-result)
            (handle-connect channel data)
            (do
              (log/warn "Authentication failed" {:reason (:log-reason auth-result)})
              (http/send! channel
                          (generate-json {:type :auth-error
                                          :message (:error auth-result)}))
              (http/close channel))))

        ;; All other messages require prior authentication
        (if (channel-authenticated? channel)
          (case msg-type
            "prompt" (handle-prompt channel data)
            "ping" (handle-ping channel)
            ;; ... rest of handlers
            )
          ;; Not authenticated - reject with generic error
          (do
            (log/warn "Unauthenticated message rejected" {:type msg-type})
            (http/send! channel
                        (generate-json {:type :auth-error
                                        :message "Authentication failed"}))
            (http/close channel)))))
    (catch Exception e
      ;; ... error handling
      )))

;; Update hello message to include auth_version
(defn send-hello [channel]
  (http/send! channel
              (generate-json {:type :hello
                              :message "Welcome to voice-code backend"
                              :version "0.1.0"
                              :auth-version 1
                              :instructions "Send connect message with api_key"})))
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
  "Render QR code to terminal using Unicode block characters.
  Note: QR codes need high contrast. This renders dark modules as blocks
  and light modules as spaces. For dark terminal backgrounds, you may need
  to invert colors or ensure sufficient contrast."
  [^BitMatrix matrix]
  (let [width (.getWidth matrix)
        height (.getHeight matrix)]
    ;; Use Unicode block characters for compact display
    ;; Top half block: ▀ (U+2580), Bottom half block: ▄ (U+2584)
    ;; Full block: █ (U+2588), Space for white
    ;; Note: Standard QR = black modules on white background
    ;; Terminal with light text on dark bg may need inversion
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
  (let [key (auth/read-api-key)
        key-len (count key)
        ;; Box width = key length + 4 (2 spaces padding each side)
        box-width (+ key-len 4)
        horizontal-line (apply str (repeat box-width "═"))
        empty-line (str "║" (apply str (repeat box-width " ")) "║")
        title "Voice-Code API Key"
        title-padding (quot (- box-width (count title)) 2)
        title-line (str "║"
                        (apply str (repeat title-padding " "))
                        title
                        (apply str (repeat (- box-width title-padding (count title)) " "))
                        "║")]
    (println)
    (println (str "╔" horizontal-line "╗"))
    (println title-line)
    (println (str "╠" horizontal-line "╣"))
    (when show-qr?
      (let [scan-msg "Scan with iOS camera or paste manually:"
            scan-padding (quot (- box-width (count scan-msg)) 2)
            scan-line (str "║"
                           (apply str (repeat scan-padding " "))
                           scan-msg
                           (apply str (repeat (- box-width scan-padding (count scan-msg)) " "))
                           "║")]
        (println scan-line)
        (println empty-line)
        (let [matrix (generate-qr-matrix key 25)]
          (render-qr-terminal matrix))
        (println empty-line)))
    (println (str "║  " key "  ║"))
    (println (str "╚" horizontal-line "╝"))
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

    /// Access group for sharing keychain items with app extensions.
    /// Format: $(TeamIdentifierPrefix)dev.910labs.voice-code
    /// This allows the Share Extension to access the same API key.
    private let accessGroup = "$(TeamIdentifierPrefix)dev.910labs.voice-code"

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
            kSecAttrAccessGroup as String: accessGroup,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        // Try to add, if exists then update
        var status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrAccessGroup as String: accessGroup
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
            kSecAttrAccessGroup as String: accessGroup,
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
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup
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
    /// Key must start with "voice-code-", be exactly 43 characters,
    /// and contain only lowercase hex characters after the prefix
    func isValidAPIKeyFormat(_ key: String) -> Bool {
        guard key.hasPrefix("voice-code-") && key.count == 43 else {
            return false
        }
        let hexPart = key.dropFirst(11)  // Remove "voice-code-" prefix
        let hexCharacterSet = CharacterSet(charactersIn: "0123456789abcdef")
        return hexPart.unicodeScalars.allSatisfy { hexCharacterSet.contains($0) }
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
    @Published var requiresReauthentication = false  // Shows "re-scan required" UI

    private var apiKey: String? {
        KeychainManager.shared.getAPIKey()
    }

    // Send connect message with API key (authentication happens here only)
    func sendConnectMessage() {
        guard let key = apiKey else {
            DispatchQueue.main.async { [weak self] in
                self?.requiresReauthentication = true
                self?.authenticationError = "API key not configured. Please scan QR code in Settings."
            }
            return
        }

        let message: [String: Any] = [
            "type": "connect",
            "session_id": currentSessionId,
            "api_key": key
        ]
        sendRawMessage(message)
    }

    // Regular messages don't need API key (session already authenticated)
    func sendMessage(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else {
            LogManager.shared.log("Failed to serialize message", category: "VoiceCodeClient")
            return
        }
        // ... rest of existing send logic ...
    }

    // Handle auth_error message type with graceful UX
    func handleMessage(_ text: String) {
        // ... existing parsing ...

        switch type {
        case "auth_error":
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isAuthenticated = false
                self.requiresReauthentication = true
                self.authenticationError = json["message"] as? String ?? "Authentication failed"
                // Don't disconnect immediately - show error UI first
            }

        case "hello":
            // Check auth_version for compatibility (future-proofing)
            if let authVersion = json["auth_version"] as? Int, authVersion > 1 {
                LogManager.shared.log("Server requires newer auth version: \(authVersion)",
                                      category: "VoiceCodeClient")
            }
            // Send connect with API key
            self.sendConnectMessage()

        case "connected":
            // Successfully authenticated
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isAuthenticated = true
                self.authenticationError = nil
                self.requiresReauthentication = false
            }
            // ... rest of existing connected handling ...

        // ... rest of existing cases ...
        }
    }
}
```

#### iOS: Graceful Auth Failure UI

When authentication fails, show a user-friendly message instead of just disconnecting:

```swift
// In ContentView.swift or appropriate view

struct AuthenticationRequiredView: View {
    @EnvironmentObject var voiceCodeClient: VoiceCodeClient

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "key.slash")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            Text("Authentication Required")
                .font(.title2)
                .fontWeight(.semibold)

            if let error = voiceCodeClient.authenticationError {
                Text(error)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            NavigationLink(destination: SettingsView()) {
                Label("Open Settings to Re-scan", systemImage: "qrcode.viewfinder")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)

            Button("Retry Connection") {
                voiceCodeClient.connect()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
}

// Usage in main view:
if voiceCodeClient.requiresReauthentication {
    AuthenticationRequiredView()
} else {
    // Normal content
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
import AudioToolbox

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
        checkCameraPermission()
    }

    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.setupCamera()
                    } else {
                        self?.showPermissionDeniedAlert()
                    }
                }
            }
        case .denied, .restricted:
            showPermissionDeniedAlert()
        @unknown default:
            break
        }
    }

    private func showPermissionDeniedAlert() {
        let alert = UIAlertController(
            title: "Camera Access Required",
            message: "Please enable camera access in Settings to scan QR codes.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        present(alert, animated: true)
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

The HTTP `/upload` endpoint uses the `Authorization` header for authentication (standard Bearer token format).

#### Backend: HTTP Authentication

```clojure
(defn extract-bearer-token
  "Extract Bearer token from Authorization header.
  Returns nil if header is missing or malformed."
  [req]
  (when-let [auth-header (get-in req [:headers "authorization"])]
    (when (str/starts-with? auth-header "Bearer ")
      (subs auth-header 7))))

(defn handle-http-upload
  "Handle HTTP POST /upload requests with Bearer token authentication."
  [req channel]
  (try
    (let [provided-key (extract-bearer-token req)
          ;; Use generic error message, log detailed reason
          auth-failed (fn [log-reason]
                        (log/warn "HTTP auth failed" {:reason log-reason})
                        (http/send! channel
                                    {:status 401
                                     :headers {"Content-Type" "application/json"
                                               "WWW-Authenticate" "Bearer realm=\"voice-code\""}
                                     :body (generate-json
                                            {:success false
                                             :error "Authentication failed"})}))]
      (cond
        (nil? provided-key)
        (auth-failed "Missing Authorization header")

        (not (auth/constant-time-equals? @api-key provided-key))
        (auth-failed "Invalid API key")

        :else
        ;; Authenticated - proceed with upload
        (let [body (slurp (:body req))
              data (parse-json body)
              filename (:filename data)
              content (:content data)
              storage-location (:storage-location data)]
          ;; ... rest of existing upload logic ...
          )))
    (catch Exception e
      ;; ... error handling ...
      )))
```

#### iOS: Share Extension with Authorization Header

The Share Extension accesses the API key via the shared Keychain access group:

```swift
// ShareError.swift
enum ShareError: Error {
    case notAuthenticated
    case invalidURL
    case invalidResponse
    case uploadFailed(statusCode: Int)
}

// In ShareViewController.swift or similar
func uploadFile(filename: String, content: Data, storageLocation: String) async throws {
    guard let apiKey = KeychainManager.shared.getAPIKey() else {
        throw ShareError.notAuthenticated
    }

    guard let url = URL(string: "\(backendURL)/upload") else {
        throw ShareError.invalidURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    let payload: [String: Any] = [
        "filename": filename,
        "content": content.base64EncodedString(),
        "storage_location": storageLocation
    ]

    request.httpBody = try JSONSerialization.data(withJSONObject: payload)

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
        throw ShareError.invalidResponse
    }

    if httpResponse.statusCode == 401 {
        throw ShareError.notAuthenticated
    }

    guard httpResponse.statusCode == 200 else {
        throw ShareError.uploadFailed(statusCode: httpResponse.statusCode)
    }
}
```

**Note:** The Share Extension requires the same Keychain Access Group (`$(TeamIdentifierPrefix)dev.910labs.voice-code`) to be configured in both:
1. Main app's entitlements file
2. Share Extension's entitlements file

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
 │  <──── {"type": "hello",   ────                   │
 │         "auth_version": 1}                        │
 │                                                   │
 │  ──── {"type": "connect",  ────>                  │
 │        "api_key": "..."}                          │
 │                                     ┌─────────────┤
 │                                     │ Validate    │
 │                                     │ api_key,    │
 │                                     │ mark authed │
 │                                     └─────────────┤
 │  <──── {"type": "connected"} ────                 │
 │                                                   │
 │  ──── {"type": "prompt",   ────>    (no api_key   │
 │        "text": "..."}                needed now!) │
 │                                     ┌─────────────┤
 │                                     │ Check       │
 │                                     │ session     │
 │                                     │ is authed   │
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
 │         "message": "Authentication failed"}       │
 │                                                   │
 │  <──── WebSocket close ────                       │
 │                                                   │


┌─────────────────────────────────────────────────────────────┐
│              Backend Restart (Transparent to User)           │
└─────────────────────────────────────────────────────────────┘

iOS                                              Backend
 │                                                   │
 │  ════ WebSocket open, authenticated ════          │
 │                                                   │
 │                              [Backend restarts]   │
 │                                                   │
 │  <──── WebSocket close (server gone) ────         │
 │                                                   │
 │  [iOS detects disconnect]                         │
 │  [Auto-reconnect with exponential backoff]        │
 │                                                   │
 │  ──── WebSocket connect ────>   [New backend]     │
 │                                                   │
 │  <──── {"type": "hello",   ────                   │
 │         "auth_version": 1}                        │
 │                                                   │
 │  ──── {"type": "connect",  ────>                  │
 │        "api_key": "..."}        (from Keychain)   │
 │                                     ┌─────────────┤
 │                                     │ Validate    │
 │                                     │ (new sess)  │
 │                                     └─────────────┤
 │  <──── {"type": "connected"} ────                 │
 │                                                   │
 │  [Session restored, user unaware of restart]      │
 │                                                   │

**Key point:** Reconnection after backend restart is transparent because:
1. API key persists in iOS Keychain (survives app/device restarts)
2. iOS includes `api_key` in every `connect` message automatically
3. No user intervention required - authentication is seamless
4. Existing session mapping (iOS UUID → Claude session) is restored from disk
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
        ;; Override key-file-path using dynamic binding
        (binding [auth/*key-file-path* test-key-path]
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

;; Mock channel for testing
(def mock-channel (atom nil))

(deftest authenticate-connect-test
  (let [stored-key "voice-code-a1b2c3d4e5f678901234567890abcdef"]

    (testing "authenticates valid key"
      (reset! server/connected-clients {})
      (let [result (server/authenticate-connect!
                     mock-channel
                     {:type "connect" :api-key stored-key}
                     stored-key)]
        (is (:authenticated result))
        (is (get-in @server/connected-clients [mock-channel :authenticated]))))

    (testing "rejects missing key"
      (let [result (server/authenticate-connect!
                     mock-channel
                     {:type "connect"}
                     stored-key)]
        (is (not (:authenticated result)))
        (is (= "Authentication failed" (:error result)))
        (is (= "Missing API key" (:log-reason result)))))

    (testing "rejects invalid key"
      (let [result (server/authenticate-connect!
                     mock-channel
                     {:type "connect" :api-key "wrong-key"}
                     stored-key)]
        (is (not (:authenticated result)))
        (is (= "Authentication failed" (:error result)))
        (is (= "Invalid API key" (:log-reason result)))))))

(deftest valid-key-format-test
  (testing "accepts valid keys"
    (is (auth/valid-key-format? "voice-code-a1b2c3d4e5f678901234567890abcdef"))
    (is (auth/valid-key-format? "voice-code-00000000000000000000000000000000")))

  (testing "rejects invalid keys"
    (is (not (auth/valid-key-format? nil)))
    (is (not (auth/valid-key-format? "")))
    (is (not (auth/valid-key-format? "voice-code-short")))
    (is (not (auth/valid-key-format? "wrong-prefix-a1b2c3d4e5f67890123456789abcdef")))
    (is (not (auth/valid-key-format? "voice-code-UPPERCASE1234567890123456789abc")))  ; uppercase
    (is (not (auth/valid-key-format? "voice-code-ghijklmn1234567890123456789abc")))))  ; non-hex
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
        // 43 chars total: "voice-code-" (11) + 32 hex chars
        let testKey = "voice-code-a1b2c3d4e5f678901234567890abcdef"

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

2. **Backend validates connect message and enforces session auth**
   - Test: Send `{"type": "connect"}` (no key) → receive `auth_error`, connection closes
   - Test: Send `{"type": "connect", "api_key": "wrong"}` → receive `auth_error`
   - Test: Send with valid key → receive `connected`
   - Test: Send `{"type": "prompt"}` without prior `connect` → receive `auth_error`

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
   - Verify: HTTP `/upload` without Authorization header returns 401
   - Verify: HTTP `/upload` with `Authorization: Bearer <key>` returns 200

10. **Backend restart is transparent to user**
    - Verify: Restart backend while iOS is connected
    - Verify: iOS auto-reconnects and re-authenticates without user intervention
    - Verify: No "API Key Required" prompt shown (key retrieved from Keychain)
    - Verify: Session resumes normally after reconnection

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
- **Decision**: Rejected - session-based auth (authenticate once on connect) is simpler

### Per-Message Authentication
- **Pros**: Stateless validation
- **Cons**: Wasteful (re-validates every message), more bandwidth, slower
- **Decision**: Rejected - session-based auth is more efficient. Authenticate once on `connect`, then mark WebSocket channel as authenticated.

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

### Edge Cases

#### Corrupted Key File
If `~/.voice-code/api-key` contains invalid data:
- Backend should validate key format on load (43 chars, correct prefix, hex-only)
- If invalid, regenerate key and log warning
- Implementation: Add `valid-api-key?` function to validate format

#### Channel Cleanup on Disconnect
When WebSocket closes, the `:authenticated` flag must be cleaned up:
```clojure
(defn on-close [channel status]
  (swap! connected-clients dissoc channel)
  (log/info "Client disconnected" {:status status}))
```

#### iOS Auto-Reconnect Backoff
Exponential backoff for reconnection attempts:
- Initial delay: 1 second
- Max delay: 30 seconds
- Multiplier: 2x per attempt
- Jitter: ±25% randomization

#### Error Message Information Leakage
Use generic error messages to avoid leaking information:
- Both "Missing API key" and "Invalid API key" should return same generic message
- Log detailed error internally, send generic "Authentication failed" to client

### Future Considerations (Out of Scope)

1. **Rate Limiting**: Limit auth failures per IP to prevent brute-force attacks
2. **Key Expiration**: Add optional TTL for API keys with refresh mechanism
3. **Audit Logging**: Log all auth events to a separate audit log
4. **Multiple Keys**: Support multiple valid keys for device migration
5. **Backend Keychain**: Store API key in macOS Keychain instead of filesystem

## 7. Implementation Checklist

### Backend
- [ ] Create `voice-code.auth` namespace with key generation/validation
  - [ ] Expose `*key-file-path*` dynamic var for testing
  - [ ] Implement `constant-time-equals?` for secure comparison
  - [ ] Implement `valid-key-format?` for hex validation
  - [ ] Validate existing key on startup, regenerate if corrupted
- [ ] Add ZXing dependency to deps.edn: `com.google.zxing/core {:mvn/version "3.5.3"}`
- [ ] Create `voice-code.qr` namespace for terminal QR display
  - [ ] Dynamic box sizing based on key length
- [ ] Add `api-key` atom and load key in `-main` startup
- [ ] Implement session-based auth:
  - [ ] Add `:authenticated` flag to `connected-clients` atom
  - [ ] Validate `api_key` only on `connect` message
  - [ ] Check `channel-authenticated?` for subsequent messages
  - [ ] Clean up `connected-clients` entry on WebSocket close
  - [ ] Use generic error messages (log detailed reason internally)
- [ ] Update `hello` message to include `auth_version: 1`
- [ ] Modify `handle-http-upload` to use `Authorization: Bearer` header
  - [ ] Add `extract-bearer-token` function
  - [ ] Return `WWW-Authenticate` header on 401
- [ ] Add `auth_error` message type
- [ ] Add Makefile targets: `show-key`, `show-key-qr`, `regenerate-key`
- [ ] Write unit tests for auth functions (including file permission test with `binding`)
- [ ] Write integration tests for auth flow

### iOS
- [ ] Create `KeychainManager` class with `isValidAPIKeyFormat` validation
  - [ ] Add `kSecAttrAccessGroup` for Share Extension access
  - [ ] Validate hex characters (not just length and prefix)
  - [ ] Include accessGroup in update query
- [ ] Update `VoiceCodeClient`:
  - [ ] Include `api_key` only in `connect` message (not every message)
  - [ ] Add `requiresReauthentication` published property
  - [ ] Check `auth_version` in `hello` response
- [ ] Handle `auth_error` message type gracefully
- [ ] Add `isAuthenticated` and `authenticationError` published properties
- [ ] Create `AuthenticationRequiredView` for graceful auth failure UX
- [ ] Create `APIKeySection` for SettingsView (with validation error display)
- [ ] Create `QRScannerView` using AVFoundation
  - [ ] Handle camera permission request and denial
  - [ ] Validate scanned code format before accepting
  - [ ] Add `NSCameraUsageDescription` to Info.plist
- [ ] Create `APIKeyManagementView` for viewing/updating/deleting key
- [ ] Update Share Extension:
  - [ ] Use `Authorization: Bearer` header (not body)
  - [ ] Configure same Keychain Access Group in entitlements
- [ ] Write unit tests for KeychainManager
- [ ] Write UI tests for key entry flow

### Documentation
- [ ] Update @STANDARDS.md with `api_key` field in `connect` message
- [ ] Update @STANDARDS.md with `auth_error` message type
- [ ] Update @STANDARDS.md with `auth_version` in `hello` message
- [ ] Add setup instructions to README
