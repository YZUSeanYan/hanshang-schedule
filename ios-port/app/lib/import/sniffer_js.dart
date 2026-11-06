/// 注入教务页面抓取课表的 JavaScript 嗅探脚本（设计文档 4.2）。
///
/// 思路：拦截 fetch / XMLHttpRequest 的响应，凡是"看起来像课表接口"
/// （URL 含 kb/schedule/course 等关键词，或响应 JSON 里含课名+星期字段）
/// 的都暂存到 window.__yzuCaptured；最后由 evaluateJavascript 收集
/// { url, title, html, captured } 打包传回 Dart 侧解析。
///
/// 安全红线：脚本只在 WebView 进程内运行，只收集课表相关内容，
/// 不读取密码输入框，不主动提交任何请求。
library;

/// 页面加载完成后注入：劫持 fetch/XHR，缓存疑似课表的响应
const String kYzuSnifferInjectJs = r'''
(function () {
  if (window.__yzuSnifferInstalled) return 'installed';
  window.__yzuSnifferInstalled = true;
  window.__yzuCaptured = [];

  // 扬大 URP 的真实接口使用 classCurriculum/curriculum，字段则是
  // kcm/jsm/zcsm + id.skxq/id.skjc。不能只匹配常见的 kcmc/xqj 方言。
  var URL_HINT = /kb|schedule|course|curriculum|teachingResources|timetable|kbcx|xsxk|xskb|wdkb|mycourse/i;
  var BODY_HINT = /kcmc|\"kcm\"|courseName|course_name|selectCourseList|timeAndPlaceList|jsxm|\"jsm\"|teacherName|attendClassTeacher|zcd|zcsm|weeksText|weekDescription|xqj|skxq|skjc|weekDay|classDay|classSessions/i;
  var MAX_KEEP = 30;

  function looksUseful(url, text) {
    if (!text || text.length < 20 || text.length > 2 * 1024 * 1024) return false;
    if (URL_HINT.test(url || '')) return true;
    // 内容试探：含中文课名/星期字段的 JSON 也收（URL 可能不含关键词）
    var head = text.slice(0, 4000);
    return BODY_HINT.test(head);
  }

  function keep(url, body) {
    try {
      if (!looksUseful(url, body)) return;
      window.__yzuCaptured.push({ url: String(url || ''), body: body });
      if (window.__yzuCaptured.length > MAX_KEEP) {
        window.__yzuCaptured = window.__yzuCaptured.slice(-MAX_KEEP);
      }
    } catch (e) { /* 静默：绝不影响页面自身逻辑 */ }
  }

  // 劫持 fetch
  var origFetch = window.fetch;
  if (origFetch) {
    window.fetch = function () {
      return origFetch.apply(this, arguments).then(function (resp) {
        try {
          resp.clone().text().then(function (text) {
            keep(resp.url, text);
          });
        } catch (e) {}
        return resp;
      });
    };
  }

  // 劫持 XMLHttpRequest
  var origOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__yzuUrl = url;
    return origOpen.apply(this, arguments);
  };
  var origSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function () {
    var xhr = this;
    xhr.addEventListener('load', function () {
      try {
        if (xhr.responseType === '' || xhr.responseType === 'text') {
          keep(xhr.__yzuUrl, xhr.responseText);
        } else if (xhr.responseType === 'json' && xhr.response) {
          keep(xhr.__yzuUrl, JSON.stringify(xhr.response));
        }
      } catch (e) {}
    });
    return origSend.apply(this, arguments);
  };

  return 'ok';
})();
''';

/// 收集抓取结果。脚本会遍历浏览器允许访问的同源 iframe；跨域 frame 会被
/// 同源策略自动跳过，不使用 postMessage，也不会把页面数据发给其他 frame。
const String kYzuSnifferCollectJs = r'''
(function () {
  var result = {
    url: String(location.href),
    title: String(document.title || ''),
    html: (document.documentElement && document.documentElement.outerHTML) || '',
    captured: [],
    frames: []
  };

  function appendCaptured(items) {
    if (!Array.isArray(items)) return;
    items.forEach(function (item) {
      if (item && typeof item.body === 'string') result.captured.push(item);
    });
  }

  function walkFrame(frameWindow, depth) {
    if (depth > 6) return;
    try {
      appendCaptured(frameWindow.__yzuCaptured || []);
      if (frameWindow !== window) {
        result.frames.push({
          url: String(frameWindow.location.href || ''),
          title: String(frameWindow.document.title || ''),
          html: (frameWindow.document.documentElement &&
                 frameWindow.document.documentElement.outerHTML) || ''
        });
      }
      for (var i = 0; i < frameWindow.frames.length; i++) {
        walkFrame(frameWindow.frames[i], depth + 1);
      }
    } catch (e) {
      // 跨域 frame：浏览器会拒绝读取，安全跳过。
    }
  }

  walkFrame(window, 0);
  return JSON.stringify(result);
})();
''';
