package cn.yzu.schedule.yzu_schedule

import android.Manifest
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import androidx.core.app.ActivityCompat
import io.flutter.plugin.common.EventChannel
import java.util.UUID

/**
 * 手表 BLE 课表传输（GATT Server + 广播）。
 *
 * 分片协议（与手表端 ble.js 约定）：
 *   每帧: [seq:1B][len:1B][data...]   （seq 从 0 递增，len ≤ 180）
 *   结束帧: seq=0xFF（len=0）
 * 手表 GATT Client 每 read 一次，本端 onCharacteristicReadRequest 返回下一片。
 */
class WatchBleTransfer(
    private val activity: MainActivity,
    private val eventSink: () -> EventChannel.EventSink?
) {
    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("8f2a0001-0000-1000-8000-00805f9b34fb")
        val CHAR_UUID: UUID = UUID.fromString("8f2a0002-0000-1000-8000-00805f9b34fb")
        const val FRAME_SIZE = 180
    }

    private var gattServer: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var advertisementCallback: AdvertiseCallback? = null
    private var gattCallback: BluetoothGattServerCallback? = null
    private var frames: MutableList<ByteArray> = mutableListOf()
    private var readIndex = 0

    private fun emit(state: String, extra: Map<String, Any?> = emptyMap()) {
        activity.runOnUiThread {
            val sink = eventSink()
            if (sink != null) {
                sink.success(mapOf("state" to state) + extra)
            }
        }
    }

    /** 返回 true 表示已开始（或已请求权限），false 表示蓝牙不可用 */
    fun start(json: String): Boolean {
        val bluetoothManager = activity.getSystemService(BluetoothManager::class.java)
        val adapter = bluetoothManager.adapter ?: return false

        // 分片
        frames.clear()
        val bytes = json.toByteArray(Charsets.UTF_8)
        var offset = 0
        var seq = 0
        while (offset < bytes.size) {
            val len = minOf(FRAME_SIZE, bytes.size - offset)
            val frame = ByteArray(2 + len)
            frame[0] = seq.toByte()
            frame[1] = len.toByte()
            System.arraycopy(bytes, offset, frame, 2, len)
            frames.add(frame)
            offset += len
            seq++
        }
        frames.add(byteArrayOf(0xFF.toByte(), 0)) // 结束帧
        readIndex = 0

        // GATT Server：可读 characteristic，读一次返回一片
        gattCallback = object : BluetoothGattServerCallback() {
            override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
                when (newState) {
                    BluetoothProfile.STATE_CONNECTED -> emit("connected")
                    BluetoothProfile.STATE_DISCONNECTED -> emit("disconnected")
                }
            }

            override fun onCharacteristicReadRequest(
                device: BluetoothDevice?,
                requestId: Int,
                offset: Int,
                characteristic: BluetoothGattCharacteristic?
            ) {
                if (characteristic?.uuid == CHAR_UUID && offset == 0 && readIndex < frames.size) {
                    val frame = frames[readIndex]
                    readIndex++
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, frame)
                    if (readIndex >= frames.size) {
                        emit("done")
                    }
                } else {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                }
            }
        }
        gattServer = bluetoothManager.openGattServer(activity, gattCallback)
        val characteristic = BluetoothGattCharacteristic(
            CHAR_UUID,
            BluetoothGattCharacteristic.PROPERTY_READ,
            BluetoothGattCharacteristic.PERMISSION_READ
        )
        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(characteristic)
        gattServer?.addService(service)

        // 广播服务 UUID（手表按此过滤扫描）
        advertiser = adapter.bluetoothLeAdvertiser
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .build()
        val data = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()
        advertisementCallback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                emit("advertising")
            }

            override fun onStartFailure(errorCode: Int) {
                emit("advertise_failed", mapOf("code" to errorCode))
            }
        }
        advertiser?.startAdvertising(settings, data, advertisementCallback)
        return true
    }

    fun stop() {
        try { advertiser?.stopAdvertising(advertisementCallback) } catch (_: Exception) {}
        try { gattServer?.close() } catch (_: Exception) {}
        advertiser = null
        gattServer = null
    }
}
