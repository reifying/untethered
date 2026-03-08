// Stub for @react-navigation/native-stack in Node.js test environment

function createNativeStackNavigator() {
  return {
    Navigator: function(props) { return props.children; },
    Screen: function(props) { return null; },
    Group: function(props) { return props.children; }
  };
}

module.exports = {
  createNativeStackNavigator: createNativeStackNavigator
};
