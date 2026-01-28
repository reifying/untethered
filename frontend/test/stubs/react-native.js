// Stub for react-native module in Node.js test environment
// This provides minimal mock implementations for tests

module.exports = {
  AppState: {
    currentState: 'active',
    addEventListener: function() { return { remove: function() {} }; }
  },
  Platform: {
    OS: 'ios',
    select: function(obj) { return obj.ios || obj.default; }
  },
  StyleSheet: {
    create: function(styles) { return styles; }
  },
  View: function() {},
  Text: function() {},
  TouchableOpacity: function() {},
  ScrollView: function() {},
  TextInput: function() {},
  ActivityIndicator: function() {},
  Alert: {
    alert: function() {}
  },
  Linking: {
    openURL: function() { return Promise.resolve(); }
  },
  Dimensions: {
    get: function() { return { width: 375, height: 812 }; }
  },
  PixelRatio: {
    get: function() { return 2; }
  },
  Keyboard: {
    dismiss: function() {}
  },
  Clipboard: {
    setString: function() {},
    getString: function() { return Promise.resolve(''); }
  }
};
