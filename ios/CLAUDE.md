## In-App Logging

The app has two separate logging paths:

1. **`Logger` (os.log)** — visible in Console.app and `log stream`. Not visible in the in-app debug log viewer.
2. **`LogManager.shared.log(message, category:)`** — feeds the in-app debug log viewer (ladybug icon → Captured Logs). This is what the user copies when reporting bugs.

**Any manager that wants its logs visible in the in-app viewer must call `LogManager.shared.log()`.** Using only `Logger.info()` means the logs are invisible to the user.

The in-app system logs tab (`getSystemLogs`) filters by subsystem `"com.travisbrown.VoiceCode"`, but most managers use `"dev.910labs.voice-code"` — so the system logs tab will miss those too. Use Captured Logs (manual `LogManager.shared.log()` calls) as the reliable path.

Pattern used in `HeadsetRemoteCommandManager`:
```swift
private func hLog(_ msg: String) {
    logger.info("\(msg, privacy: .public)")
    LogManager.shared.log(msg, category: "HeadsetRemote")
}
```

Follow this pattern for any new manager that needs in-app log visibility.
