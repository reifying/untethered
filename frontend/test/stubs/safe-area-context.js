// Stub for react-native-safe-area-context in Node.js test environment

var React = require('react');

module.exports = {
  SafeAreaProvider: function(props) { return props.children; },
  SafeAreaView: function(props) { return props.children; },
  useSafeAreaInsets: function() {
    return { top: 0, bottom: 0, left: 0, right: 0 };
  },
  useSafeAreaFrame: function() {
    return { x: 0, y: 0, width: 375, height: 812 };
  },
  SafeAreaInsetsContext: {
    Consumer: function(props) { return props.children({ top: 0, bottom: 0, left: 0, right: 0 }); },
    Provider: function(props) { return props.children; }
  },
  initialWindowMetrics: {
    insets: { top: 0, bottom: 0, left: 0, right: 0 },
    frame: { x: 0, y: 0, width: 375, height: 812 }
  }
};
