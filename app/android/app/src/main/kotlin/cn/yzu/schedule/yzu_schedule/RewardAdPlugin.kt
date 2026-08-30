package cn.yzu.schedule.yzu_schedule

import android.app.Activity
import android.os.Handler
import android.os.Looper
import com.bytedance.sdk.openadsdk.AdSlot
import com.bytedance.sdk.openadsdk.TTAdConstant
import com.bytedance.sdk.openadsdk.TTAdNative
import com.bytedance.sdk.openadsdk.TTAdSdk
import com.bytedance.sdk.openadsdk.TTRewardVideoAd
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 穿山甲激励视频广告桥接（「看广告支持作者」，v1.0.32）。
 *
 * 设计约束：
 * - AppID / 广告位 ID 全部由 Dart 侧经 --dart-define 注入后通过 MethodChannel
 *   传入，未配置时 Dart 侧不显示入口，原生侧 init 会直接报 not_configured。
 * - 整个加载→展示→关闭流程只为 MethodChannel.Result 产出一次结果；
 *   rewarded=true 仅在奖励发放（onRewardArrived/onRewardVerify）后关闭时返回。
 */
object RewardAdPlugin {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val initStarted = AtomicBoolean(false)
    private var initReady = false
    private var initError: String? = null
    private val initWaiters = mutableListOf<(Boolean, String?) -> Unit>()

    fun handle(
        activity: Activity,
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "init" -> {
                val appId = call.argument<String>("appId") ?: ""
                if (appId.isBlank()) {
                    result.error("not_configured", "广告服务未配置", null)
                    return
                }
                ensureInit(activity, appId) { ok, err ->
                    if (ok) result.success(true)
                    else result.error("init_failed", err ?: "广告服务初始化失败", null)
                }
            }
            "show" -> {
                val slotId = call.argument<String>("slotId") ?: ""
                val userId = call.argument<String>("userId") ?: ""
                if (slotId.isBlank()) {
                    result.error("not_configured", "广告位未配置", null)
                    return
                }
                ensureInit(
                    activity,
                    call.argument<String>("appId") ?: "",
                ) { ok, err ->
                    if (!ok) {
                        result.error("init_failed", err ?: "广告服务初始化失败", null)
                        return@ensureInit
                    }
                    showRewardVideo(activity, slotId, userId, result)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun ensureInit(
        activity: Activity,
        appId: String,
        callback: (Boolean, String?) -> Unit,
    ) {
        mainHandler.post {
            if (initReady) {
                callback(true, null)
                return@post
            }
            initError?.let {
                callback(false, it)
                return@post
            }
            initWaiters.add(callback)
            if (!initStarted.compareAndSet(false, true)) return@post

            val config = com.bytedance.sdk.openadsdk.TTAdConfig.Builder()
                .appId(appId)
                .appName("邗上课表")
                .allowShowNotify(true)
                .debug(false)
                .directDownloadNetworkType(TTAdConstant.NETWORK_STATE_WIFI)
                .build()
            TTAdSdk.init(activity.applicationContext, config)
            TTAdSdk.start(object : TTAdSdk.Callback {
                override fun success() {
                    initReady = true
                    drainWaiters(true, null)
                }

                override fun fail(code: Int, msg: String?) {
                    initError = "初始化失败($code) ${msg ?: ""}".trim()
                    drainWaiters(false, initError)
                }
            })
        }
    }

    private fun drainWaiters(ok: Boolean, err: String?) {
        val waiters = ArrayList<(Boolean, String?) -> Unit>(initWaiters)
        initWaiters.clear()
        for (w in waiters) w(ok, err)
    }

    private var currentResult: MethodChannel.Result? = null
    private var rewarded = false

    private fun showRewardVideo(
        activity: Activity,
        slotId: String,
        userId: String,
        result: MethodChannel.Result,
    ) {
        if (currentResult != null) {
            result.error("busy", "广告正在播放中", null)
            return
        }
        currentResult = result
        rewarded = false

        val adNative: TTAdNative = TTAdSdk.getAdManager().createAdNative(activity)
        val slot = AdSlot.Builder()
            .setCodeId(slotId)
            .setSupportDeepLink(true)
            .setRewardName("支持")
            .setRewardAmount(1)
            .setUserID(userId.ifBlank { "anonymous" })
            .setMediaExtra("support_author")
            .setOrientation(TTAdConstant.VERTICAL)
            .build()

        adNative.loadRewardVideoAd(slot, object : TTAdNative.RewardVideoAdListener {
            override fun onError(code: Int, message: String?) {
                settle("load_failed", "广告加载失败($code) ${message ?: ""}".trim(), null)
            }

            override fun onRewardVideoAdLoad(ad: TTRewardVideoAd?) {
                if (ad == null) {
                    settle("load_failed", "广告加载失败（空广告对象）", null)
                    return
                }
                ad.setRewardAdInteractionListener(object :
                    TTRewardVideoAd.RewardAdInteractionListener {
                    override fun onAdShow() {}

                    override fun onAdVideoBarClick() {}

                    override fun onVideoComplete() {}

                    override fun onVideoError() {}

                    override fun onRewardVerify(
                        verify: Boolean,
                        rewardAmount: Int,
                        rewardName: String?,
                        errorCode: Int,
                        errorMsg: String?,
                    ) {
                        if (verify) rewarded = true
                    }

                    override fun onRewardArrived(
                        arrived: Boolean,
                        rewardType: Int,
                        extraInfo: android.os.Bundle?,
                    ) {
                        if (arrived) rewarded = true
                    }

                    override fun onSkippedVideo() {}

                    override fun onAdClose() {
                        settle(null, null, mapOf("rewarded" to rewarded))
                    }
                })
                ad.showRewardVideoAd(activity)
            }

            override fun onRewardVideoCached() {}

            override fun onRewardVideoCached(ad: TTRewardVideoAd?) {}
        })
    }

    /** 统一结算：保证 result 只被调用一次，且切换到主线程。 */
    private fun settle(errorCode: String?, errorMessage: String?, success: Map<String, Any?>?) {
        val r = currentResult ?: return
        currentResult = null
        mainHandler.post {
            if (errorCode != null) r.error(errorCode, errorMessage, null)
            else r.success(success)
        }
    }
}
