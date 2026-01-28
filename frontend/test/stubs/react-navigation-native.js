// Stub for @react-navigation/native in Node.js test environment

var React = require('react');

module.exports = {
  NavigationContainer: function(props) { return props.children; },
  useNavigation: function() {
    return {
      navigate: function(name, params) {},
      goBack: function() {},
      reset: function(state) {},
      setParams: function(params) {},
      dispatch: function(action) {},
      isFocused: function() { return true; },
      canGoBack: function() { return false; },
      getState: function() { return { routes: [], index: 0 }; },
      getParent: function() { return null; }
    };
  },
  useRoute: function() {
    return {
      key: 'mock-key',
      name: 'MockScreen',
      params: {}
    };
  },
  useFocusEffect: function(callback) {},
  useIsFocused: function() { return true; },
  CommonActions: {
    navigate: function(name, params) { return { type: 'NAVIGATE', payload: { name: name, params: params } }; },
    reset: function(state) { return { type: 'RESET', payload: state }; },
    goBack: function() { return { type: 'GO_BACK' }; },
    setParams: function(params) { return { type: 'SET_PARAMS', payload: { params: params } }; }
  },
  StackActions: {
    push: function(name, params) { return { type: 'PUSH', payload: { name: name, params: params } }; },
    pop: function(count) { return { type: 'POP', payload: { count: count || 1 } }; },
    popToTop: function() { return { type: 'POP_TO_TOP' }; },
    replace: function(name, params) { return { type: 'REPLACE', payload: { name: name, params: params } }; }
  },
  createNavigationContainerRef: function() {
    return {
      isReady: function() { return true; },
      navigate: function(name, params) {},
      goBack: function() {},
      reset: function(state) {},
      getCurrentRoute: function() { return { name: 'MockScreen', params: {} }; }
    };
  }
};
