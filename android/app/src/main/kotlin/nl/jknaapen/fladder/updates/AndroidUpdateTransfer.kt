package nl.jknaapen.fladder.updates

import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.StatFs
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.ZipFile

internal class UpdateError(val reason: String) : Exception()

internal fun JSONObject.asMap(): Map<String, Any?> = keys().asSequence().associateWith { key ->
    when (val value = opt(key)) {
        JSONObject.NULL -> null
        is JSONObject -> value.asMap()
        is JSONArray -> (0 until value.length()).map { value.opt(it) }
        else -> value
    }
}

internal class AndroidUpdateTransfer(private val context: Context) {
    private val directory = File(context.cacheDir, "jms-updates").apply { mkdirs() }
    private val partial = File(directory, "update.part")
    private val ready = File(directory, "update.apk")
    private val requestFile = File(directory, "request.json")
    private val bindingFile = File(directory, "partial.binding")
    private val verifiedFile = File(directory, "verified.json")
    private val cancelled = AtomicBoolean(false)
    @Volatile private var connection: HttpURLConnection? = null

    fun key(metadata: Map<*, *>): String {
        val apk = metadata["apk"] as? Map<*, *> ?: throw UpdateError("invalidApk")
        val repository = metadata["repository"] as? String ?: throw UpdateError("source")
        val url = metadata["url"] as? String ?: throw UpdateError("source")
        if (!UpdatePolicy.assetAllowed(url, repository)) throw UpdateError("source")
        if ((metadata["platform"] ?: "android") != "android" ||
            metadata["applicationId"] != "com.jim608.jms" ||
            metadata["schemaVersion"] != 1 ||
            (metadata["abis"] as? List<*>) != listOf("arm64-v8a") ||
            !Regex("[a-f0-9]{40}").matches(metadata["sourceCommit"] as? String ?: "") ||
            !Regex("[a-f0-9]{64}").matches(apk["sha256"] as? String ?: "") ||
            (apk["size"] as? Number)?.toLong() !in 1..UpdatePolicy.MAX_BYTES ||
            (metadata["versionCode"] as? Number)?.toLong()?.let { it > 0 } != true ||
            (metadata["minSdk"] as? Number)?.toInt()?.let { it in 24..Build.VERSION.SDK_INT } != true ||
            (metadata["versionName"] as? String).isNullOrBlank()) throw UpdateError("incompatible")
        return UpdatePolicy.transferBinding(repository, url, metadata["versionName"] as String,
            (metadata["versionCode"] as Number).toLong(), (metadata["minSdk"] as Number).toInt(),
            metadata["sourceCommit"] as String, (apk["size"] as Number).toLong(), apk["sha256"] as String)
            ?: throw UpdateError("incompatible")
    }

    fun saveRequest(metadata: Map<*, *>, workId: String) {
        key(metadata)
        writeJson(requestFile, metadata.entries.associate { it.key.toString() to it.value } + ("_workId" to workId))
    }

    fun request(): Map<String, Any?>? = readJson(requestFile)
    fun jobId(): String? = request()?.get("_workId") as? String
    fun verified(): Map<String, Any?>? = readJson(verifiedFile)
    fun progress(metadata: Map<*, *>): Double {
        val expected = ((metadata["apk"] as? Map<*, *>)?.get("size") as? Number)?.toLong() ?: return 0.0
        if (expected <= 0 || !bindingFile.isFile || bindingFile.readText() != partialBinding(metadata)) return 0.0
        return (partial.length().toDouble() / expected).coerceIn(0.0, 1.0)
    }

    fun stop() { cancelled.set(true); connection?.disconnect() }
    fun clear() = synchronized(fileLock) {
        partial.delete()
        bindingFile.delete()
        ready.delete()
        verifiedFile.delete()
    }
    fun clearIfBound(metadata: Map<*, *>) = synchronized(fileLock) {
        if (bindingFile.isFile && bindingFile.readText() == partialBinding(metadata)) clear()
    }
    private fun partialBinding(metadata: Map<*, *>) =
        UpdatePolicy.partialBinding(key(metadata), metadata["_workId"] as? String ?: "") ?: throw UpdateError("source")

    fun download(metadata: Map<*, *>, stopped: () -> Boolean, progress: (Double) -> Unit) {
        val transferKey = partialBinding(metadata)
        val apk = metadata["apk"] as Map<*, *>
        val expectedSize = (apk["size"] as Number).toLong()
        if (StatFs(directory.path).availableBytes < expectedSize * 2 + 16 * 1024 * 1024) throw UpdateError("space")
        fun check() { if (cancelled.get() || stopped() || Thread.currentThread().isInterrupted) throw UpdateError("cancelled") }
        synchronized(fileLock) {
            check()
            val same = bindingFile.isFile && bindingFile.readText() == transferKey
            if (!same) { clear(); bindingFile.writeText(transferKey) }
            ready.delete()
            verifiedFile.delete()
        }
        if (partial.length() > expectedSize) throw UpdateError("size")
        var received = partial.length()
        val digest = MessageDigest.getInstance("SHA-256")
        if (received > 0) partial.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) { check(); val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
        }
        if (received < expectedSize) {
            var address = metadata["url"] as String
            var response: HttpURLConnection? = null
            try {
                for (redirect in 0..5) {
                    check()
                    val candidate = URL(address).openConnection() as HttpURLConnection
                    connection = candidate
                    candidate.instanceFollowRedirects = false
                    candidate.connectTimeout = 15000
                    candidate.readTimeout = 20000
                    candidate.setRequestProperty("User-Agent", "JMS-Android-Updater")
                    candidate.setRequestProperty("Accept-Encoding", "identity")
                    if (received > 0) candidate.setRequestProperty("Range", "bytes=$received-")
                    val status = candidate.responseCode
                    if (status in 300..399) {
                        val location = candidate.getHeaderField("Location") ?: throw UpdateError("source")
                        val next = URL(URL(address), location).toString()
                        candidate.disconnect()
                        if (!UpdatePolicy.redirectAllowed(next)) throw UpdateError("source")
                        address = next
                        continue
                    }
                    val start = UpdatePolicy.responseStart(status, candidate.getHeaderField("Content-Range"), received, expectedSize)
                        ?: run { candidate.disconnect(); throw UpdateError("download") }
                    if (start == 0L) { received = 0; digest.reset() }
                    if (candidate.contentLengthLong >= 0 && candidate.contentLengthLong != expectedSize - received)
                        throw UpdateError("size")
                    response = candidate
                    break
                }
                val input = response?.inputStream ?: throw UpdateError("source")
                var lastEvent = 0L
                input.use { stream -> partial.outputStreamAppend(received > 0).use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        check()
                        val count = stream.read(buffer)
                        if (count < 0) break
                        received += count
                        if (received > expectedSize) throw UpdateError("size")
                        digest.update(buffer, 0, count)
                        output.write(buffer, 0, count)
                        val now = System.currentTimeMillis()
                        if (now - lastEvent > 250) { lastEvent = now; progress(received.toDouble() / expectedSize) }
                    }
                } }
            } finally { connection?.disconnect(); connection = null }
        }
        check()
        if (received < expectedSize) throw IOException("Incomplete update transfer")
        if (!UpdatePolicy.matchingContent(received, expectedSize, hex(digest.digest()), apk["sha256"] as String)) throw UpdateError("hash")
        validate(partial, metadata, false, ::check)
        check()
        if (!partial.renameTo(ready)) throw UpdateError("space")
        ready.setReadOnly()
        check()
        writeJson(verifiedFile, metadata)
        progress(1.0)
    }

    @Suppress("DEPRECATION")
    private fun installed(): PackageInfo = context.packageManager.getPackageInfo(context.packageName,
        if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES)
    @Suppress("DEPRECATION")
    private fun code(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
    @Suppress("DEPRECATION")
    private fun signers(info: PackageInfo): Set<String> {
        val certificates = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        return certificates?.map { hex(MessageDigest.getInstance("SHA-256").digest(it.toByteArray())) }?.toSet() ?: emptySet()
    }
    @Suppress("DEPRECATION")
    fun validate(file: File, metadata: Map<*, *>, rehash: Boolean, check: () -> Unit = {}) {
        key(metadata)
        check()
        val apk = metadata["apk"] as Map<*, *>
        if (!file.isFile || file.length() != (apk["size"] as Number).toLong()) throw UpdateError("size")
        if (rehash) {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) { check(); val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
            }
            if (hex(digest.digest()) != apk["sha256"]) throw UpdateError("hash")
        }
        val candidate = context.packageManager.getPackageArchiveInfo(file.path,
            if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES)
            ?: throw UpdateError("invalidApk")
        val installed = installed()
        val abis = ZipFile(file).use { archive ->
            if (archive.getEntry("classes.dex") == null || archive.getEntry("lib/arm64-v8a/libflutter.so") == null ||
                archive.getEntry("lib/arm64-v8a/libapp.so") == null || !candidate.splitNames.isNullOrEmpty()) throw UpdateError("split")
            archive.entries().asSequence().map { it.name }.filter { it.startsWith("lib/") && it.endsWith(".so") }
                .map { it.split("/")[1] }.toSet()
        }
        if (metadata["applicationId"] != candidate.packageName ||
            !UpdatePolicy.compatible(candidate.packageName, installed.packageName, code(candidate), code(installed),
                (metadata["versionCode"] as Number).toLong(), candidate.versionName, metadata["versionName"] as String,
                candidate.applicationInfo?.minSdkVersion ?: 0, (metadata["minSdk"] as Number).toInt(),
                Build.VERSION.SDK_INT, abis, Build.SUPPORTED_ABIS.toSet())) throw UpdateError("incompatible")
        if (!UpdatePolicy.matchingSigners(signers(installed), signers(candidate))) throw UpdateError("signature")
    }

    fun installFile(): File = ready
    private fun readJson(file: File): Map<String, Any?>? = runCatching {
        if (!file.isFile || file.length() > 8192) return null
        JSONObject(file.readText()).asMap().also { key(it) }
    }.getOrNull()
    private fun writeJson(file: File, value: Map<*, *>) = synchronized(fileLock) {
        val text = JSONObject(value).toString()
        if (text.toByteArray(Charsets.UTF_8).size > 8192) throw UpdateError("invalidApk")
        val temp = File(directory, file.name + ".tmp")
        temp.writeText(text)
        if (!temp.renameTo(file)) throw UpdateError("space")
    }
    private fun File.outputStreamAppend(append: Boolean) = java.io.FileOutputStream(this, append)
    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }
    companion object { private val fileLock = Any() }
}
