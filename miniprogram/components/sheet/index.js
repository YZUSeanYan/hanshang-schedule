/*
 * 通用底部弹层，替代网页版的 <dialog>。
 *
 * 网页版用 dialog.showModal() 拿到焦点陷阱、Esc 关闭、::backdrop 等一整套浏览器能力；
 * 小程序没有对应物，这里用 fixed 遮罩 + 面板自己实现，并保留网页版的三条行为：
 * 点遮罩关闭、内容区可独立滚动、动作按钮固定在底部不随内容滚动。
 *
 * 进出场都有动画：进场在 .sheet-panel 里定义；退场必须先播动画再触发 close，
 * 因为外层 wx:if="{{show}}" 会立刻摘掉节点，不做延迟就只剩「瞬移」。
 */
Component({
  // multipleSlots：默认插槽放内容、actions 具名插槽放底部按钮
  options: { styleIsolation: "apply-shared", multipleSlots: true },

  properties: {
    show: { type: Boolean, value: false },
    title: { type: String, value: "" },
    sub: { type: String, value: "" },
    // 点遮罩是否关闭：表单类弹层关掉它，避免误触丢失已填内容
    maskClosable: { type: Boolean, value: true },
    // 是否有底部动作区（小程序无法探测具名插槽是否为空，由调用方显式声明）
    hasActions: { type: Boolean, value: false },
  },

  data: { closing: false },

  methods: {
    // 退场动画播完再通知外层把 show 置 false
    dismiss() {
      if (this.data.closing) return;
      this.setData({ closing: true });
      setTimeout(() => {
        this.setData({ closing: false });
        this.triggerEvent("close");
      }, 200);
    },

    onMaskTap() {
      if (!this.data.maskClosable) return;
      this.dismiss();
    },

    onCloseTap() {
      this.dismiss();
    },

    // 遮罩层吞掉 touchmove，避免弹层打开时底下的课表跟着滚
    noop() {},
  },
});
