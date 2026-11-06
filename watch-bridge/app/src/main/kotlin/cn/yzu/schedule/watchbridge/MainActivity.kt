package cn.yzu.schedule.watchbridge

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast

/**
 * 邗上课表 · 手表助手
 * 单 Activity 双面板：登录 → 发送。
 * 发送流程：取权威快照（share/create + preview）→ BLE GATT 广播 → 手表「蓝牙导入」接收。
 * 蓝牙蓝图见 docs/手表助手-蓝图.md。
 */
class MainActivity : Activity() {

    private lateinit var api: ApiClient
    private val ui = Handler(Looper.getMainLooper())
    private var ble: WatchBleTransfer? = null

    private lateinit var panelLogin: LinearLayout
    private lateinit var panelMain: LinearLayout
    private lateinit var editAccount: EditText
    private lateinit var editPassword: EditText
    private lateinit var loginStatus: TextView
    private lateinit var textSemester: TextView
    private lateinit var textMeta: TextView
    private lateinit var textLog: TextView
    private lateinit var logScroll: ScrollView
    private lateinit var btnSend: Button

    private var sending = false
    private var pendingSend = false
    private var timeoutRunnable: Runnable? = null
    private var stopRunnable: Runnable? = null

    /** 运行中的发送是否已进入 BLE 阶段（超时保护用） */
    private var bleStarted = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        api = ApiClient(this)

        panelLogin = findViewById(R.id.panelLogin)
        panelMain = findViewById(R.id.panelMain)
        editAccount = findViewById(R.id.editAccount)
        editPassword = findViewById(R.id.editPassword)
        loginStatus = findViewById(R.id.loginStatus)
        textSemester = findViewById(R.id.textSemester)
        textMeta = findViewById(R.id.textMeta)
        textLog = findViewById(R.id.textLog)
        logScroll = findViewById(R.id.logScroll)
        btnSend = findViewById(R.id.btnSend)

        findViewById<Button>(R.id.btnLogin).setOnClickListener { doLogin() }
        btnSend.setOnClickListener { onSendTapped() }
        findViewById<TextView>(R.id.btnLogout).setOnClickListener { doLogout() }

        editAccount.setText(api.account)
        // 演示模式（adb shell am start -e demo 1）：仅供截图/录屏看布局，不联网不取数
        if (intent.getBooleanExtra("demo", false)) {
            showDemo()
        } else if (api.isLoggedIn) {
            showMain()
        } else {
            showLogin()
        }
    }

    private fun showDemo() {
        panelLogin.visibility = View.GONE
        panelMain.visibility = View.VISIBLE
        textSemester.text = "2026-2027 秋季学期"
        textMeta.text = "共 12 门课 · 演示模式"
        textLog.text = "快照就绪（12 门课），开始蓝牙广播…\n蓝牙广播中…请在手表点「开始接收」，保持 10 米内\n手表已连接，开始传输…\n发送中… 10/24 帧"
    }

    // ---------- 面板 ----------

    private fun showLogin() {
        panelMain.visibility = View.GONE
        panelLogin.visibility = View.VISIBLE
    }

    private fun showMain() {
        panelLogin.visibility = View.GONE
        panelMain.visibility = View.VISIBLE
        textSemester.text = "正在读取课表…"
        textMeta.text = ""
        Thread {
            try {
                val (name, count) = api.semesterBrief()
                ui.post {
                    textSemester.text = name
                    textMeta.text = "共 " + count + " 门课 · 已登录：" + api.account
                }
            } catch (e: Exception) {
                ui.post {
                    textSemester.text = "课表读取失败"
                    textMeta.text = e.message ?: "网络错误"
                }
            }
        }.start()
    }

    private fun log(line: String) {
        ui.post {
            textLog.text = line
            logScroll.post { logScroll.fullScroll(View.FOCUS_DOWN) }
        }
    }

    // ---------- 登录 ----------

    private fun doLogin() {
        val account = editAccount.text.toString().trim()
        val password = editPassword.text.toString()
        if (account.isEmpty() || password.isEmpty()) {
            loginStatus.text = "请输入账号和密码"
            return
        }
        loginStatus.text = "正在登录…"
        Thread {
            try {
                api.login(account, password)
                ui.post {
                    loginStatus.text = "与「邗上课表」App 同一账号"
                    showMain()
                }
            } catch (e: Exception) {
                ui.post { loginStatus.text = e.message ?: "登录失败，请稍后重试" }
            }
        }.start()
    }

    private fun doLogout() {
        stopSend("已停止")
        api.clearSession()
        editPassword.setText("")
        loginStatus.text = "已退出登录"
        showLogin()
    }

    // ---------- 发送 ----------

    private fun onSendTapped() {
        if (sending) return
        if (!hasBlePermissions()) {
            pendingSend = true
            requestBlePermissions()
            return
        }
        startSend()
    }

    private fun hasBlePermissions(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED &&
                checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED &&
                checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED
        } else {
            checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requestBlePermissions() {
        val perms = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_ADVERTISE,
            )
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        requestPermissions(perms, 2001)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (requestCode == 2001 && pendingSend) {
            pendingSend = false
            if (grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }) {
                startSend()
            } else {
                log("需要蓝牙权限才能发送到手表")
            }
        }
    }

    private fun startSend() {
        val adapter = getSystemService(BluetoothManager::class.java)?.adapter
        if (adapter == null) {
            log("此设备没有蓝牙，无法发送")
            return
        }
        if (!adapter.isEnabled) {
            pendingSend = true
            startActivityForResult(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE), 2002)
            return
        }
        doSend()
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == 2002 && pendingSend) {
            pendingSend = false
            if (resultCode == RESULT_OK) doSend() else log("蓝牙未开启，无法发送")
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun doSend() {
        sending = true
        bleStarted = false
        btnSend.isEnabled = false
        btnSend.text = "发送中…"
        log("正在从服务器取课表快照…")
        Thread {
            try {
                val snap = api.fetchSnapshot()
                ui.post {
                    textSemester.text = snap.semesterName
                    textMeta.text = "共 " + snap.courseCount + " 门课 · 快照已就绪"
                    log("快照就绪（" + snap.courseCount + " 门课），开始蓝牙广播…")
                    startBle(snap.json)
                }
            } catch (e: Exception) {
                ui.post {
                    finishSend()
                    log("取快照失败：" + (e.message ?: "网络错误"))
                }
            }
        }.start()
    }

    private fun startBle(json: String) {
        val transfer = WatchBleTransfer(this) { state, extra ->
            ui.post { onBleEvent(state, extra) }
        }
        ble = transfer
        val ok = transfer.start(json)
        if (!ok) {
            finishSend()
            log("蓝牙不可用，请检查蓝牙状态")
            return
        }
        bleStarted = true
        // 120 秒无人连接/未完成则自动收摊
        val t = Runnable {
            stopSend("等待手表超时（120 秒），已停止广播")
        }
        timeoutRunnable = t
        ui.postDelayed(t, 120_000)
    }

    private fun onBleEvent(state: String, extra: Map<String, Any?>) {
        when (state) {
            "advertising" -> log("蓝牙广播中…请在手表点「开始接收」，保持 10 米内")
            "connected" -> log("手表已连接，开始传输…")
            "disconnected" -> if (sending && bleStarted) log("手表已断开")
            "frame" -> {
                val idx = (extra["index"] as? Int) ?: 0
                val total = (extra["total"] as? Int) ?: 0
                if (total > 0 && (idx == 1 || idx == total || idx % 10 == 0)) {
                    log("发送中… " + idx + "/" + total + " 帧")
                }
            }
            "done" -> {
                log("✅ 发送完成！手表端会保存并显示课表")
                Toast.makeText(this, "课表已发送", Toast.LENGTH_SHORT).show()
                timeoutRunnable?.let { ui.removeCallbacks(it) }
                // 留 1.5 秒给手表读完最后一帧，再收广播
                val t = Runnable { finishSend() }
                stopRunnable = t
                ui.postDelayed(t, 1500)
            }
            "advertise_failed" -> {
                finishSend()
                log("广播启动失败（code=" + (extra["code"] ?: "?") + "），请关闭其他占用蓝牙的应用后重试")
            }
            "failed" -> {
                finishSend()
                log(extra["message"] as? String ?: "蓝牙不可用")
            }
        }
    }

    /** 超时/取消：停 BLE 并复位按钮 */
    private fun stopSend(message: String) {
        timeoutRunnable?.let { ui.removeCallbacks(it) }
        stopRunnable?.let { ui.removeCallbacks(it) }
        timeoutRunnable = null
        stopRunnable = null
        ble?.stop()
        ble = null
        bleStarted = false
        finishSend()
        log(message)
    }

    private fun finishSend() {
        sending = false
        bleStarted = false
        btnSend.isEnabled = true
        btnSend.text = "发送到手表"
    }

    override fun onDestroy() {
        super.onDestroy()
        timeoutRunnable?.let { ui.removeCallbacks(it) }
        stopRunnable?.let { ui.removeCallbacks(it) }
        ble?.stop()
        ble = null
    }
}
