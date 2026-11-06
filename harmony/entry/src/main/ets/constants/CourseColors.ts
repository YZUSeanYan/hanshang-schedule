/**
 * 课程块默认配色：柔和马卡龙色系。
 * 移植自 Flutter 版 app/lib/core/constants/course_colors.dart。
 *
 * 颜色一律用 ARGB 整数（与数据库 color 字段、服务端同步格式一致），
 * UI 侧再转成 '#AARRGGBB' 字符串。纯逻辑（无 @ohos 依赖），node 单测覆盖。
 *
 * 哈希语义与 Dart 版完全一致：Dart String.codeUnits 是 UTF-16 代码单元，
 * 等价于 JS 的 charCodeAt；掩码 & 0x7fffffff 取低 31 位，两种语言结果相同。
 */

/** 马卡龙 10 色盘（ARGB） */
export const MACARON: number[] = [
  0xFFA8D8EA, // 浅蓝
  0xFFFFCBCB, // 浅粉
  0xFFB5EAD7, // 薄荷绿
  0xFFFFDAC1, // 浅橙
  0xFFC7CEEA, // 薰衣草
  0xFFF6E6AD, // 鹅黄
  0xFFA2E1DB, // 青绿
  0xFFF3B0C3, // 玫粉
  0xFFBFD8B8, // 豆绿
  0xFFE7C6E7, // 浅紫
];

/** 深色文字（浅色背景用），Flutter 版 0xFF1A1A1A */
export const TEXT_DARK = 0xFF1A1A1A;
/** 白色文字（深色背景用） */
export const TEXT_WHITE = 0xFFFFFFFF;

/** 按课程名稳定分配一个默认颜色（同课名同色） */
export function forCourseName(name: string): number {
  let hash = 0;
  for (let i = 0; i < name.length; i++) {
    hash = (hash * 31 + name.charCodeAt(i)) & 0x7fffffff;
  }
  return MACARON[hash % MACARON.length];
}

/**
 * 课程块文字颜色：按背景亮度自动选黑/白，保证深浅色下都可读。
 * 亮度公式与 Flutter Color.computeLuminance 一致（sRGB 相对亮度线性化）。
 */
export function textOn(background: number): number {
  return computeLuminance(background) > 0.5 ? TEXT_DARK : TEXT_WHITE;
}

/** sRGB 相对亮度（0-1），与 Flutter Color.computeLuminance 算法一致 */
export function computeLuminance(argb: number): number {
  const r = linearize(((argb >> 16) & 0xff) / 255.0);
  const g = linearize(((argb >> 8) & 0xff) / 255.0);
  const b = linearize((argb & 0xff) / 255.0);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

function linearize(c: number): number {
  return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
}

/** ARGB 整数 → '#AARRGGBB'（ArkUI 背景色用字符串形式） */
export function argbToCss(argb: number): string {
  const a = (argb >>> 24) & 0xff;
  const r = (argb >>> 16) & 0xff;
  const g = (argb >>> 8) & 0xff;
  const b = argb & 0xff;
  const hex = (v: number): string => (v < 16 ? `0${v.toString(16)}` : v.toString(16));
  return `#${hex(a)}${hex(r)}${hex(g)}${hex(b)}`;
}
