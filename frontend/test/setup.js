// Test setup - mock native modules before shadow-cljs test runner loads
// This file is run before the test output via Node's --require flag

const Module = require('module');
const originalRequire = Module.prototype.require;

// Stub implementations for native modules
const stubs = {
  'react-native': {
    AppState: {
      currentState: 'active',
      addEventListener: () => ({ remove: () => {} })
    },
    Platform: {
      OS: 'ios',
      select: (obj) => obj.ios || obj.default
    },
    StyleSheet: {
      create: (styles) => styles
    },
    View: () => null,
    Text: () => null,
    TouchableOpacity: () => null,
    ScrollView: () => null,
    TextInput: () => null,
    ActivityIndicator: () => null,
    Alert: { alert: () => {} },
    Linking: { openURL: () => Promise.resolve() },
    Dimensions: { get: () => ({ width: 375, height: 812 }) },
    PixelRatio: { get: () => 2 },
    Keyboard: { dismiss: () => {} },
    Clipboard: {
      setString: () => {},
      getString: () => Promise.resolve('')
    }
  },
  'react-native-haptic-feedback': {
    default: { trigger: () => {} },
    trigger: () => {}
  },
  'react-native-keychain': {
    setGenericPassword: () => Promise.resolve(true),
    getGenericPassword: () => Promise.resolve(false),
    resetGenericPassword: () => Promise.resolve(true),
    ACCESSIBLE: {
      WHEN_UNLOCKED: 'AccessibleWhenUnlocked',
      AFTER_FIRST_UNLOCK: 'AccessibleAfterFirstUnlock',
      ALWAYS: 'AccessibleAlways'
    }
  },
  'react-native-sqlite-storage': {
    openDatabase: () => ({
      transaction: (txCallback, errorCallback, successCallback) => {
        const tx = {
          executeSql: (sql, params, success, error) => {
            if (success) success(tx, { rows: { length: 0, item: () => null } });
          }
        };
        txCallback(tx);
        if (successCallback) successCallback();
      },
      close: (success) => { if (success) success(); }
    }),
    enablePromise: () => {},
    DEBUG: () => {}
  },
  'react-native-tts': {
    default: {
      speak: () => Promise.resolve(),
      stop: () => Promise.resolve(),
      pause: () => Promise.resolve(),
      resume: () => Promise.resolve(),
      voices: () => Promise.resolve([]),
      setDefaultVoice: () => Promise.resolve(),
      setDefaultRate: () => Promise.resolve(),
      setDefaultPitch: () => Promise.resolve(),
      setIgnoreSilentSwitch: () => Promise.resolve(),
      addEventListener: () => ({ remove: () => {} }),
      removeEventListener: () => {}
    }
  },
  '@react-native-voice/voice': {
    default: {
      start: () => Promise.resolve(),
      stop: () => Promise.resolve(),
      cancel: () => Promise.resolve(),
      destroy: () => Promise.resolve(),
      isAvailable: () => Promise.resolve(true),
      isRecognizing: () => Promise.resolve(false),
      onSpeechStart: null,
      onSpeechEnd: null,
      onSpeechResults: null,
      onSpeechPartialResults: null,
      onSpeechError: null,
      removeAllListeners: () => {}
    }
  },
  '@notifee/react-native': {
    default: {
      displayNotification: () => Promise.resolve(),
      cancelNotification: () => Promise.resolve(),
      cancelAllNotifications: () => Promise.resolve(),
      requestPermission: () => Promise.resolve({ authorizationStatus: 1 }),
      getNotificationSettings: () => Promise.resolve({ authorizationStatus: 1 }),
      setNotificationCategories: () => Promise.resolve(),
      createChannel: () => Promise.resolve(),
      onForegroundEvent: () => () => {},
      onBackgroundEvent: () => {}
    }
  },
  'react-native-vision-camera': {
    Camera: () => null,
    useCameraDevice: () => null,
    useCameraPermission: () => ({ hasPermission: false, requestPermission: () => Promise.resolve(false) }),
    useCodeScanner: () => ({})
  },
  '@react-native-clipboard/clipboard': {
    default: {
      setString: () => {},
      getString: () => Promise.resolve(''),
      hasString: () => Promise.resolve(false)
    },
    setString: () => {},
    getString: () => Promise.resolve(''),
    hasString: () => Promise.resolve(false)
  }
};

Module.prototype.require = function(id) {
  if (stubs[id]) {
    return stubs[id];
  }
  return originalRequire.apply(this, arguments);
};

console.log('Test setup: Native module stubs loaded');
