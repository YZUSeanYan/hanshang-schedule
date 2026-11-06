/*
 * 课前提醒 —— 微信订阅消息的降级实现。
 *
 * 这是本次移植里唯一「功能变弱」的地方，原因写在评估里、也写在这里免得日后
 * 有人以为是漏做：小程序既没有 Web Push，也没有后台定时能力，订阅消息还必须
 * 由用户点击触发、授权一次换一条额度，做不到 App 那种「开一次就一直提醒」。
 *
 * 因此这里的策略是：
 *   用户每点一次「开启课前提醒」→ 静默攒 1 条发送额度（勾选过"总是保持以上
 *   选择"后不再弹窗），额度由服务端在需要时消费。
 *
 * 注意：客户端的额度只是「允许发送」，真正送达还需要服务端用 openid +
 * 模板 ID 调 subscribe/send 接口，并且要有一个按作息扫课的定时任务。
 * 那部分属于后端新增能力，不在本次小程序移植范围内——所以模板未配置时
 * 这里不做任何假动作，直接把原因显示给用户，而不是显示一个点了没用按钮。
 */
const { SUBSCRIBE_TEMPLATE_ID } = require("./config");
const store = require("./store");

function isConfigured() {
  return Boolean(SUBSCRIBE_TEMPLATE_ID);
}

function statusText() {
  if (!SUBSCRIBE_TEMPLATE_ID) return "订阅消息模板未配置（需公众平台申请后填入 utils/config.js）";
  const quota = store.readSubscribeQuota();
  return quota.granted
    ? `今日已攒 ${quota.granted} 次额度`
    : "点按开启，每次点击可攒一条课前提醒";
}

/*
 * 发起订阅。必须在用户点击事件里同步调用（微信的硬性要求），
 * 所以调用方直接把它挂在按钮的 bindtap 上，不要包在 await 之后。
 */
function request() {
  return new Promise((resolve, reject) => {
    if (!SUBSCRIBE_TEMPLATE_ID) {
      reject(new Error("订阅消息模板未配置"));
      return;
    }
    wx.requestSubscribeMessage({
      tmplIds: [SUBSCRIBE_TEMPLATE_ID],
      success: (res) => {
        const result = res[SUBSCRIBE_TEMPLATE_ID];
        if (result === "accept") store.bumpSubscribeQuota();
        resolve(result);
      },
      fail: (error) => reject(error),
    });
  });
}

module.exports = { isConfigured, statusText, request };
