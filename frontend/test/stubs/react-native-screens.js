// Stub for react-native-screens in Node.js test environment

module.exports = {
  enableScreens: function(shouldEnableScreens) {},
  screensEnabled: function() { return true; },
  Screen: function(props) { return props.children; },
  ScreenContainer: function(props) { return props.children; },
  ScreenStack: function(props) { return props.children; }
};
