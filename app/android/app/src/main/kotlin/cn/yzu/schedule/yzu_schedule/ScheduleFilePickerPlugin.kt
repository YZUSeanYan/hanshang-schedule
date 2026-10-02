package cn.yzu.schedule.yzu_schedule

import android.app.Activity
import android.content.Intent
import android.provider.MediaStore
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 截图/Excel 课表导入的文件选择器 + AI 日程拍照识别。
 * Dart 侧契约（schedule_file_picker.dart）：
 *   方法 pick，参数 kind = "image" | "table" | "capture"；
 *   返回 { name, bytes, mimeType }，用户取消返回 null。
 * image/table 使用 ACTION_OPEN_DOCUMENT 一次性 URI 授权，不需要存储权限；
 * capture 用相机 Intent + FileProvider 取全尺寸照片，不声明相机权限，
 * 与隐私政策「不索取相机权限」一致；无相机应用时自动回退到图片选择器。
 */
class ScheduleFilePickerPlugin(private val activity: FlutterActivity) {

    companion object {
        const val REQUEST_PICK = 2002
        const val REQUEST_CAPTURE = 2003

        /// 单文件读取上限（review R16）：超限早拒绝，未知大小按实际字节
        /// 截断判定；避免把超大文件整读进内存造成卡顿/OOM。
        const val MAX_READ_BYTES = 20L * 1024 * 1024
    }

    private var pendingResult: MethodChannel.Result? = null
    private var captureUri: android.net.Uri? = null

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "pick") {
            result.notImplemented()
            return
        }
        if (pendingResult != null) {
            result.error("busy", "已有进行中的文件选择", null)
            return
        }
        when (call.argument<String>("kind") ?: "table") {
            "capture" -> launchCapture(result)
            "image" -> launchSaf(result, image = true)
            else -> launchSaf(result, image = false)
        }
    }

    private fun launchSaf(result: MethodChannel.Result, image: Boolean) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            if (image) {
                type = "image/*"
            } else {
                type = "*/*"
                putExtra(
                    Intent.EXTRA_MIME_TYPES,
                    arrayOf(
                        // xlsx / xls / csv
                        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                        "application/vnd.ms-excel",
                        "text/csv",
                        "text/comma-separated-values",
                        "application/csv",
                    )
                )
            }
        }
        pendingResult = result
        try {
            activity.startActivityForResult(intent, REQUEST_PICK)
        } catch (e: Exception) {
            pendingResult = null
            result.error("picker_error", e.message ?: "无法打开文件选择器", null)
        }
    }

    private fun launchCapture(result: MethodChannel.Result) {
        val photoFile =
            File(activity.cacheDir, "capture_${System.currentTimeMillis()}.jpg")
        val uri = FileProvider.getUriForFile(
            activity,
            "${activity.packageName}.fileprovider",
            photoFile,
        )
        val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
            putExtra(MediaStore.EXTRA_OUTPUT, uri)
            addFlags(
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_READ_URI_PERMISSION
            )
        }
        if (intent.resolveActivity(activity.packageManager) == null) {
            // 无相机应用（部分平板/模拟器）：回退到系统图片选择器
            launchSaf(result, image = true)
            return
        }
        pendingResult = result
        captureUri = uri
        try {
            activity.startActivityForResult(intent, REQUEST_CAPTURE)
        } catch (e: Exception) {
            pendingResult = null
            captureUri = null
            result.error("capture_error", e.message ?: "无法打开相机", null)
        }
    }

    /** @return true 表示该结果已被本插件消费 */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK && requestCode != REQUEST_CAPTURE) return false
        val result = pendingResult
        pendingResult = null
        if (result == null) return true
        val uri = if (requestCode == REQUEST_CAPTURE) captureUri else data?.data
        if (requestCode == REQUEST_CAPTURE) captureUri = null
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }
        try {
            // 有界读取放到后台线程（review R16）：原实现是主线程无上限
            // readBytes()，大文件/慢流会阻塞 UI 甚至 ANR；MethodChannel
            // Result 必须回主线程，所以读完后 Handler.post 回来。
            val appContext = activity.applicationContext
            val isCapture = requestCode == REQUEST_CAPTURE
            Thread {
                try {
                    val resolver = appContext.contentResolver
                    val declaredSize = querySize(uri)
                    if (declaredSize != null && declaredSize > MAX_READ_BYTES) {
                        mainResult(result) {
                            result.error("file_too_large", "文件超过 20MB 上限", null)
                        }
                        return@Thread
                    }
                    val bytes = resolver.openInputStream(uri)?.use { input ->
                        readBounded(input, MAX_READ_BYTES)
                    }
                    if (bytes == null) {
                        mainResult(result) {
                            result.error("file_too_large", "文件超过 20MB 上限", null)
                        }
                        return@Thread
                    }
                    if (bytes.isEmpty()) {
                        mainResult(result) {
                            result.error("read_error", "无法读取所选文件", null)
                        }
                        return@Thread
                    }
                    val name = queryDisplayName(uri)
                        ?: if (isCapture) "拍照.jpg" else "课表文件"
                    val mime = resolver.getType(uri) ?: "application/octet-stream"
                    mainResult(result) {
                        result.success(
                            mapOf(
                                "name" to name,
                                "bytes" to bytes,
                                "mimeType" to mime,
                            )
                        )
                    }
                } catch (e: Exception) {
                    mainResult(result) {
                        result.error("read_error", e.message ?: "读取失败", null)
                    }
                } finally {
                    // 拍照缓存文件即用即删
                    if (isCapture) {
                        try {
                            appContext.contentResolver.delete(uri, null, null)
                        } catch (_: Exception) {
                        }
                    }
                }
            }.start()
        } catch (e: Exception) {
            result.error("read_error", e.message ?: "读取失败", null)
        }
        return true
    }

    /** 把 MethodChannel 回调封回主线程 */
    private fun mainResult(result: MethodChannel.Result, block: () -> Unit) {
        android.os.Handler(android.os.Looper.getMainLooper()).post(block)
    }

    /** 有界读取：超过 max 返回 null；流比 max 长时不会读入超过 max 的内存 */
    private fun readBounded(input: java.io.InputStream, max: Long): ByteArray? {
        val buffer = java.io.ByteArrayOutputStream()
        val chunk = ByteArray(64 * 1024)
        var total = 0L
        while (true) {
            val n = input.read(chunk)
            if (n < 0) break
            total += n
            if (total > max) return null
            buffer.write(chunk, 0, n)
        }
        return buffer.toByteArray()
    }

    private fun querySize(uri: android.net.Uri): Long? {
        return try {
            activity.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val index = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (index >= 0 && cursor.moveToFirst() && !cursor.isNull(index)) {
                    cursor.getLong(index)
                } else null
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun queryDisplayName(uri: android.net.Uri): String? {
        return try {
            activity.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0 && cursor.moveToFirst()) cursor.getString(index) else null
            }
        } catch (_: Exception) {
            null
        }
    }
}
