"use strict";

Object.defineProperty(exports, "__esModule", {
  value: true
});
exports.default = useReanimatedSheetProgress;
var React = _interopRequireWildcard(require("react"));
var _reactNativeReanimated = require("react-native-reanimated");
var _ReanimatedSheetProgressContext = _interopRequireDefault(require("./ReanimatedSheetProgressContext"));
function _interopRequireDefault(e) { return e && e.__esModule ? e : { default: e }; }
function _getRequireWildcardCache(e) { if ("function" != typeof WeakMap) return null; var r = new WeakMap(), t = new WeakMap(); return (_getRequireWildcardCache = function (e) { return e ? t : r; })(e); }
function _interopRequireWildcard(e, r) { if (!r && e && e.__esModule) return e; if (null === e || "object" != typeof e && "function" != typeof e) return { default: e }; var t = _getRequireWildcardCache(r); if (t && t.has(e)) return t.get(e); var n = { __proto__: null }, a = Object.defineProperty && Object.getOwnPropertyDescriptor; for (var u in e) if ("default" !== u && {}.hasOwnProperty.call(e, u)) { var i = a ? Object.getOwnPropertyDescriptor(e, u) : null; i && (i.get || i.set) ? Object.defineProperty(n, u, i) : n[u] = e[u]; } return n.default = e, t && t.set(e, n), n; }
// @ts-ignore file to be used only if `react-native-reanimated` available in the project

// Returns a Reanimated SharedValue tracking sheet openness in [0,1] (1 = settled open, 0 = dismissed),
// updated every frame on the UI thread during the open animation, interactive drag, and dismiss.
// Falls back to a constant 1 SharedValue when not inside a Native Stack sheet screen (no provider),
// so consumers never crash if the screen isn't a sheet.
function useReanimatedSheetProgress() {
  const fallback = (0, _reactNativeReanimated.useSharedValue)(1);
  const sheetProgress = React.useContext(_ReanimatedSheetProgressContext.default);
  return sheetProgress ?? fallback;
}
//# sourceMappingURL=useReanimatedSheetProgress.js.map