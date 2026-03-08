// Stub for react-native-keychain in Node.js test environment

module.exports = {
  setGenericPassword: function(username, password, options) {
    return Promise.resolve(true);
  },
  getGenericPassword: function(options) {
    return Promise.resolve(false);
  },
  resetGenericPassword: function(options) {
    return Promise.resolve(true);
  },
  ACCESSIBLE: {
    WHEN_UNLOCKED: 'AccessibleWhenUnlocked',
    AFTER_FIRST_UNLOCK: 'AccessibleAfterFirstUnlock',
    ALWAYS: 'AccessibleAlways'
  }
};
