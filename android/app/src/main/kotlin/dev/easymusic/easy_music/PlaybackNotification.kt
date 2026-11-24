package dev.easymusic.easy_music

import android.app.Notification
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.os.Bundle
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaControllerCompat
import android.support.v4.media.session.MediaSessionCompat
import android.view.View
import android.widget.RemoteViews
import androidx.core.app.NotificationCompat

private const val EXTRA_MEDIA_SESSION = "dev.easymusic.easy_music.MEDIA_SESSION"
private const val FAVORITE_ACTION = "dev.easymusic.easy_music.TOGGLE_FAVORITE"
private const val TRACK_ID = "trackId"

/** 由播放服务发布，首次播放、暂停和切歌都使用同一张通知。 */
internal class PlaybackNotification(private val context: Context) {
    private data class Content(
        val title: String?,
        val artist: String?,
        val cover: Bitmap?,
        val playing: Boolean,
        val favoriteTrackId: String?,
        val liked: Boolean,
    )

    fun build(
        builder: NotificationCompat.Builder,
        controller: MediaControllerCompat,
        openIntent: PendingIntent?,
        playing: Boolean,
    ): Notification {
        val token = controller.sessionToken
        val state = controller.playbackState
        val item = controller.metadata.takeIf { (state?.activeQueueItemId ?: -1) >= 0 }
        val favorite = state?.customActions?.firstOrNull {
            it.action == FAVORITE_ACTION && it.extras?.getString(TRACK_ID) == item?.description?.mediaId
        }
        val content = Content(
            title = item?.getString(MediaMetadataCompat.METADATA_KEY_TITLE),
            artist = item?.getString(MediaMetadataCompat.METADATA_KEY_ARTIST),
            cover = item?.getBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART),
            playing = playing,
            favoriteTrackId = favorite?.extras?.getString(TRACK_ID),
            liked = favorite?.icon == R.drawable.ic_notification_liked,
        )
        builder.setContentTitle(content.title ?: context.getString(R.string.playback_notification_empty))
            .setContentText(content.artist)
            .setContentIntent(openIntent)
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
        if (content.title != null) {
            val cover = content.cover?.let { bitmap ->
                // 封面会装进折叠和展开两份视图，限制尺寸以免通知超过 Binder 上限。
                val edge = maxOf(bitmap.width, bitmap.height)
                if (edge <= 256) bitmap else Bitmap.createScaledBitmap(
                    bitmap, (bitmap.width * 256 / edge).coerceAtLeast(1),
                    (bitmap.height * 256 / edge).coerceAtLeast(1), true,
                )
            }
            val viewContent = content.copy(cover = cover)
            // 自定义卡片只提交内容，通知头由系统按版本添加。
            builder.setCustomContentView(buildView(R.layout.playback_notification, viewContent, token))
                .setCustomBigContentView(buildView(R.layout.playback_notification_expanded, viewContent, token))
        }
        return builder.build()
    }

    private fun buildView(layout: Int, content: Content, token: MediaSessionCompat.Token): RemoteViews =
        RemoteViews(context.packageName, layout).apply {
            setTextViewText(R.id.playback_title, content.title)
            setTextViewText(R.id.playback_artist, content.artist)
            setViewVisibility(R.id.playback_artist, if (content.artist.isNullOrBlank()) View.GONE else View.VISIBLE)
            setViewVisibility(R.id.playback_cover, if (content.cover == null) View.GONE else View.VISIBLE)
            content.cover?.let { setImageViewBitmap(R.id.playback_cover, it) }
            setImageViewResource(R.id.playback_toggle,
                if (content.playing) R.drawable.ic_notification_pause else R.drawable.ic_notification_play)
            setContentDescription(R.id.playback_toggle, context.getString(
                if (content.playing) R.string.playback_notification_pause else R.string.playback_notification_play,
            ))
            setOnClickPendingIntent(R.id.playback_previous, action(token, "previous"))
            setOnClickPendingIntent(R.id.playback_toggle, action(token, if (content.playing) "pause" else "play"))
            setOnClickPendingIntent(R.id.playback_next, action(token, "next"))

            val trackId = content.favoriteTrackId
            setViewVisibility(R.id.playback_favorite, if (trackId == null) View.GONE else View.VISIBLE)
            if (trackId != null) {
                setImageViewResource(R.id.playback_favorite, if (content.liked) R.drawable.ic_notification_liked else R.drawable.ic_notification_like)
                setContentDescription(R.id.playback_favorite, context.getString(
                    if (content.liked) R.string.playback_notification_unlike else R.string.playback_notification_like,
                ))
                setOnClickPendingIntent(R.id.playback_favorite, action(token, FAVORITE_ACTION, trackId))
            }
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
            FAVORITE_ACTION -> {
                val trackId = intent.data?.schemeSpecificPart ?: return
                controls.sendCustomAction(FAVORITE_ACTION, Bundle().apply { putString(TRACK_ID, trackId) })
            }
        }
    }
}
