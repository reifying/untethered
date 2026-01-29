(ns voice-code.testing-env
  "Testing environment detection utilities.
   Provides flags for detecting when app is running under test conditions.
   Matches iOS TestingEnvironment.swift functionality.

   Usage:
     ;; Skip permission prompts during UI tests
     (when-not testing-env/ui-testing?
       (request-permission!))

     ;; Use stub implementations in unit tests
     (if testing-env/unit-testing?
       (stub-implementation)
       (real-implementation))"
  (:require [clojure.string :as str]))

;; ============================================================================
;; Environment Detection
;; ============================================================================

(defn- check-launch-args
  "Check React Native launch arguments for testing flags.
   In React Native, launch arguments can be passed via:
   - iOS: launchArguments in XCUIApplication
   - Android: intent extras via adb
   - Metro bundler: __DEV__ mode detection

   For UI testing, the test harness should set the 'uitesting' argument."
  [arg-name]
  ;; React Native doesn't expose ProcessInfo.arguments directly like iOS.
  ;; Instead, we check:
  ;; 1. Global __TEST_UITESTING__ flag (can be set by test harness)
  ;; 2. React Native NativeModules for custom test module
  (or
   ;; Check for global flag set by test harness
   (and (exists? js/globalThis)
        (aget js/globalThis (str "__TEST_" (str/upper-case arg-name) "__")))
   ;; Check for global flag on window (web/dev context)
   (and (exists? js/window)
        (aget js/window (str "__TEST_" (str/upper-case arg-name) "__")))))

(def ui-testing?
  "Returns true when app is launched by UI tests with uitesting flag.
   UI tests should set globalThis.__TEST_UITESTING__ = true to enable this.

   When true, permission prompts are skipped to prevent blocking automation.

   Matches iOS TestingEnvironment.isUITesting."
  (delay (boolean (check-launch-args "uitesting"))))

(def unit-testing?
  "Returns true when running in unit test environment (Node.js/shadow-cljs test).
   Detected by checking for Node.js process object.

   When true, native modules use stub implementations.

   Matches iOS TestingEnvironment.isUnitTesting (but using Node.js detection
   instead of XCTest detection)."
  (delay
    (or
     ;; Node.js process object exists (shadow-cljs test runner)
     (and (exists? js/process)
          (exists? (.-versions js/process))
          (some? (.-node (.-versions js/process))))
     ;; Explicit test flag
     (boolean (check-launch-args "unittesting")))))

(def dev-mode?
  "Returns true when running in development mode.
   Detected by React Native's __DEV__ global.

   Matches iOS TestingEnvironment.isPreview (development equivalent)."
  (delay
    (and (exists? js/__DEV__)
         (true? js/__DEV__))))

;; ============================================================================
;; Convenience Functions
;; ============================================================================

(defn skip-permission-prompt?
  "Returns true if permission prompts should be skipped.
   Skip in both UI testing and unit testing contexts."
  []
  (or @ui-testing? @unit-testing?))

(defn use-native-modules?
  "Returns true if native modules should be used.
   False during unit tests where we use stubs."
  []
  (not @unit-testing?))

(defn testing?
  "Returns true if running in any testing context."
  []
  (or @ui-testing? @unit-testing?))
