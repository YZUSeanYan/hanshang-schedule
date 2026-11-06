package cn.yzu.schedule.watchbridge

import android.content.Context
import android.net.Uri
import org.json.JSONObject
import java.io.BufferedReader
import java.net.HttpURLConnection
import java.net.URL

/** 业务异常（HTTP 状态码 + 服务端 detail.message） */
class ApiException(val code: Int, message: String) : Exception(message)

/** 快照拉取结果 */
data class SnapshotResult(val json: String, val semesterName: String, val courseCount: Int)

/**
 * 邗上课表后端 API 封装（与主 App 契约一致）：
 *   base = https://api.seanyan.store/yzu/api
 *   POST /auth/login  GET /sync/pull?since=0  POST /share/create  GET /share/{code}
 * 快照直接取服务端 _snapshot_for_semester 产物（share preview 的 payload），
 * 与手表 bleimport/applySnapshot 结构同构。
 */
class ApiClient(ctx: Context) {

    companion object {
        const val BASE = "https://api.seanyan.store/yzu/api"
        private const val PREFS = "watch_bridge"
        private const val K_ACCESS = "access_token"
        private const val K_REFRESH = "refresh_token"
        private const val K_ACCOUNT = "account"

        /**
         * 安全校验（生成期验收条件）：仅允许 http/https 中的 https；
         * 拒绝 localhost、环回、私网与保留地址。
         */
        fun requireSafeUrl(raw: String): URL {
            val uri = Uri.parse(raw)
            val scheme = uri.scheme?.lowercase()
            require(scheme == "https") { "仅允许 https 请求" }
            val host = uri.host?.lowercase() ?: throw IllegalArgumentException("非法 URL")
            if (host == "localhost" || host.endsWith(".local") || host == "0.0.0.0") {
                throw IllegalArgumentException("目标地址不被允许")
            }
            // 字面量 IP：拒绝环回/私网/链路本地/保留段
            val ip = Regex("""^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$""").matchEntire(host)
            if (ip != null) {
                val a = ip.groupValues[1].toInt()
                val b = ip.groupValues[2].toInt()
                val blocked = a == 0 || a == 10 || a == 127 || a == 169 && b == 254 ||
                    a == 172 && b in 16..31 || a == 192 && b == 168 || a >= 224
                if (blocked) throw IllegalArgumentException("目标地址不被允许")
            }
            return URL(raw)
        }
    }

    private val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    var accessToken: String = prefs.getString(K_ACCESS, "") ?: ""
        private set
    var refreshToken: String = prefs.getString(K_REFRESH, "") ?: ""
        private set
    var account: String = prefs.getString(K_ACCOUNT, "") ?: ""
        private set

    val isLoggedIn: Boolean get() = accessToken.isNotEmpty()

    fun clearSession() {
        accessToken = ""
        refreshToken = ""
        account = ""
        prefs.edit().clear().apply()
    }

    /** 登录（用户名或邮箱 + 密码） */
    fun login(account: String, password: String) {
        val body = JSONObject()
            .put("account", account)
            .put("password", password)
        val data = request("/auth/login", "POST", body, auth = false).getJSONObject("data")
        accessToken = data.optString("access_token")
        refreshToken = data.optString("refresh_token")
        this.account = account
        prefs.edit()
            .putString(K_ACCESS, accessToken)
            .putString(K_REFRESH, refreshToken)
            .putString(K_ACCOUNT, account)
            .apply()
    }

    /** 学期概要（名称 + 课程数），面板展示用 */
    fun semesterBrief(): Pair<String, Int> {
        val data = pullData()
        val sem = pickSemester(data)
        val count = countCourses(data, sem.getString("uuid"))
        return Pair(sem.optString("name", "当前学期"), count)
    }

    /** 取权威快照：share/create → share/{code} preview 的 payload */
    fun fetchSnapshot(): SnapshotResult {
        val data = pullData()
        val sem = pickSemester(data)
        val count = countCourses(data, sem.getString("uuid"))
        val code = request(
            "/share/create", "POST",
            JSONObject().put("semester_uuid", sem.getString("uuid"))
        ).getJSONObject("data").getString("code")
        val payload = request("/share/" + code, "GET")
            .getJSONObject("data").getJSONObject("payload")
        return SnapshotResult(
            json = payload.toString(),
            semesterName = sem.optString("name", "当前学期"),
            courseCount = count,
        )
    }

    private fun pullData(): JSONObject {
        return request("/sync/pull?since=0", "GET").getJSONObject("data")
    }

    private fun pickSemester(data: JSONObject): JSONObject {
        val semesters = data.optJSONArray("semesters") ?: throw ApiException(0, "没有课表数据，请先在「邗上课表」App 同步课表")
        var picked: JSONObject? = null
        for (i in 0 until semesters.length()) {
            val s = semesters.optJSONObject(i) ?: continue
            if (s.optBoolean("deleted")) continue
            if (picked == null) picked = s
            if (s.optBoolean("is_current")) {
                picked = s
                break
            }
        }
        return picked ?: throw ApiException(0, "没有可用学期，请先在「邗上课表」App 同步课表")
    }

    private fun countCourses(data: JSONObject, semesterUuid: String): Int {
        val courses = data.optJSONArray("courses") ?: return 0
        var n = 0
        for (i in 0 until courses.length()) {
            val c = courses.optJSONObject(i) ?: continue
            if (!c.optBoolean("deleted") && c.optString("semester_uuid") == semesterUuid) n++
        }
        return n
    }

    /** 带鉴权请求；401 给出明确的重新登录提示 */
    private fun request(path: String, method: String, body: JSONObject? = null, auth: Boolean = true): JSONObject {
        val conn = requireSafeUrl(BASE + path).openConnection() as HttpURLConnection
        try {
            conn.requestMethod = method
            conn.connectTimeout = 15000
            conn.readTimeout = 20000
            conn.setRequestProperty("Content-Type", "application/json")
            if (auth && accessToken.isNotEmpty()) {
                conn.setRequestProperty("Authorization", "Bearer " + accessToken)
            }
            if (body != null) {
                conn.doOutput = true
                conn.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            }
            val code = conn.responseCode
            val text = (if (code in 200..299) conn.inputStream else conn.errorStream)
                ?.bufferedReader()?.use(BufferedReader::readText) ?: ""
            val json = JSONObject(text.ifEmpty { "{}" })
            if (code == 401 && auth) throw ApiException(401, "登录已过期，请重新登录")
            if (code !in 200..299) {
                val msg = json.optJSONObject("detail")?.optString("message")?.takeIf { it.isNotEmpty() }
                    ?: ("请求失败(" + code + ")")
                throw ApiException(code, msg)
            }
            return json
        } finally {
            conn.disconnect()
        }
    }
}
