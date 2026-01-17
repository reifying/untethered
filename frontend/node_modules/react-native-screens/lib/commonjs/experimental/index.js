"use strict";

Object.defineProperty(exports, "__esModule", {
  value: true
});
var _exportNames = {
  ScreenStackHost: true,
  StackScreen: true,
  StackScreenLifecycleState: true,
  SplitViewHost: true,
  SplitViewScreen: true,
  SafeAreaView: true
};
Object.defineProperty(exports, "SafeAreaView", {
  enumerable: true,
  get: function () {
    return _SafeAreaView.default;
  }
});
Object.defineProperty(exports, "ScreenStackHost", {
  enumerable: true,
  get: function () {
    return _ScreenStackHost.default;
  }
});
Object.defineProperty(exports, "SplitViewHost", {
  enumerable: true,
  get: function () {
    return _SplitViewHost.default;
  }
});
Object.defineProperty(exports, "SplitViewScreen", {
  enumerable: true,
  get: function () {
    return _SplitViewScreen.default;
  }
});
Object.defineProperty(exports, "StackScreen", {
  enumerable: true,
  get: function () {
    return _StackScreen.default;
  }
});
Object.defineProperty(exports, "StackScreenLifecycleState", {
  enumerable: true,
  get: function () {
    return _StackScreen.StackScreenLifecycleState;
  }
});
var _types = require("./types");
Object.keys(_types).forEach(function (key) {
  if (key === "default" || key === "__esModule") return;
  if (Object.prototype.hasOwnProperty.call(_exportNames, key)) return;
  if (key in exports && exports[key] === _types[key]) return;
  Object.defineProperty(exports, key, {
    enumerable: true,
    get: function () {
      return _types[key];
    }
  });
});
var _ScreenStackHost = _interopRequireDefault(require("../components/gamma/stack/ScreenStackHost"));
var _StackScreen = _interopRequireWildcard(require("../components/gamma/stack/StackScreen"));
var _SplitViewHost = _interopRequireDefault(require("../components/gamma/split-view/SplitViewHost"));
var _SplitViewScreen = _interopRequireDefault(require("../components/gamma/split-view/SplitViewScreen"));
var _SafeAreaView = _interopRequireDefault(require("../components/safe-area/SafeAreaView"));
function _getRequireWildcardCache(e) { if ("function" != typeof WeakMap) return null; var r = new WeakMap(), t = new WeakMap(); return (_getRequireWildcardCache = function (e) { return e ? t : r; })(e); }
function _interopRequireWildcard(e, r) { if (!r && e && e.__esModule) return e; if (null === e || "object" != typeof e && "function" != typeof e) return { default: e }; var t = _getRequireWildcardCache(r); if (t && t.has(e)) return t.get(e); var n = { __proto__: null }, a = Object.defineProperty && Object.getOwnPropertyDescriptor; for (var u in e) if ("default" !== u && {}.hasOwnProperty.call(e, u)) { var i = a ? Object.getOwnPropertyDescriptor(e, u) : null; i && (i.get || i.set) ? Object.defineProperty(n, u, i) : n[u] = e[u]; } return n.default = e, t && t.set(e, n), n; }
function _interopRequireDefault(e) { return e && e.__esModule ? e : { default: e }; }
//# sourceMappingURL=index.js.map