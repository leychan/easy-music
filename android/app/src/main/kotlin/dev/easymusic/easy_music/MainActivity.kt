package dev.easymusic.easy_music

import android.Manifest
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.widget.Toast
import com.ryanheise.audioservice.AudioService
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private var notificationPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dev.easymusic.easy_music/external"
        ).setMethodCallHandler { call, result ->
            val value = call.arguments as? String
            try {
                when (call.method) {
                    "open" -> {
                        val uri = value?.let(Uri::parse)
                        if (uri == null || uri.scheme !in listOf("https", "http") || uri.host.isNullOrEmpty()) {
                            result.error("INVALID_URL", "Invalid web address", null)
                            return@setMethodCallHandler
                        }
                        startActivity(Intent(Intent.ACTION_VIEW, uri))
                    }
                    "share" -> {
                        val intent = Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_TEXT, value)
                        }
                        startActivity(Intent.createChooser(intent, null))
                    }
                    "playbackNotifications" -> {
                        AudioService.showPlaybackNotification()
                        managePlaybackNotifications(call.arguments == true, result)
                        return@setMethodCallHandler
                    }
                    "playbackNotificationNotice" -> {
                        if (value != null) Toast.makeText(applicationContext, value, Toast.LENGTH_SHORT).show()
                    }
                    else -> {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }
                }
                result.success(null)
            } catch (error: ActivityNotFoundException) {
                result.error("NO_HANDLER", "No app can handle the request", null)
            }
        }
    }

    override fun onPostResume() {
        super.onPostResume()
        AudioService.showPlaybackNotification()
    }

    private fun managePlaybackNotifications(automatic: Boolean, result: MethodChannel.Result) {
        if (notificationPermissionResult != null) {
            result.success(false)
            return
        }
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            !manager.areNotificationsEnabled() &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            val preferences = getPreferences(MODE_PRIVATE)
            val asked = preferences.getBoolean("playback_notification_permission_requested", false)
            val retry = !automatic && shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)
            if (!asked || retry) {
                // 拒绝后不在每次启动播放时重复打扰，用户仍可从设置手动开启。
                preferences.edit().putBoolean("playback_notification_permission_requested", true).apply()
                notificationPermissionResult = result
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PLAYBACK_NOTIFICATION_REQUEST)
                return
            }
        }
        if (!automatic) {
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            } else {
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null))
            }
            startActivity(intent)
        }
        result.success(false)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PLAYBACK_NOTIFICATION_REQUEST) {
            val result = notificationPermissionResult
            notificationPermissionResult = null
            AudioService.showPlaybackNotification()
            result?.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
        }
    }

    override fun onDestroy() {
        notificationPermissionResult?.success(false)
        notificationPermissionResult = null
        super.onDestroy()
    }

    private companion object {
        const val PLAYBACK_NOTIFICATION_REQUEST = 137
    }
}
