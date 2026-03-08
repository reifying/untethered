// Stub for react-native-document-picker in Node.js test environment

module.exports = {
  default: {
    pick: function(options) { return Promise.resolve([]); },
    pickDirectory: function() { return Promise.resolve(null); },
    isCancel: function(err) { return false; }
  },
  pick: function(options) { return Promise.resolve([]); },
  pickDirectory: function() { return Promise.resolve(null); },
  isCancel: function(err) { return false; },
  types: {
    allFiles: '*/*',
    images: 'image/*',
    plainText: 'text/plain',
    audio: 'audio/*',
    pdf: 'application/pdf'
  }
};
