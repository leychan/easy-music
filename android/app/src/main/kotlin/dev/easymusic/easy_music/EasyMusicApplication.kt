package dev.easymusic.easy_music

import android.app.Application
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.support.v4.media.session.MediaControllerCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat
import com.ryanheise.audioservice.AudioService

class EasyMusicApplication : Application(), AudioService.PlaybackNotificationFactory {
    private val playbackNotification by lazy { PlaybackNotification(this) }

    override fun onCreate() {
        super.onCreate()
        // 升级后清理旧版单独发布的卡片，当前版本由播放服务管理唯一的通知。
        getSystemService(NotificationManager::class.java).cancel(1125)
    }

    override fun buildPlaybackNotification(
        builder: NotificationCompat.Builder,
        controller: MediaControllerCompat,
        openIntent: PendingIntent?,
        playing: Boolean,
    ): Notification = playbackNotification.build(builder, controller, openIntent, playing)

    override fun configurePlaybackStateActions(
        builder: PlaybackStateCompat.Builder,
        actions: Long,
        customActions: List<PlaybackStateCompat.CustomAction>,
    ) = playbackNotification.configurePlaybackStateActions(builder, actions, customActions)
}
