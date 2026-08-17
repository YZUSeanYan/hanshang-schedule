package cn.yzu.schedule.yzu_schedule

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var transfer: WatchBleTransfer? = null
    private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 手表 BLE 课表传输
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hanshang/ble")
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startTransfer" -> {
                    val json = call.argument<String>("json") ?: ""
                    if (json.isBlank()) {
                        result.error("ble_error", "课表数据为空", null)
                        return@setMethodCallHandler
                    }
                    if (!hasBlePermissions()) {
                        requestBlePermissions()
                        result.success(mapOf("permission" to "requested"))
                        return@setMethodCallHandler
                    }
                    try {
                        transfer = WatchBleTransfer(this) { eventSink }
                        val ok = transfer?.start(json) ?: false
                        if (ok) {
                            result.success(mapOf("permission" to "granted"))
                        } else {
                            result.error("ble_error", "蓝牙不可用，请先开启蓝牙", null)
                        }
                    } catch (e: Exception) {
                        result.error("ble_error", e.message ?: "启动失败", null)
                    }
                }
                "stopTransfer" -> {
                    transfer?.stop()
                    transfer = null
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        val stateChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "hanshang/ble/state")
        stateChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })

        // 上课实时通知（灵动岛）
        val liveChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hanshang/course_live")
        liveChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    CourseLiveNotifier.update(
                        this,
                        call.argument<String>("title") ?: "上课中",
                        call.argument<String>("text") ?: "",
                        call.argument<Int>("progress") ?: 0,
                        call.argument<Int>("max") ?: 1,
                        call.argument<String>("shortText") ?: "上课中"
                    )
                    result.success(true)
                }
                "cancel" -> {
                    CourseLiveNotifier.cancel(this)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // 课前提醒通知快捷操作（勿扰模式开关）
        val reminderChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hanshang/reminder_action")
        reminderChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "toggleDnd" -> {
                    val manager = getSystemService(android.content.Context.NOTIFICATION_SERVICE)
                        as android.app.NotificationManager
                    if (manager.isNotificationPolicyAccessGranted) {
                        // 已授权：直接切换勿扰模式
                        val current = manager.currentInterruptionFilter
                        val newFilter =
                            if (current == android.app.NotificationManager.INTERRUPTION_FILTER_ALL)
                                android.app.NotificationManager.INTERRUPTION_FILTER_NONE
                            else android.app.NotificationManager.INTERRUPTION_FILTER_ALL
                        manager.setInterruptionFilter(newFilter)
                        result.success(
                            mapOf("enabled" to (newFilter != android.app.NotificationManager.INTERRUPTION_FILTER_ALL))
                        )
                    } else {
                        // 未授权：首次引导到勿扰访问权限页（仅此一次，之后一键直达）
                        try {
                            val intent = android.content.Intent(
                                android.provider.Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS
                            ).apply { addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK) }
                            startActivity(intent)
                            result.success(mapOf("enabled" to false, "needPermission" to true))
                        } catch (e: Exception) {
                            result.error("settings_error", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        transfer?.stop()
        transfer = null
        super.onDestroy()
    }

    private fun hasBlePermissions(): Boolean {
        return if (Build.VERSION.SDK_INT >= 31) {
            checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED &&
                checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED &&
                checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED
        } else {
            checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requestBlePermissions() {
        val perms = if (Build.VERSION.SDK_INT >= 31) {
            arrayOf(
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_ADVERTISE
            )
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        requestPermissions(perms, 2001)
    }
}
