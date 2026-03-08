// Stub for @react-native-clipboard/clipboard in Node.js test environment

module.exports = {
  default: {
    setString: function(content) {},
    getString: function() { return Promise.resolve(''); },
    hasString: function() { return Promise.resolve(false); }
  },
  setString: function(content) {},
  getString: function() { return Promise.resolve(''); },
  hasString: function() { return Promise.resolve(false); }
};
