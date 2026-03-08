// Stub for @react-navigation/native in Node.js test environment

module.exports = {
  NavigationContainer: function(props) { return props.children; },
  useNavigation: function() {
    return {
      navigate: function() {},
      goBack: function() {},
      reset: function() {},
      isFocused: function() { return true; },
      canGoBack: function() { return false; }
    };
  },
  useRoute: function() {
    return { key: 'mock-key', name: 'MockScreen', params: {} };
  },
  useFocusEffect: function(callback) {},
  useIsFocused: function() { return true; },
  CommonActions: {
    navigate: function(name, params) { return { type: 'NAVIGATE', payload: { name: name, params: params } }; },
    reset: function(state) { return { type: 'RESET', payload: state }; },
    goBack: function() { return { type: 'GO_BACK' }; }
  },
  StackActions: {
    push: function(name, params) { return { type: 'PUSH', payload: { name: name, params: params } }; },
    pop: function(count) { return { type: 'POP', payload: { count: count || 1 } }; }
  }
};
