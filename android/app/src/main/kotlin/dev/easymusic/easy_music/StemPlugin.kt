package dev.easymusic.easy_music

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioTrack
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.audio.AudioProcessor.AudioFormat
import androidx.media3.common.audio.AudioProcessor.UnhandledAudioFormatException
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.AudioOutput
import androidx.media3.exoplayer.audio.AudioOutputProvider
import androidx.media3.exoplayer.audio.AudioTrackAudioOutput
import androidx.media3.exoplayer.audio.AudioTrackAudioOutputProvider
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.audio.DefaultAudioTrackBufferSizeProvider
import androidx.media3.exoplayer.audio.ForwardingAudioOutputProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CancellationException
import java.util.concurrent.Executors
import kotlin.math.roundToInt

@OptIn(UnstableApi::class)
internal class StemPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var context: Context
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private lateinit var separator: StemSeparator
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val microphoneWorker = Executors.newSingleThreadExecutor()
    private var sink: EventChannel.EventSink? = null
    private var attached = false
    private var job: StemJob? = null
    private var clearing = false
    private var prepared: File? = null
    @Volatile private var playingFile: File? = null
    private var player: ExoPlayer? = null
    private var processor: StemMixProcessor? = null
    private var token = 0L
    private var loadResult: MethodChannel.Result? = null
    private var foreground = false
    private var karaoke = false
    @Volatile private var microphone: KaraokeCapture? = null
    @Volatile private var microphoneGain = DEFAULT_MICROPHONE_GAIN
    @Volatile private var microphoneReverb = DEFAULT_MICROPHONE_REVERB

    private val positionTick = object : Runnable {
        override fun run() {
            val current = player ?: return
            if (current.isPlaying) {
                emitPlayback(tick = true)
                main.postDelayed(this, 180)
            }
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        separator = StemSeparator(context)
        methods = MethodChannel(binding.binaryMessenger, "dev.easymusic.easy_music/stems")
        events = EventChannel(binding.binaryMessenger, "dev.easymusic.easy_music/stem_events")
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
        attached = true
        worker.execute {
            runCatching {
                if (separator.removeLegacyCache()) Log.i("EasyMusicStems", "Legacy stem cache cleared")
            }.onFailure {
                Log.w("EasyMusicStems", "Cannot clear legacy stem cache")
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = false
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        job?.cancel()
        worker.shutdown()
        closePlayer()
        microphoneWorker.shutdown()
        sink = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        emitPlayback()
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "hasResources" -> hasResources(call, result)
                "prepare" -> prepare(call, result)
                "cancel" -> {
                    if (job?.id == call.number("id").toLong()) job?.cancel()
                    result.success(null)
                }
                "clear" -> clear(result)
                "load" -> load(call, result)
                "close" -> {
                    val state = snapshot()
                    closePlayer()
                    result.success(state)
                }
                "mix" -> {
                    processor?.gains = MixGains(call.gain("vocals"), call.gain("accompaniment"))
                    microphoneGain = call.gain("microphone")
                    microphoneReverb = call.gain("reverb")
                    result.success(null)
                }
                "karaoke" -> {
                    setKaraoke(call.argument<Boolean>("enabled") == true)
                    result.success(snapshot())
                }
                "volume" -> {
                    player?.volume = call.gain("volume")
                    result.success(null)
                }
                "speed" -> {
                    player?.setPlaybackSpeed(call.number("speed").toFloat().coerceIn(0.5f, 2f))
                    result.success(snapshot())
                }
                "repeatOne" -> {
                    player?.repeatMode = if (call.argument<Boolean>("enabled") == true)
                        Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
                    result.success(null)
                }
                "play" -> {
                    requirePlayer().play()
                    result.success(snapshot())
                }
                "pause" -> {
                    requirePlayer().pause()
                    result.success(snapshot())
                }
                "seek" -> {
                    microphone?.discardBefore(System.nanoTime())
                    requirePlayer().seekTo(call.number("position").toLong().coerceAtLeast(0))
                    result.success(snapshot())
                }
                else -> result.notImplemented()
            }
        } catch (problem: StemFailure) {
            result.error(problem.code, problem.message, null)
        } catch (error: Exception) {
            Log.w("EasyMusicStems", "Stem command failed: " + error.javaClass.simpleName)
            if (call.method == "load") {
                loadResult = null
                closePlayer()
            }
            result.error("playback", "无法播放分轨，请重试。", null)
        }
    }

    fun setForeground(visible: Boolean) {
        foreground = visible
        if (!visible && karaoke) {
            karaoke = false
            updateMicrophone()
            emitPlayback()
        }
    }

    private fun setKaraoke(enabled: Boolean) {
        if (enabled) {
            requirePlayer()
            if (!foreground ||
                context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                throw StemFailure("microphone", "请在播放页授权麦克风后开启 K 歌。")
            }
        }
        karaoke = enabled
        updateMicrophone()
    }

    private fun updateMicrophone() {
        if (!(karaoke && foreground && player?.isPlaying == true)) {
            microphone?.stop()
            microphone = null
        } else if (microphone == null) {
            val capture = KaraokeCapture { failed ->
                main.post {
                    if (microphone === failed) {
                        karaoke = false
                        updateMicrophone()
                        emitPlayback()
                        sink?.success(mapOf("event" to "karaokeError", "id" to token))
                    }
                }
            }
            microphone = capture
            capture.start(microphoneWorker)
        }
    }

    private fun source(call: MethodCall): Uri {
        val uri = Uri.parse(requireNotNull(call.argument<String>("uri")))
        val loopback = uri.scheme == "http" && uri.host == "127.0.0.1" &&
            uri.port in 1..65535 && uri.userInfo == null
        require(uri.scheme == "content" || uri.scheme == "file" || loopback)
        return uri
    }

    private fun hasResources(call: MethodCall, result: MethodChannel.Result) {
        if (job != null || clearing) {
            result.success(false)
            return
        }
        val uri = source(call)
        require(uri.scheme != "http" || uri.getQueryParameter("cachedOnly") == "1")
        val cacheKey = call.argument<String>("cacheKey")
        worker.execute {
            val available = separator.hasResources(uri, cacheKey)
            main.post { if (attached) result.success(available) }
        }
    }

    private fun prepare(call: MethodCall, result: MethodChannel.Result) {
        if (job != null || clearing) throw StemFailure("busy", "正在处理另一个分轨操作。")
        val uri = source(call)
        val cacheKey = call.argument<String>("cacheKey")
        val request = StemJob(call.number("id").toLong())
        job = request
        worker.execute {
            var lastStage: String? = null
            var lastSent = 0L
            try {
                Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
                val file = separator.prepare(uri, cacheKey, request, { playingFile }) { stage, fraction ->
                    val now = SystemClock.elapsedRealtime()
                    if (stage != lastStage || now - lastSent >= 200 || fraction == 1.0) {
                        lastStage = stage
                        lastSent = now
                        main.post {
                            if (job === request) {
                                sink?.success(mapOf(
                                    "event" to "progress", "id" to request.id,
                                    "stage" to stage, "fraction" to fraction
                                ))
                            }
                        }
                    }
                }
                main.post {
                    finishJob(request) {
                        prepared = file
                        result.success(file.path)
                    }
                }
            } catch (_: CancellationException) {
                main.post { finishJob(request) { result.error("cancelled", null, null) } }
            } catch (problem: StemFailure) {
                main.post { finishJob(request) { result.error(problem.code, problem.message, null) } }
            } catch (error: Exception) {
                Log.w("EasyMusicStems", "Separation failed: " + error.javaClass.simpleName)
                main.post { finishJob(request) { result.error("separation", "无法分离这首歌，请重试。", null) } }
            } catch (error: LinkageError) {
                Log.w("EasyMusicStems", "Runtime unavailable: " + error.javaClass.simpleName)
                main.post { finishJob(request) { result.error("runtime", "这台设备无法运行分轨模型。", null) } }
            } catch (_: OutOfMemoryError) {
                main.post { finishJob(request) { result.error("memory", "可用内存不足，无法分轨。", null) } }
            }
        }
    }

    private fun finishJob(request: StemJob, finish: () -> Unit) {
        if (!attached || job !== request) return
        job = null
        finish()
    }

    private fun clear(result: MethodChannel.Result) {
        if (job != null || clearing || player != null) {
            throw StemFailure("busy", "请先结束分轨播放或处理任务。")
        }
        clearing = true
        worker.execute {
            val success = runCatching { separator.clear() }.isSuccess
            main.post {
                clearing = false
                if (attached) {
                    prepared = null
                    if (success) result.success(null)
                    else result.error("storage", "无法清理分轨缓存。", null)
                }
            }
        }
    }

    private fun load(call: MethodCall, result: MethodChannel.Result) {
        val file = prepared?.takeIf { it.path == call.argument<String>("path") && it.isFile }
            ?: throw StemFailure("file", "分轨缓存已失效，请重新启用。")
        closePlayer()
        token = call.number("id").toLong()
        val mixer = StemMixProcessor().apply {
            gains = MixGains(call.gain("vocals"), call.gain("accompaniment"))
        }
        val renderers = object : DefaultRenderersFactory(context) {
            override fun buildAudioSink(
                context: Context,
                enableFloatOutput: Boolean,
                enableAudioOutputPlaybackParameters: Boolean,
            ): AudioSink {
                val output = AudioTrackAudioOutputProvider.Builder(context)
                    .setAudioTrackBufferSizeProvider(DefaultAudioTrackBufferSizeProvider.Builder()
                        .setMinPcmBufferDurationUs(25000)
                        .setMaxPcmBufferDurationUs(75000)
                        .build())
                    .setAudioTrackBuilderModifier { builder, _ ->
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            builder.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
                        }
                    }
                    .build()
                val karaokeOutput = object : ForwardingAudioOutputProvider(output) {
                    override fun getAudioOutput(config: AudioOutputProvider.OutputConfig): AudioOutput {
                        val delegate = super.getAudioOutput(config)
                        // 在最后一次写入前加入麦克风，避免耳返随着伴奏一起提前缓冲。
                        return if (config.encoding == C.ENCODING_PCM_16BIT && config.sampleRate == STEM_SAMPLE_RATE &&
                            Integer.bitCount(config.channelMask) == 2 &&
                            !config.isOffload && !config.isTunneling) {
                            KaraokeAudioOutput(
                                delegate, { microphone }, { microphoneGain }, { microphoneReverb },
                                (delegate as? AudioTrackAudioOutput)?.audioTrack?.let(::KaraokeOutputBuffer),
                            )
                        } else {
                            delegate
                        }
                    }
                }
                return DefaultAudioSink.Builder(context)
                    .setAudioProcessors(arrayOf(mixer))
                    .setAudioOutputProvider(karaokeOutput)
                    .build()
            }
        }
        val current = ExoPlayer.Builder(context, renderers).build()
        processor = mixer
        player = current
        playingFile = file
        loadResult = result
        current.addListener(object : Player.Listener {
            override fun onEvents(player: Player, events: Player.Events) {
                if (current !== this@StemPlugin.player) return
                if (current.playbackState == Player.STATE_ENDED) karaoke = false
                updateMicrophone()
                if (current.playbackState == Player.STATE_READY) {
                    loadResult?.success(snapshot())
                    loadResult = null
                }
                emitPlayback()
                main.removeCallbacks(positionTick)
                if (current.isPlaying) main.postDelayed(positionTick, 180)
            }

            override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                if (current === player && reason == Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY) {
                    karaoke = false
                    updateMicrophone()
                }
            }

            override fun onPositionDiscontinuity(
                oldPosition: Player.PositionInfo,
                newPosition: Player.PositionInfo,
                reason: Int,
            ) {
                if (current === player) microphone?.discardBefore(System.nanoTime())
            }

            override fun onPlayerError(error: PlaybackException) {
                if (current !== this@StemPlugin.player) return
                val loading = loadResult
                loadResult = null
                if (loading != null) {
                    loading.error("playback", "无法读取分轨缓存。", null)
                    closePlayer()
                } else {
                    sink?.success(mapOf("event" to "error", "id" to token))
                }
            }
        })
        current.setAudioAttributes(
            AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(),
            true,
        )
        current.setHandleAudioBecomingNoisy(true)
        current.setWakeMode(C.WAKE_MODE_LOCAL)
        current.volume = call.gain("volume")
        current.setPlaybackSpeed(call.number("speed").toFloat())
        current.repeatMode = if (call.argument<Boolean>("repeatOne") == true)
            Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
        current.setMediaItem(MediaItem.fromUri(Uri.fromFile(file)), call.number("position").toLong())
        current.prepare()
    }

    private fun closePlayer() {
        karaoke = false
        updateMicrophone()
        microphoneGain = DEFAULT_MICROPHONE_GAIN
        microphoneReverb = DEFAULT_MICROPHONE_REVERB
        main.removeCallbacks(positionTick)
        loadResult?.error("cancelled", null, null)
        loadResult = null
        val old = player
        player = null
        old?.release()
        processor = null
        playingFile = null
    }

    private fun snapshot(): Map<String, Any?>? = player?.let {
        mapOf(
            "id" to token,
            "state" to it.playbackState,
            "playing" to (it.playWhenReady && it.playbackSuppressionReason == Player.PLAYBACK_SUPPRESSION_REASON_NONE),
            "position" to it.currentPosition,
            "duration" to it.duration.coerceAtLeast(0),
            "buffered" to it.bufferedPosition,
            "karaoke" to karaoke,
            "microphoneInput" to (if (karaoke) microphone?.status() else null),
        )
    }

    private fun emitPlayback(tick: Boolean = false) {
        val state = snapshot() ?: return
        sink?.success(state + mapOf("event" to (if (tick) "position" else "playback")))
    }

    private fun requirePlayer(): ExoPlayer =
        player ?: throw StemFailure("playback", "分轨播放器尚未启动。")

    private fun MethodCall.number(key: String): Number = requireNotNull(argument<Number>(key))

    private fun MethodCall.gain(key: String): Float = number(key).toFloat().coerceIn(0f, 1f)
}

private data class MixGains(val vocals: Float = 1f, val accompaniment: Float = 1f)

@OptIn(UnstableApi::class)
private class StemMixProcessor : BaseAudioProcessor() {
    @Volatile var gains = MixGains()
    private var vocals = 1f
    private var accompaniment = 1f

    override fun onConfigure(input: AudioFormat): AudioFormat {
        if (input.encoding != C.ENCODING_PCM_16BIT || input.channelCount != 4) {
            throw UnhandledAudioFormatException(input)
        }
        return AudioFormat(input.sampleRate, 2, C.ENCODING_PCM_16BIT)
    }

    override fun queueInput(input: ByteBuffer) {
        val output = replaceOutputBuffer(input.remaining() / 2).order(ByteOrder.LITTLE_ENDIAN)
        input.order(ByteOrder.LITTLE_ENDIAN)
        val target = gains
        while (input.remaining() >= 8) {
            // 消除快速拖动滑块时的增益突变，混音线程只处理已经读取好的 PCM。
            vocals += (target.vocals - vocals) * 0.005f
            accompaniment += (target.accompaniment - accompaniment) * 0.005f
            val vocalLeft = input.short
            val vocalRight = input.short
            val musicLeft = input.short
            val musicRight = input.short
            output.putShort(mix(vocalLeft, musicLeft))
            output.putShort(mix(vocalRight, musicRight))
        }
        output.flip()
    }

    private fun mix(voice: Short, music: Short): Short =
        ((voice * vocals + music * accompaniment) / STEM_HEADROOM).roundToInt()
            .coerceIn(-32768, 32767).toShort()
}
