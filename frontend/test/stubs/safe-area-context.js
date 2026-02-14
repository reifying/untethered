// Stub for react-native-safe-area-context in Node.js test environment
// MUST use ESM export var syntax, not CommonJS module.exports
// See MEMORY.md: shadow-cljs wraps CommonJS under .default, breaking :as imports

export var SafeAreaProvider = function(props) { return props.children; };
export var SafeAreaView = function(props) { return props.children; };
export var useSafeAreaInsets = function() {
  return { top: 0, bottom: 0, left: 0, right: 0 };
};
export var useSafeAreaFrame = function() {
  return { x: 0, y: 0, width: 375, height: 812 };
};
export var SafeAreaInsetsContext = {
  Consumer: function(props) { return props.children({ top: 0, bottom: 0, left: 0, right: 0 }); },
  Provider: function(props) { return props.children; }
};
export var initialWindowMetrics = {
  insets: { top: 0, bottom: 0, left: 0, right: 0 },
  frame: { x: 0, y: 0, width: 375, height: 812 }
};
