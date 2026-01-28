// Stub for @react-native-voice/voice in Node.js test environment

module.exports = {
  default: {
    start: function(locale) { return Promise.resolve(); },
    stop: function() { return Promise.resolve(); },
    cancel: function() { return Promise.resolve(); },
    destroy: function() { return Promise.resolve(); },
    isAvailable: function() { return Promise.resolve(true); },
    isRecognizing: function() { return Promise.resolve(false); },
    onSpeechStart: null,
    onSpeechEnd: null,
    onSpeechResults: null,
    onSpeechPartialResults: null,
    onSpeechError: null,
    removeAllListeners: function() {}
  }
};
