// Stub for react-native-safe-area-context in Node.js test environment
// Uses ESM export syntax to match shadow-cljs expectations.

export var SafeAreaProvider = function(props) { return props.children; };
export var SafeAreaView = function(props) { return props.children; };
export var useSafeAreaInsets = function() {
  return { top: 0, bottom: 0, left: 0, right: 0 };
};
export var useSafeAreaFrame = function() {
  return { x: 0, y: 0, width: 375, height: 812 };
};
export var initialWindowMetrics = {
  insets: { top: 0, bottom: 0, left: 0, right: 0 },
  frame: { x: 0, y: 0, width: 375, height: 812 }
};
