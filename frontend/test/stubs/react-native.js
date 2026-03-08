// Stub for react-native module in Node.js test environment
// Uses ESM export syntax so shadow-cljs treats exports as top-level named exports.

export var Platform = {
  OS: 'ios',
  select: function(obj) { return obj.ios || obj.default; }
};

export var AppState = {
  currentState: 'active',
  addEventListener: function() { return { remove: function() {} }; }
};

export var StyleSheet = {
  create: function(styles) { return styles; }
};

export var View = function() {};
export var Text = function() {};
export var TouchableOpacity = function() {};
export var ScrollView = function() {};
export var TextInput = function() {};
export var ActivityIndicator = function() {};
export var SafeAreaView = function() {};
export var Modal = function() {};
export var FlatList = function() {};
export var Pressable = function() {};
export var Switch = function() {};
export var Image = function() {};

export var Alert = {
  alert: function() {}
};

export var Linking = {
  openURL: function() { return Promise.resolve(); }
};

export var Dimensions = {
  get: function() { return { width: 375, height: 812 }; }
};

export var PixelRatio = {
  get: function() { return 2; }
};

export var Keyboard = {
  dismiss: function() {},
  addListener: function() { return { remove: function() {} }; }
};

export var Clipboard = {
  setString: function() {},
  getString: function() { return Promise.resolve(''); }
};

export var Animated = {
  View: function() {},
  Text: function() {},
  Value: function(val) {
    this._value = val;
    this._offset = 0;
  },
  timing: function() { return { start: function(cb) { if (cb) cb(); } }; },
  spring: function() { return { start: function(cb) { if (cb) cb(); } }; },
  parallel: function() { return { start: function(cb) { if (cb) cb(); } }; },
  sequence: function() { return { start: function(cb) { if (cb) cb(); } }; },
  event: function() { return function() {}; },
  createAnimatedComponent: function(comp) { return comp; }
};
Animated.Value.prototype.setValue = function(val) { this._value = val; };
Animated.Value.prototype.setOffset = function(val) { this._offset = val; };
Animated.Value.prototype.flattenOffset = function() { this._value += this._offset; this._offset = 0; };
Animated.ValueXY = function() { this.x = new Animated.Value(0); this.y = new Animated.Value(0); };

export var StatusBar = {
  setBarStyle: function() {},
  setBackgroundColor: function() {},
  currentHeight: 0
};

export var RefreshControl = function() {};
export var PanResponder = {
  create: function() { return { panHandlers: {} }; }
};
export var Share = {
  share: function() { return Promise.resolve({ action: 'sharedAction' }); },
  sharedAction: 'sharedAction',
  dismissedAction: 'dismissedAction'
};
export var KeyboardAvoidingView = function() {};
export var TouchableNativeFeedback = function() {};

export var Appearance = {
  getColorScheme: function() { return 'light'; },
  addChangeListener: function() { return { remove: function() {} }; },
  setColorScheme: null
};

export var AppRegistry = {
  registerComponent: function() {}
};
