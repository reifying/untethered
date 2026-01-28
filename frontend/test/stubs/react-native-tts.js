// Stub for react-native-tts in Node.js test environment

module.exports = {
  default: {
    speak: function(text, options) { return Promise.resolve(); },
    stop: function() { return Promise.resolve(); },
    pause: function() { return Promise.resolve(); },
    resume: function() { return Promise.resolve(); },
    voices: function() { return Promise.resolve([]); },
    setDefaultVoice: function(voiceId) { return Promise.resolve(); },
    setDefaultRate: function(rate) { return Promise.resolve(); },
    setDefaultPitch: function(pitch) { return Promise.resolve(); },
    setIgnoreSilentSwitch: function(ignore) { return Promise.resolve(); },
    addEventListener: function(event, handler) { return { remove: function() {} }; },
    removeEventListener: function(event, handler) {}
  }
};
