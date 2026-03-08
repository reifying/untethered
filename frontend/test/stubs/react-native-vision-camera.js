// Stub for react-native-vision-camera in Node.js test environment

export var Camera = {
  getCameraPermissionStatus: function() { return "not-determined"; },
  requestCameraPermission: function() { return Promise.resolve(false); }
};
export var useCameraDevice = function() { return null; };
export var useCameraPermission = function() { return { hasPermission: false, requestPermission: function() { return Promise.resolve(false); } }; };
export var useCodeScanner = function() { return {}; };
