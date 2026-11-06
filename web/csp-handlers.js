// CSP 外置化（2026-10-02）：原 index.html 内联 onclick（导出到日历按钮）迁出
document.addEventListener('DOMContentLoaded', () => {
  const btn = document.getElementById('export-calendar');
  if (btn) btn.addEventListener('click', () => {
    if (typeof window.exportToCalendar === 'function') window.exportToCalendar();
    else alert('导出模块未加载成功，请强制刷新页面');
  });
});
