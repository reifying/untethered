"use strict";

Object.defineProperty(exports, "__esModule", {
  value: true
});
var _BottomTabs = require("./components/bottom-tabs/BottomTabs.types");
Object.keys(_BottomTabs).forEach(function (key) {
  if (key === "default" || key === "__esModule") return;
  if (key in exports && exports[key] === _BottomTabs[key]) return;
  Object.defineProperty(exports, key, {
    enumerable: true,
    get: function () {
      return _BottomTabs[key];
    }
  });
});
var _BottomTabsScreen = require("./components/bottom-tabs/BottomTabsScreen.types");
Object.keys(_BottomTabsScreen).forEach(function (key) {
  if (key === "default" || key === "__esModule") return;
  if (key in exports && exports[key] === _BottomTabsScreen[key]) return;
  Object.defineProperty(exports, key, {
    enumerable: true,
    get: function () {
      return _BottomTabsScreen[key];
    }
  });
});
var _types = require("./components/shared/types");
Object.keys(_types).forEach(function (key) {
  if (key === "default" || key === "__esModule") return;
  if (key in exports && exports[key] === _types[key]) return;
  Object.defineProperty(exports, key, {
    enumerable: true,
    get: function () {
      return _types[key];
    }
  });
});
//# sourceMappingURL=types.js.map