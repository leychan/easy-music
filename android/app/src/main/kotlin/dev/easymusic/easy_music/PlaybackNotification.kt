package dev.easymusic.easy_music

import android.app.Notification
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaControllerCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat
import androidx.media.app.NotificationCompat.MediaStyle

private const val EXTRA_MEDIA_SESSION = "dev.easymusic.easy_music.MEDIA_SESSION"
private const val FAVORITE_ACTION = "dev.easymusic.easy_music.TOGGLE_FAVORITE"
private const val PREVIOUS_ACTION = "dev.easymusic.easy_music.PREVIOUS"
private const val EXIT_ACTION = "dev.easymusic.easy_music.EXIT"
private const val TRACK_ID = "trackId"

/** 由播放服务发布，首次播放、暂停和切歌都使用同一张通知。 */
internal class PlaybackNotification(private val context: Context) {
    fun configurePlaybackStateActions(
        builder: PlaybackStateCompat.Builder,
        actions: Long,
        customActions: List<PlaybackStateCompat.CustomAction>,
    ) {
        val favorite = customActions.firstOrNull { it.action == FAVORITE_ACTION }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && favorite != null) {
            // Android 13 起，系统用第一个自定义操作填补空出的「上一首」位置。
            // 有收藏按钮时让它占用这个位置，并把「上一首」保留在展开的卡片里。
            builder.setActions(actions and PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS.inv())
                .addCustomAction(favorite)
            if (actions and PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS != 0L) {
                builder.addCustomAction(
                    PREVIOUS_ACTION,
                    context.getString(R.string.playback_notification_previous),
                    R.drawable.ic_notification_previous,
                )
            }
            customActions.filter { it.action != FAVORITE_ACTION }.forEach { builder.addCustomAction(it) }
        } else {
            customActions.forEach { builder.addCustomAction(it) }
        }
    }

    fun build(
        builder: NotificationCompat.Builder,
        controller: MediaControllerCompat,
        openIntent: PendingIntent?,
        playing: Boolean,
    ): Notification {
        val token = controller.sessionToken
        val state = controller.playbackState
        val item = controller.metadata.takeIf { (state?.activeQueueItemId ?: -1) >= 0 }
        val title = item?.getString(MediaMetadataCompat.METADATA_KEY_TITLE)
        builder.setContentTitle(title ?: context.getString(R.string.playback_notification_empty))
            .setContentText(item?.getString(MediaMetadataCompat.METADATA_KEY_ARTIST))
            .setContentIntent(openIntent)
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
        if (item == null || title == null) return builder.build()

        item.getBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART)?.let { bitmap ->
            // 限制通知封面尺寸，避免大图使系统传输超限。
            val edge = maxOf(bitmap.width, bitmap.height)
            val cover = if (edge <= 256) bitmap else Bitmap.createScaledBitmap(
                bitmap, (bitmap.width * 256 / edge).coerceAtLeast(1),
                (bitmap.height * 256 / edge).coerceAtLeast(1), true,
            )
            builder.setLargeIcon(cover)
        }

        val trackId = item.description.mediaId
        val favorite = state?.customActions?.firstOrNull {
            it.action == FAVORITE_ACTION && it.extras?.getString(TRACK_ID) == trackId
        }
        val hasFavorite = trackId != null && favorite != null
        if (trackId != null && favorite != null) {
            val liked = favorite.icon == R.drawable.ic_notification_liked
            builder.addAction(
                if (liked) R.drawable.ic_notification_liked else R.drawable.ic_notification_like,
                context.getString(if (liked) R.string.playback_notification_unlike else R.string.playback_notification_like),
                action(token, FAVORITE_ACTION, trackId),
            )
        }

        builder.addAction(
            R.drawable.ic_notification_previous,
            context.getString(R.string.playback_notification_previous),
            action(token, "previous"),
        )
            .addAction(
                if (playing) R.drawable.ic_notification_pause else R.drawable.ic_notification_play,
                context.getString(
                    if (playing) R.string.playback_notification_pause else R.string.playback_notification_play,
                ),
                action(token, if (playing) "pause" else "play"),
            )
            .addAction(
                R.drawable.ic_notification_next,
                context.getString(R.string.playback_notification_next),
                action(token, "next"),
            )

        builder.addAction(
            R.drawable.ic_notification_close,
            context.getString(R.string.playback_notification_exit),
            action(token, EXIT_ACTION),
        )

        // 旧版 Android 的折叠卡片只能显示三个按钮，有收藏时保留播放和下一首。
        val style = MediaStyle().setMediaSession(token)
        if (hasFavorite) style.setShowActionsInCompactView(0, 2, 3)
        else style.setShowActionsInCompactView(0, 1, 2)
        return builder.setStyle(style).build()
    }

    private fun action(token: MediaSessionCompat.Token, action: String, trackId: String? = null): PendingIntent {
        val intent = Intent(context, PlaybackNotificationActionReceiver::class.java)
            .setAction(action)
            .putExtra(EXTRA_MEDIA_SESSION, token)
        if (trackId != null) {
            // PendingIntent 用 data 区分歌曲，旧通知的点击不会被更新为下一首。
            intent.setData(Uri.fromParts("easymusic-favorite", trackId, null))
        }
        return PendingIntent.getBroadcast(context, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
}

/** 点击通知时通过媒体会话控制播放，应用无需切到前台。 */
class PlaybackNotificationActionReceiver : BroadcastReceiver() {
    @Suppress("DEPRECATION")
    override fun onReceive(context: Context, intent: Intent) {
        val token = intent.getParcelableExtra<MediaSessionCompat.Token>(EXTRA_MEDIA_SESSION) ?: return
        val controls = MediaControllerCompat(context, token).transportControls
        when (intent.action) {
            "previous" -> controls.skipToPrevious()
            "play" -> controls.play()
            "pause" -> controls.pause()
            "next" -> controls.skipToNext()
            EXIT_ACTION -> controls.sendCustomAction(EXIT_ACTION, null)
            FAVORITE_ACTION -> {
                val trackId = intent.data?.schemeSpecificPart ?: return
                controls.sendCustomAction(FAVORITE_ACTION, Bundle().apply { putString(TRACK_ID, trackId) })
            }
        }
    }
}
