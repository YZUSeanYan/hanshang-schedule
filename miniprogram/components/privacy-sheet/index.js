/*
 * 隐私政策弹层。正文与网页版/App 第 6 版同一份，只把与平台相关的机制描述
 * 改成小程序实际情况（网页版写的是 Web Push，小程序写微信订阅消息；语音录入
 * 仍是 Android App 专有，保留原说明以免遗漏已声明的处理目的）。
 * 正文直接写在 wxml 里，避免长文本在 JS 字符串里转义出错。
 */
Component({
  options: { styleIsolation: "apply-shared" },

  properties: {
    show: { type: Boolean, value: false },
  },

  methods: {
    close() {
      this.setData({ show: false });
      this.triggerEvent("close");
    },
  },
});
