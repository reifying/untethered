## In-App Logging

All application logging goes through a single path: **`LogManager.shared.log(message, category:)`**.
It feeds the in-app debug log viewer (ladybug icon → Captured Logs), which is what the
user copies (or shares with an agent via the Share Logs button) when reporting bugs.

`Logger`/OSLog and `print()` are **not** used for application logging. Do not add
`import OSLog` / `import os.log`, `Logger(subsystem:category:)` declarations, or diagnostic
`print()` statements. (Exceptions: the Share Extension has its own logging, and `#if DEBUG`
blocks may keep `print()` for dev-only output.)

Pass a `category` derived from the manager/view name so logs are easy to filter. Pattern
used in `HeadsetRemoteCommandManager`:
```swift
private func hLog(_ msg: String) {
    LogManager.shared.log(msg, category: "HeadsetRemote")
}
```

Follow this pattern for any new manager or view that needs to log.
