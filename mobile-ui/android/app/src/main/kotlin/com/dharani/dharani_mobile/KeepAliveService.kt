package com.dharani.dharani_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps the phone reachable while a driver is online or a ride/call is active, with the screen off and
 * on battery: foreground service (so the process is not frozen), a partial CPU wake lock (Dart timers and
 * the socket keep running) and a Wi-Fi lock (radio stays out of power-save so offers arrive instantly).
 */
class KeepAliveService : Service() {
    private var wake: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Dharani online", NotificationManager.IMPORTANCE_LOW))
        val n = Notification.Builder(this, CHANNEL)
            .setContentTitle("Dharani is online")
            .setContentText(intent?.getStringExtra("text") ?: "Ready for requests")
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(ID, n)
        }
        if (wake == null) {
            val pm = getSystemService(PowerManager::class.java)
            wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "dharani:online").apply { setReferenceCounted(false); acquire() }
        }
        if (wifi == null) {
            val wm = applicationContext.getSystemService(WifiManager::class.java)
            val mode = if (Build.VERSION.SDK_INT >= 29) WifiManager.WIFI_MODE_FULL_LOW_LATENCY else WifiManager.WIFI_MODE_FULL_HIGH_PERF
            wifi = wm.createWifiLock(mode, "dharani:online").apply { setReferenceCounted(false); acquire() }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        try { wake?.release() } catch (_: Throwable) {}
        try { wifi?.release() } catch (_: Throwable) {}
        wake = null
        wifi = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "dharani_online"
        private const val ID = 4712
    }
}
