"use strict";

Object.defineProperty(exports, "__esModule", {
  value: true
});
var _exportNames = {
  internalEnableDetailedBottomTabsLogging: true,
  bottomTabsDebugLog: true
};
Object.defineProperty(exports, "bottomTabsDebugLog", {
  enumerable: true,
  get: function () {
    return _logging.bottomTabsDebugLog;
  }
});
Object.defineProperty(exports, "internalEnableDetailedBottomTabsLogging", {
  enumerable: true,
  get: function () {
    return _logging.internalEnableDetailedBottomTabsLogging;
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
var _logging = require("./logging");
//# sourceMappingURL=index.js.map