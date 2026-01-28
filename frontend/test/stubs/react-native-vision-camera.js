// Stub for react-native-vision-camera in Node.js test environment

module.exports = {
  Camera: function() {},
  useCameraDevice: function() { return null; },
  useCameraPermission: function() { return { hasPermission: false, requestPermission: function() { return Promise.resolve(false); } }; },
  useCodeScanner: function() { return {}; }
};
