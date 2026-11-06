/*
 * JS 侧调色板（与 app.wxss 中的 CSS 变量一一对应）。
 *
 * 为什么要在 JS 里再写一份：小程序的 <image> 不能继承 currentColor，
 * 图标只能把颜色编码进 SVG 数据 URI；而 JS 读不到 WXSS 的 CSS 变量。
 * 于是这里作为唯一真源给图标取色，改动时需与 app.wxss 同步（两处都标了同名注释）。
 */
const LIGHT = {
  primary: "#206A4E",
  onPrimary: "#FFFFFF",
  primaryContainer: "#A8F2CE",
  onPrimaryContainer: "#005138",
  secondaryContainer: "#CFE9D9",
  onSecondaryContainer: "#354B40",
  error: "#BA1A1A",
  onErrorContainer: "#93000A",
  surface: "#F5FBF5",
  surfaceLowest: "#FFFFFF",
  onSurface: "#171D1A",
  onSurfaceVariant: "#404943",
  outline: "#707973",
  inverseSurface: "#2C322E",
  inverseOnSurface: "#EDF2EC",
};

const DARK = {
  primary: "#8DD5B2",
  onPrimary: "#003826",
  primaryContainer: "#005138",
  onPrimaryContainer: "#A8F2CE",
  secondaryContainer: "#354B40",
  onSecondaryContainer: "#CFE9D9",
  error: "#FFB4AB",
  onErrorContainer: "#FFDAD6",
  surface: "#121417",
  surfaceLowest: "#0A0F0C",
  onSurface: "#DEE4DE",
  onSurfaceVariant: "#BFC9C2",
  outline: "#8A938C",
  inverseSurface: "#DEE4DE",
  inverseOnSurface: "#2C322E",
};

// 语义 tone → 调色板键；页面只写 tone，不关心深浅色
const TONES = {
  primary: "primary",
  "on-primary": "onPrimary",
  "primary-container": "primaryContainer",
  "on-primary-container": "onPrimaryContainer",
  "on-secondary-container": "onSecondaryContainer",
  error: "error",
  "on-surface": "onSurface",
  "on-surface-variant": "onSurfaceVariant",
  outline: "outline",
  "inverse-on-surface": "inverseOnSurface",
  base: "onSurface",
};

function palette(dark) {
  return dark ? DARK : LIGHT;
}

function colorOf(tone, dark) {
  const board = palette(dark);
  const key = TONES[tone] || TONES.base;
  return board[key] || board.onSurface;
}

module.exports = { LIGHT, DARK, palette, colorOf };
