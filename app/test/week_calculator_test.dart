import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/core/utils/week_calculator.dart';

void main() {
  group('mondayOf 周一归位', () {
    test('周一当天不变', () {
      expect(mondayOf(DateTime(2026, 3, 2)),
          DateTime(2026, 3, 2)); // 2026-03-02 是周一
    });
    test('周日归位到同周周一', () {
      expect(mondayOf(DateTime(2026, 3, 8)), DateTime(2026, 3, 2));
    });
    test('跨月归位', () {
      expect(mondayOf(DateTime(2026, 3, 1)), DateTime(2026, 2, 23)); // 3月1日是周日
    });
  });

  group('weekNumberOf 周数计算', () {
    final start = DateTime(2026, 3, 2); // 开学第一周周一

    test('开学第一天 = 第 1 周', () {
      expect(weekNumberOf(start, start), 1);
    });
    test('第一周周日仍 = 第 1 周', () {
      expect(weekNumberOf(start, DateTime(2026, 3, 8)), 1);
    });
    test('第二个周一 = 第 2 周', () {
      expect(weekNumberOf(start, DateTime(2026, 3, 9)), 2);
    });
    test('开学前一天 = 第 0 周', () {
      expect(weekNumberOf(start, DateTime(2026, 3, 1)), 0);
    });
    test('开学前一周 = 负数', () {
      expect(weekNumberOf(start, DateTime(2026, 2, 23)), lessThan(1));
    });
    test('跨年学期：12 月底开学，次年 1 月周数连续', () {
      final winterStart = DateTime(2026, 12, 28); // 周一
      expect(weekNumberOf(winterStart, DateTime(2027, 1, 4)), 2);
      expect(weekNumberOf(winterStart, DateTime(2027, 1, 1)), 1);
    });
    test('超出总周数仍照常返回（第 21 周）', () {
      expect(weekNumberOf(start, start.add(const Duration(days: 20 * 7))), 21);
    });
    test('目标带时间分量不影响结果', () {
      expect(weekNumberOf(start, DateTime(2026, 3, 9, 23, 59)), 2);
    });
  });

  group('occursInWeek 单双周判断', () {
    test('每周：任何正周都上课', () {
      expect(occursInWeek(WeeksType.every, const [], 1), isTrue);
      expect(occursInWeek(WeeksType.every, const [], 20), isTrue);
    });
    test('单周：1/3/5 上课，2/4 不上', () {
      expect(occursInWeek(WeeksType.odd, const [], 1), isTrue);
      expect(occursInWeek(WeeksType.odd, const [], 2), isFalse);
      expect(occursInWeek(WeeksType.odd, const [], 17), isTrue);
    });
    test('双周：第 1 周不上，2/4 上', () {
      expect(occursInWeek(WeeksType.even, const [], 1), isFalse);
      expect(occursInWeek(WeeksType.even, const [], 2), isTrue);
      expect(occursInWeek(WeeksType.even, const [], 16), isTrue);
    });
    test('自定义：只在列表内上课', () {
      const weeks = [1, 3, 5, 6, 7, 8, 12];
      expect(occursInWeek(WeeksType.custom, weeks, 3), isTrue);
      expect(occursInWeek(WeeksType.custom, weeks, 4), isFalse);
      expect(occursInWeek(WeeksType.custom, weeks, 12), isTrue);
    });
    test('开学前（周 ≤ 0）一律不上课', () {
      expect(occursInWeek(WeeksType.every, const [], 0), isFalse);
      expect(occursInWeek(WeeksType.every, const [], -3), isFalse);
    });
  });

  group('parseCustomWeeks 自定义周次解析', () {
    test('逗号分隔', () {
      expect(parseCustomWeeks('1,3,5'), [1, 3, 5]);
    });
    test('区间展开', () {
      expect(parseCustomWeeks('5-8'), [5, 6, 7, 8]);
    });
    test('混合 + 中文分隔符 + 去重排序', () {
      expect(parseCustomWeeks('12，1,3、5-8 3'), [1, 3, 5, 6, 7, 8, 12]);
    });
    test('非法输入被忽略', () {
      expect(parseCustomWeeks('abc,,-1,,'), isEmpty);
      expect(parseCustomWeeks(''), isEmpty);
    });
    test('倒序区间被忽略', () {
      expect(parseCustomWeeks('8-5'), isEmpty);
    });
  });

  group('describeWeeks 展示文本', () {
    test('各类型文案', () {
      expect(describeWeeks(WeeksType.every, const []), '每周');
      expect(describeWeeks(WeeksType.odd, const []), '单周');
      expect(describeWeeks(WeeksType.even, const []), '双周');
      expect(describeWeeks(WeeksType.custom, const [1, 2]), '第 1、2 周');
      expect(describeWeeks(WeeksType.custom, const []), '未设置周次');
    });
  });

  group('clampWeek 展示区间收敛', () {
    test('学期内原样返回', () {
      expect(clampWeek(5, 20), 5);
    });
    test('开学前/已结束返回 null（假期中）', () {
      expect(clampWeek(0, 20), isNull);
      expect(clampWeek(21, 20), isNull);
    });
  });
}
