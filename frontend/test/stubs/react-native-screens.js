// Stub for react-native-screens in Node.js test environment

var React = require('react');

module.exports = {
  enableScreens: function(shouldEnableScreens) {},
  screensEnabled: function() { return true; },
  Screen: function(props) { return props.children; },
  ScreenContainer: function(props) { return props.children; },
  NativeScreen: function(props) { return props.children; },
  NativeScreenContainer: function(props) { return props.children; },
  ScreenStack: function(props) { return props.children; },
  ScreenStackHeaderBackButtonImage: function(props) { return null; },
  ScreenStackHeaderCenterView: function(props) { return props.children; },
  ScreenStackHeaderConfig: function(props) { return null; },
  ScreenStackHeaderLeftView: function(props) { return props.children; },
  ScreenStackHeaderRightView: function(props) { return props.children; },
  ScreenStackHeaderSearchBarView: function(props) { return props.children; },
  SearchBar: function(props) { return null; },
  FullWindowOverlay: function(props) { return props.children; },
  useTransitionProgress: function() { return { progress: { value: 1 } }; }
};
