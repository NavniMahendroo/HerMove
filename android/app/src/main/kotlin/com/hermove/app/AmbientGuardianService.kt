package com.hermove.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class AmbientGuardianService : Service() {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val eventLock = Any()
    private lateinit var vibrator: Vibrator
    private var receiverRegistered = false

    private val aclDisconnectReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != BluetoothDevice.ACTION_ACL_DISCONNECTED) return
            val device = readDisconnectedDevice(intent)
            handleBluetoothDisconnect(device)
        }
    }

    override fun onCreate() {
        super.onCreate()
        vibrator = obtainVibrator()
        startInForeground()
        registerAclDisconnectReceiver()
        isRunning = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startInForeground()
        return START_STICKY
    }

    override fun onDestroy() {
        unregisterAclDisconnectReceiver()
        isRunning = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startInForeground() {
        createNotificationChannel()
        val notification = buildNotification()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val contentIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                pendingIntentFlags()
            )
        }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("HERMOVE is active")
            .setContentText("Ambient Guardian is monitoring your Bluetooth trigger.")
            .setStyle(
                NotificationCompat.BigTextStyle().bigText(
                    "Ambient Guardian is running in the background and watching for earbud disconnect events."
                )
            )
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(contentIntent)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Ambient Guardian",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Keeps HERMOVE alive for Bluetooth safety monitoring."
            setSound(null, null)
            enableVibration(false)
            enableLights(false)
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
        }

        manager.createNotificationChannel(channel)
    }

    private fun registerAclDisconnectReceiver() {
        if (receiverRegistered) return

        val filter = IntentFilter(BluetoothDevice.ACTION_ACL_DISCONNECTED)
        ContextCompat.registerReceiver(
            this,
            aclDisconnectReceiver,
            filter,
            ContextCompat.RECEIVER_EXPORTED
        )
        receiverRegistered = true
    }

    private fun unregisterAclDisconnectReceiver() {
        if (!receiverRegistered) return
        runCatching { unregisterReceiver(aclDisconnectReceiver) }
        receiverRegistered = false
    }

    private fun handleBluetoothDisconnect(device: BluetoothDevice?) {
        val payload = mapOf(
            "event" to "bluetooth_acl_disconnected",
            "timestamp" to System.currentTimeMillis(),
            "deviceName" to safeDeviceName(device),
            "deviceAddress" to safeDeviceAddress(device)
        )

        emitToFlutter(payload)
        pulseTwice()
    }

    private fun pulseTwice() {
        if (!hasVibrator()) return

        mainHandler.post {
            vibrateBriefly()
            mainHandler.postDelayed({
                vibrateBriefly()
            }, SECOND_PULSE_DELAY_MS)
        }
    }

    private fun vibrateBriefly() {
        if (!hasVibrator()) return

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator.vibrate(
                VibrationEffect.createOneShot(
                    VIBRATION_DURATION_MS,
                    VibrationEffect.DEFAULT_AMPLITUDE
                )
            )
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(VIBRATION_DURATION_MS)
        }
    }

    private fun emitToFlutter(payload: Map<String, Any?>) {
        synchronized(eventLock) {
            val sink = eventSink
            if (sink != null) {
                sink.success(payload)
            } else {
                if (pendingEvents.size == MAX_PENDING_EVENTS) {
                    pendingEvents.removeAt(0)
                }
                pendingEvents.add(payload)
            }
        }

        mainHandler.post {
            methodChannel?.invokeMethod("onHardwareTrigger", payload)
        }
    }

    private fun flushPendingEvents() {
        val sink = eventSink ?: return
        synchronized(eventLock) {
            pendingEvents.forEach { sink.success(it) }
            pendingEvents.clear()
        }
    }

    private fun obtainVibrator(): Vibrator {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val manager = getSystemService(VibratorManager::class.java)
            manager.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(VIBRATOR_SERVICE) as Vibrator
        }
    }

    private fun hasVibrator(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            getSystemService(VibratorManager::class.java).defaultVibrator.hasVibrator()
        } else {
            vibrator.hasVibrator()
        }
    }

    private fun readDisconnectedDevice(intent: Intent): BluetoothDevice? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
        }
    }

    private fun safeDeviceName(device: BluetoothDevice?): String? {
        return try {
            device?.name
        } catch (_: SecurityException) {
            null
        }
    }

    private fun safeDeviceAddress(device: BluetoothDevice?): String? {
        return try {
            device?.address
        } catch (_: SecurityException) {
            null
        }
    }

    private fun pendingIntentFlags(): Int {
        return PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    }

    companion object {
        private const val CHANNEL_ID = "ambient_guardian_foreground"
        private const val NOTIFICATION_ID = 4287
        private const val MAX_PENDING_EVENTS = 8
        private const val SECOND_PULSE_DELAY_MS = 180L
        private const val VIBRATION_DURATION_MS = 110L

        const val METHOD_CHANNEL_NAME = "hermove/ambient_guardian/methods"
        const val EVENT_CHANNEL_NAME = "hermove/ambient_guardian/events"

        @Volatile
        private var isRunning = false

        @Volatile
        private var methodChannel: MethodChannel? = null

        @Volatile
        private var eventSink: EventChannel.EventSink? = null

        private val pendingEvents = mutableListOf<Map<String, Any?>>()

        @JvmStatic
        fun start(context: Context) {
            ContextCompat.startForegroundService(
                context.applicationContext,
                Intent(context.applicationContext, AmbientGuardianService::class.java)
            )
        }

        @JvmStatic
        fun stop(context: Context) {
            context.applicationContext.stopService(
                Intent(context.applicationContext, AmbientGuardianService::class.java)
            )
        }

        @JvmStatic
        fun bindToFlutterEngine(context: Context, messenger: BinaryMessenger) {
            methodChannel = MethodChannel(messenger, METHOD_CHANNEL_NAME).apply {
                setMethodCallHandler { call, result ->
                    when (call.method) {
                        "startMonitoring" -> {
                            start(context)
                            result.success(true)
                        }

                        "stopMonitoring" -> {
                            stop(context)
                            result.success(true)
                        }

                        "isMonitoring" -> {
                            result.success(isRunning)
                        }

                        else -> result.notImplemented()
                    }
                }
            }

            EventChannel(messenger, EVENT_CHANNEL_NAME).setStreamHandler(
                object : EventChannel.StreamHandler {
                    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                        eventSink = events
                        if (events != null) {
                            flushPendingEvents()
                        }
                    }

                    override fun onCancel(arguments: Any?) {
                        eventSink = null
                    }
                }
            )
        }
    }
}
