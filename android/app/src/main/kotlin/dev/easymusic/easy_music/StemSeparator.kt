package dev.easymusic.easy_music

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtSession
import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.io.RandomAccessFile
import java.net.URL
import java.security.DigestOutputStream
import java.security.MessageDigest
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean

internal const val MAX_STEM_BYTES = 384 * 1024 * 1024
private const val MODEL_PATH = "/csukuangfj/sherpa-onnx-spleeter-2stems-fp16/resolve/" +
    "93ba771920ade509f8cbd6825b1a90856c797e08/"
private val MODEL_HOSTS = listOf("https://huggingface.co", "https://hf-mirror.com")
private val MODELS = listOf(
    StemModel("vocals", 19681017L, "24cef84aedcd1fe87c0b743ef3370ad34dc1fabf6c9014d6128a75a538c7b668"),
    StemModel("accompaniment", 19681024L, "d14cea55793cc531a5875f5f4da08207d1c5ab9292e8e0099a104eecb014fcc0"),
)

internal class StemJob(val id: Long) {
    private val cancelled = AtomicBoolean(false)

    private var inference: OrtSession.RunOptions? = null

    @Synchronized
    fun cancel() {
        cancelled.set(true)
        runCatching { inference?.setTerminate(true) }
    }

    fun run(session: OrtSession, input: Map<String, OnnxTensor>, output: Map<String, OnnxTensor>) {
        OrtSession.RunOptions().use { options ->
            synchronized(this) {
                check()
                inference = options
            }
            try {
                session.run(input, emptySet(), output, options).use { check() }
            } finally {
                synchronized(this) { inference = null }
                check()
            }
        }
    }

    fun check() {
        if (cancelled.get() || Thread.currentThread().isInterrupted) throw CancellationException()
    }
}

internal class StemSeparator(private val context: Context) {
    private val cache = File(context.cacheDir, "music-stems-v2")
    private val legacyCache = File(context.cacheDir, "music-stems-v1")
    private val modelDirectory = File(context.noBackupFilesDir, "music-stem-model")
    private val digestName = Regex("[a-f0-9]{64}")

    fun removeLegacyCache(): Boolean {
        if (!legacyCache.exists()) return false
        if (!legacyCache.deleteRecursively()) {
            throw StemFailure("storage", "无法清理旧分轨缓存。")
        }
        return true
    }

    fun hasResources(source: Uri, cacheKey: String?): Boolean {
        val reference = reference(source, cacheKey)
        if (cachedWave(reference) != null) return true
        if (cache.listFiles { file -> file.extension == "wav" }.isNullOrEmpty()) return false
        // 老缓存仅有内容哈希。尝试读取本地文件或完整在线缓存，补上快速查找索引。
        val digest = MessageDigest.getInstance("SHA-256")
        val discard = object : OutputStream() {
            override fun write(value: Int) = Unit
            override fun write(bytes: ByteArray, offset: Int, count: Int) = Unit
        }
        return runCatching {
            DigestOutputStream(discard, digest).use { output ->
                readSource(source, output, StemJob(0)) {}
            }
            val wave = File(cache, digest.digest().toHex() + ".wav")
            if (!validWave(wave)) return@runCatching false
            remember(reference, wave)
            true
        }.getOrDefault(false)
    }

    fun prepare(
        source: Uri,
        cacheKey: String?,
        job: StemJob,
        playingFile: () -> File?,
        progress: (String, Double?) -> Unit,
    ): File {
        cache.mkdirs()
        val reference = reference(source, cacheKey)
        cachedWave(reference)?.let {
            job.check()
            it.setLastModified(System.currentTimeMillis())
            return it
        }
        val snapshot = File.createTempFile("stem-input-", ".audio", cache)
        try {
            progress("reading", null)
            val digest = MessageDigest.getInstance("SHA-256")
            DigestOutputStream(snapshot.outputStream().buffered(), digest).use { output ->
                readSource(source, output, job) { progress("sourceDownload", it) }
            }
            val key = digest.digest().toHex()
            val output = File(cache, "$key.wav")
            if (validWave(output)) {
                output.setLastModified(System.currentTimeMillis())
                job.check()
                remember(reference, output)
                return output
            }
            output.delete()
            val decoded = File.createTempFile("stem-decoded-", ".pcm", cache)
            val partial = File.createTempFile("stem-mixed-", ".part", cache)
            try {
                progress("decoding", null)
                val frames = decodeStemInput(snapshot, decoded, job::check)
                snapshot.delete()
                val bytes = (frames.last - frames.first + 1L) * 8 + 44
                trim(bytes, playingFile())
                if (cache.usableSpace < bytes + 4 * 1024 * 1024) {
                    throw StemFailure("storage", "可用空间不足，无法保存分轨。")
                }
                var downloaded = 0L
                val totalModelBytes = MODELS.sumOf { it.bytes }
                val (vocals, accompaniment) = MODELS.map { model ->
                    val sources = MODEL_HOSTS.map { URL(it + MODEL_PATH + model.name + ".fp16.onnx?download=true") }
                    val file = getStemModel(model, modelDirectory, sources, job) { part ->
                        progress("download", (downloaded + part).toDouble() / totalModelBytes)
                    }
                    downloaded += model.bytes
                    file
                }
                writeStems(vocals, accompaniment, decoded, frames, partial, job, progress)
                job.check()
                if (partial.length() != bytes || !partial.renameTo(output)) {
                    throw StemFailure("storage", "无法保存分轨文件。")
                }
                remember(reference, output)
                return output
            } finally {
                decoded.delete()
                partial.delete()
            }
        } finally {
            snapshot.delete()
        }
    }

    private fun readSource(source: Uri, output: OutputStream, job: StemJob, progress: (Double?) -> Unit) {
        if (source.scheme == "http") {
            try {
                readRemoteStem(URL(source.toString()), output, job, progress)
            } catch (_: IOException) {
                job.check()
                throw StemFailure("source", "在线音频读取失败，请检查网络和可用空间。")
            }
        } else {
            val input = context.contentResolver.openInputStream(source)
                ?: throw StemFailure("file", "无法打开这首本地歌曲。")
            input.use { copyStemBytes(it, output, job) }
        }
    }

    private fun reference(source: Uri, cacheKey: String?): File? {
        if (source.scheme == "http") {
            return cacheKey?.takeIf(digestName::matches)?.let { File(cache, "online-$it.ref") }
        }
        val metadata = runCatching {
            if (source.scheme == "file") {
                val file = File(checkNotNull(source.path))
                file.length() to file.lastModified()
            } else {
                context.contentResolver.query(source, arrayOf(
                    OpenableColumns.SIZE, DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                ), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val size = cursor.getColumnIndex(OpenableColumns.SIZE)
                        val modified = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                        if (size >= 0 && modified >= 0) cursor.getLong(size) to cursor.getLong(modified) else null
                    } else null
                }
            }
        }.getOrNull() ?: return null
        if (metadata.first <= 0 || metadata.second <= 0) return null
        val hash = MessageDigest.getInstance("SHA-256")
            .digest("$source\n${metadata.first}\n${metadata.second}".toByteArray()).toHex()
        return File(cache, "local-$hash.ref")
    }

    private fun referencedWave(reference: File?): File? = runCatching {
        if (reference?.length() != 64L) return@runCatching null
        val name = reference.readText().takeIf(digestName::matches) ?: return@runCatching null
        File(cache, "$name.wav")
    }.getOrNull()

    private fun cachedWave(reference: File?): File? = referencedWave(reference)?.takeIf(::validWave)

    private fun remember(reference: File?, wave: File) {
        if (reference != null) runCatching { reference.writeText(wave.nameWithoutExtension) }
    }

    fun clear() {
        cache.listFiles()?.forEach {
            if (!it.delete()) throw StemFailure("storage", "有分轨缓存无法清理。")
        }
    }

    private fun validWave(file: File): Boolean {
        if (file.length() <= 44 || file.length() > MAX_STEM_BYTES) return false
        return runCatching {
            RandomAccessFile(file, "r").use {
                val riff = it.readInt()
                it.seek(40)
                val bytes = Integer.reverseBytes(it.readInt())
                riff == 0x52494646 && bytes > 0 && bytes % 8 == 0 && bytes + 44L == it.length()
            }
        }.getOrDefault(false)
    }

    private fun trim(required: Long, playing: File?) {
        val files = cache.listFiles { file -> file.extension == "wav" } ?: return
        var bytes = files.sumOf { it.length() }
        for (file in files.sortedBy { it.lastModified() }) {
            if (bytes + required <= MAX_STEM_BYTES) break
            val size = file.length()
            if (file != playing && file.delete()) bytes -= size
        }
        cache.listFiles { file -> file.extension == "ref" }?.forEach {
            if (referencedWave(it)?.isFile != true) it.delete()
        }
        if (bytes + required > MAX_STEM_BYTES) {
            throw StemFailure("storage", "分轨缓存已满，请先切回原声或清理缓存。")
        }
    }
}

internal fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
