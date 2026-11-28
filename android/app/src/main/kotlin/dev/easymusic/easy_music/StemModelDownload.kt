package dev.easymusic.easy_music

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import javax.net.ssl.HttpsURLConnection

internal data class StemModel(val name: String, val bytes: Long, val sha: String)

internal fun getStemModel(
    spec: StemModel,
    directory: File,
    sources: List<URL>,
    job: StemJob,
    progress: (Long) -> Unit,
): File {
    directory.mkdirs()
    val basename = spec.name + "-" + spec.sha
    val model = File(directory, "$basename.onnx")
    if (model.isFile && model.length() == spec.bytes) return model
    val partial = File(directory, "$basename.part")

    fun publishModel(): Boolean {
        if (partial.length() != spec.bytes) return false
        if (modelDigest(partial, job) != spec.sha) {
            // 坏文件不能成为下次的续传起点。
            if (!partial.delete()) throw StemFailure("storage", "无法清除损坏的分轨模型。")
            return false
        }
        job.check()
        if (!partial.renameTo(model)) throw StemFailure("storage", "无法保存分轨模型。")
        return true
    }

    job.check()
    if (partial.length() > spec.bytes && !partial.delete()) {
        throw StemFailure("storage", "无法清除损坏的分轨模型。")
    }
    if (publishModel()) return model
    if (directory.usableSpace < spec.bytes - partial.length() + 4 * 1024 * 1024) {
        throw StemFailure("storage", "可用空间不足，无法下载分轨模型。")
    }

    // 每个下载源最多试两次。断开的部分保留，切源或下次打开都可以接着下载。
    repeat(2) {
        for (source in sources) {
            job.check()
            progress(partial.length())
            try {
                transferModel(source, spec, partial, job, progress)
            } catch (_: IOException) {
                job.check()
            }
            if (publishModel()) return model
        }
    }
    val message = if (partial.length() > 0) {
        "模型下载失败，已保留下载进度，请检查网络后重试。"
    } else {
        "模型下载失败，请检查网络后重试。"
    }
    throw StemFailure("model", message)
}

private fun transferModel(
    source: URL,
    spec: StemModel,
    partial: File,
    job: StemJob,
    progress: (Long) -> Unit,
) {
    var address = source
    repeat(6) {
        job.check()
        if (address.protocol != "https" || address.userInfo != null) {
            throw IOException("Invalid model download address")
        }
        val offset = partial.length()
        val connection = address.openConnection() as HttpsURLConnection
        try {
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 8000
            connection.readTimeout = 30000
            connection.setRequestProperty("Accept-Encoding", "identity")
            if (offset > 0) connection.setRequestProperty("Range", "bytes=$offset-")
            val status = connection.responseCode
            if (status in 300..399) {
                val location = connection.getHeaderField("Location")
                    ?: throw IOException("Missing model download redirect")
                address = URL(address, location)
                return@repeat
            }
            if (status == 416 && offset > 0) {
                // 下载源无法接受保留的范围，改从该模型的开头下载。
                if (!partial.delete()) throw StemFailure("storage", "无法重置模型下载进度。")
                address = source
                return@repeat
            }
            val length = connection.getHeaderField("Content-Length")?.toLongOrNull()
            val encoding = connection.contentEncoding
            if (encoding != null && !encoding.equals("identity", ignoreCase = true)) {
                throw IOException("Unexpected model content encoding")
            }
            val start = when (status) {
                HttpURLConnection.HTTP_OK -> 0L
                HttpURLConnection.HTTP_PARTIAL -> {
                    val range = stemContentRange.matchEntire(connection.getHeaderField("Content-Range") ?: "")
                        ?: throw IOException("Missing model byte range")
                    val (first, last, total) = range.destructured
                    if (first.toLongOrNull() != offset || last.toLongOrNull() != spec.bytes - 1 ||
                        total.toLongOrNull() != spec.bytes) {
                        throw IOException("Unexpected model byte range")
                    }
                    offset
                }
                else -> throw IOException("Model server returned HTTP $status")
            }
            val remaining = spec.bytes - start
            if (length != null && length != remaining) throw IOException("Unexpected model size")
            progress(start)
            connection.inputStream.use { input ->
                FileOutputStream(partial, start > 0).buffered().use { output ->
                    val buffer = ByteArray(128 * 1024)
                    var written = start
                    while (true) {
                        job.check()
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (written + count > spec.bytes) throw IOException("Model exceeded its declared size")
                        output.write(buffer, 0, count)
                        written += count
                        progress(written)
                    }
                }
            }
            return
        } finally {
            connection.disconnect()
        }
    }
    throw IOException("Too many redirects while downloading the model")
}

private fun modelDigest(file: File, job: StemJob): String {
    val digest = MessageDigest.getInstance("SHA-256")
    file.inputStream().use { input ->
        val buffer = ByteArray(128 * 1024)
        while (true) {
            job.check()
            val count = input.read(buffer)
            if (count < 0) break
            digest.update(buffer, 0, count)
        }
    }
    return digest.digest().toHex()
}
