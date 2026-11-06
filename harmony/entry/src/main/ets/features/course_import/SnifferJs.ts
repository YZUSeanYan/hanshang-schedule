/**
 * 注入教务页面的课表嗅探脚本(WebView 内运行)。
 * 移植自 Flutter 版 lib/import/sniffer_js.dart,逻辑逐行对齐。
 *
 * 安全红线:只缓存"疑似课表"的 fetch/XHR 响应到 window.__yzuCaptured,
 * 不读取密码输入框,不主动提交任何请求。
 */

/** 页面加载完成后注入:劫持 fetch/XHR,缓存疑似课表的响应 */
export const SNIFFER_INJECT_JS: string = `
(function () {
  if (window.__yzuSnifferInstalled) return 'installed';
  window.__yzuSnifferInstalled = true;
  window.__yzuCaptured = [];

  var URL_HINT = /kb|schedule|course|curriculum|teachingResources|timetable|kbcx|xsxk|xskb|wdkb|mycourse/i;
  var BODY_HINT = /kcmc|"kcm"|courseName|course_name|selectCourseList|timeAndPlaceList|jsxm|"jsm"|teacherName|attendClassTeacher|zcd|zcsm|weeksText|weekDescription|xqj|skxq|skjc|weekDay|classDay|classSessions/i;
  var MAX_KEEP = 30;

  function looksUseful(url, text) {
    if (!text || text.length < 20 || text.length > 2 * 1024 * 1024) return false;
    if (URL_HINT.test(url || '')) return true;
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
    } catch (e) { }
  }

  var origFetch = window.fetch;
  if (origFetch) {
    window.fetch = function () {
      return origFetch.apply(this, arguments).then(function (resp) {
        try {
          resp.clone().text().then(function (text) {
            keep(resp.url, text);
          });
        } catch (e) { }
        return resp;
      });
    };
  }

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
      } catch (e) { }
    });
    return origSend.apply(this, arguments);
  };

  return 'ok';
})();
`;

/** 收集抓取结果:{url,title,html,captured,frames}(JSON 字符串) */
export const SNIFFER_COLLECT_JS: string = `
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
    } catch (e) { }
  }

  walkFrame(window, 0);
  return JSON.stringify(result);
})();
`;
