import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseCapture, tryParseJson, parseWeeksText, htmlToText } from '../entry/src/main/ets/features/course_import/YzuParser.ts';

test('扬大 URP 接口 JSON:嵌套 id(skxq/skjc)+ cxjc + 拆分地点', () => {
  const body = JSON.stringify({
    code: 200,
    data: {
      courseList: [
        {
          kcm: '流体热力学1（引进）',
          jsm: '教师B* 外教1',
          id: { skxq: 3, skjc: 1 },
          cxjc: 2,
          zcsm: '1-16周',
          xqm: '扬子津东校区',
          jxlm: '文津楼',
          jasm: 'N204'
        },
        {
          kcm: '大学物理Ⅳ',
          jsm: '教师A*',
          id: { skxq: 5, skjc: 3, cxjc: 2 },
          zcd: '1-15周单',
          skdd: '江阳路南校区主楼S201'
        }
      ]
    }
  });
  const courses = tryParseJson(body);
  assert.notEqual(courses, null);
  assert.equal(courses.length, 2);
  const fluid = courses.find((c) => c.name.includes('流体'));
  assert.equal(fluid.slots.length, 1);
  assert.equal(fluid.slots[0].dayOfWeek, 3);
  assert.equal(fluid.slots[0].startSection, 1);
  assert.equal(fluid.slots[0].endSection, 2);
  assert.equal(fluid.slots[0].location, '扬子津东校区文津楼N204');
  const physics = courses.find((c) => c.name.includes('物理'));
  assert.equal(physics.slots[0].weeksType, 3);
  assert.deepEqual(physics.slots[0].customWeeks, [1, 3, 5, 7, 9, 11, 13, 15]);
});

test('timeAndPlaceList 嵌套时间段', () => {
  const body = JSON.stringify({
    kbList: [
      {
        kcmc: '概率论与数理统计Ⅱ',
        jsxm: '教师C*',
        timeAndPlaceList: [
          { xqj: '2', jcdm: '3-4', zcd: '1-16周', cdmc: '文津楼N302' },
          { xqj: '4', jcdm: '3-4', zcd: '1-16周', cdmc: '文津楼N302' }
        ]
      }
    ]
  });
  const courses = tryParseJson(body);
  assert.notEqual(courses, null);
  assert.equal(courses[0].slots.length, 2);
  assert.equal(courses[0].slots[1].dayOfWeek, 4);
  assert.equal(courses[0].slots[0].endSection, 4);
});

test('周次文本解析矩阵', () => {
  assert.deepEqual(parseWeeksText(''), [0, []]);
  assert.deepEqual(parseWeeksText('1-16周')[1].length, 16);
  assert.deepEqual(parseWeeksText('单周'), [1, []]);
  assert.deepEqual(parseWeeksText('双周'), [2, []]);
  assert.deepEqual(parseWeeksText('1,3,5-7周')[1], [1, 3, 5, 6, 7]);
  assert.deepEqual(parseWeeksText('2-16周双')[1][0], 2);
  assert.equal(parseWeeksText('1-15周单')[1].every((w) => w % 2 === 1), true);
});

test('parseCapture:嗅探包 → JSON 命中', () => {
  const capture = JSON.stringify({
    url: 'https://jw.yzu.edu.cn/student/kb',
    title: '课表',
    html: '<html></html>',
    captured: [
      { url: 'https://static/logo.png', body: 'not-json' },
      {
        url: 'https://jw.yzu.edu.cn/api/classCurriculum',
        body: JSON.stringify([{ kcm: '测试课', jsm: '张三', xqj: 1, jcs: '1-2', zcd: '1-12周', jxcdm: 'A101' }])
      }
    ],
    frames: []
  });
  const result = parseCapture(capture);
  assert.equal(result.source, 'json');
  assert.equal(result.courses.length, 1);
  assert.equal(result.courses[0].slots[0].dayOfWeek, 1);
  assert.ok(result.detail.includes('classCurriculum'));
});

test('parseCapture:HTML 块状清单兜底(青果 >> 格式)', () => {
  const inner = '大学物理Ⅳ | 080601_4 4学分\n教师A*\n1-16周>>星期四>>1-2节\n扬子津东校区>>文津楼>>N107';
  const capture = JSON.stringify({
    url: 'https://webvpn.yzu.edu.cn/kb',
    title: '本学期课表',
    html: `<html><body><table><tr><td>${inner.split('\n').join('<br>')}</td></tr></table></body></html>`,
    captured: [],
    frames: []
  });
  const result = parseCapture(capture);
  assert.equal(result.source, 'html');
  assert.equal(result.courses.length, 1);
  assert.equal(result.courses[0].name, '大学物理Ⅳ');
  assert.equal(result.courses[0].slots[0].dayOfWeek, 4);
});

test('parseCapture:全部失败 → none + 诊断', () => {
  const capture = JSON.stringify({
    url: 'https://example.com', title: '首页', html: '<html>nothing</html>', captured: [], frames: []
  });
  const result = parseCapture(capture);
  assert.equal(result.source, 'none');
  assert.equal(result.courses.length, 0);
  assert.ok(result.detail.length > 0);
});

test('htmlToText 去标签转行', () => {
  const text = htmlToText('<p>大学物理</p><tr><td>1-16周</td><td>文津楼</td></tr>');
  assert.ok(text.includes('大学物理'));
  assert.ok(text.includes('文津楼'));
  assert.equal(text.includes('<'), false);
});
