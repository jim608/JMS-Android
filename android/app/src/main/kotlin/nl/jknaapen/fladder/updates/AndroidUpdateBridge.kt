package nl.jknaapen.fladder.updates

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.Settings
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.FileProvider
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.ZipFile

class UpdateFileProvider : FileProvider()

class AndroidUpdateBridge(private val activity: AudioServiceFragmentActivity, messenger: BinaryMessenger) :
    DefaultLifecycleObserver {
    private val channel = MethodChannel(messenger, "com.jim608.jms/updates")
    private val handler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private val cancelled = AtomicBoolean(false)
    private val allowed = AtomicBoolean(true)
    private val busy = AtomicBoolean(false)
    private val directory = File(activity.cacheDir, "jms-updates").apply { mkdirs() }
    private val partial = File(directory, "update.part")
    private val ready = File(directory, "update.apk")
    private var verified: Map<*, *>? = null
    private var installResult: MethodChannel.Result? = null
    @Volatile private var connection: HttpURLConnection? = null
    private val installer = activity.registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        installResult?.success(if (result.resultCode == Activity.RESULT_CANCELED) "installCancelled" else "installPending")
        installResult = null
        busy.set(false)
    }

    init {
        partial.delete()
        if (ready.exists() && System.currentTimeMillis() - ready.lastModified() > 86400000) ready.delete()
        activity.lifecycle.addObserver(this)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "device" -> {
                    val installed = installed()
                    result.success(mapOf("applicationId" to installed.packageName, "versionCode" to code(installed),
                        "sdk" to Build.VERSION.SDK_INT, "abis" to Build.SUPPORTED_ABIS.toList()))
                }
                "allowed" -> {
                    allowed.set(call.arguments == true)
                    if (!allowed.get()) cancelled.set(true)
                    result.success(null)
                }
                "cancel" -> {
                    cancelled.set(true)
                    connection?.disconnect()
                    result.success(null)
                }
                "canInstall" -> result.success(canInstall())
                "permission" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= 26) activity.startActivity(
                            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + activity.packageName)))
                        result.success(null)
                    } catch (_: Exception) { result.error("systemBlocked", "System settings unavailable", null) }
                }
                "download" -> work(result) { download(call.arguments as Map<*, *>); null }
                "install" -> install(result)
                else -> result.notImplemented()
            }
        }
    }

    private fun install(result: MethodChannel.Result) {
        if (!allowed.get()) { result.error("playback", "Playback active", null); return }
        if (!canInstall()) { result.error("permission", "Install permission required", null); return }
        if (!busy.compareAndSet(false, true)) { result.error("busy", "Update work in progress", null); return }
        cancelled.set(false)
        executor.execute {
            try {
                validate(ready, verified ?: throw UpdateError("notVerified"), true)
                handler.post {
                    if (!allowed.get() || !canInstall()) {
                        busy.set(false)
                        result.error("permission", "Installation deferred", null)
                    } else try {
                        val uri = FileProvider.getUriForFile(activity, activity.packageName + ".update_provider", ready)
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            putExtra(Intent.EXTRA_RETURN_RESULT, true)
                        }
                        installResult = result
                        installer.launch(intent)
                    } catch (_: Exception) {
                        installResult = null
                        busy.set(false)
                        result.error("systemBlocked", "System installer unavailable", null)
                    }
                }
            } catch (error: Exception) {
                busy.set(false)
                handler.post { result.error((error as? UpdateError)?.reason ?: "invalidApk", "APK verification failed", null) }
            }
        }
    }

    private fun work(result: MethodChannel.Result, operation: () -> Any?) {
        if (!allowed.get()) { result.error("playback", "Playback active", null); return }
        if (!busy.compareAndSet(false, true)) { result.error("busy", "Update work in progress", null); return }
        cancelled.set(false)
        executor.execute {
            try {
                val value = operation()
                handler.post { result.success(value) }
            } catch (error: Exception) {
                partial.delete()
                ready.delete()
                verified = null
                val reason = if (cancelled.get()) "cancelled" else (error as? UpdateError)?.reason ?: "download"
                handler.post { result.error(reason, "Update operation stopped", null) }
            } finally {
                connection?.disconnect()
                connection = null
                busy.set(false)
            }
        }
    }

    private fun checkAllowed() {
        if (cancelled.get() || !allowed.get()) throw UpdateError("cancelled")
    }

    private fun download(metadata: Map<*, *>) {
        val apk = metadata["apk"] as Map<*, *>
        val expectedSize = (apk["size"] as Number).toLong()
        if (expectedSize !in 1..UpdatePolicy.MAX_BYTES) throw UpdateError("size")
        val repository = metadata["repository"] as String
        var address = metadata["url"] as String
        if (!UpdatePolicy.assetAllowed(address, repository)) throw UpdateError("source")
        if (StatFs(directory.path).availableBytes < expectedSize * 2 + 16 * 1024 * 1024) throw UpdateError("space")
        verified = null
        ready.delete()
        partial.delete()
        var response: HttpURLConnection? = null
        for (redirect in 0..5) {
            checkAllowed()
            val candidate = URL(address).openConnection() as HttpURLConnection
            connection = candidate
            candidate.instanceFollowRedirects = false
            candidate.connectTimeout = 15000
            candidate.readTimeout = 20000
            candidate.setRequestProperty("User-Agent", "JMS-Android-Updater")
            val status = candidate.responseCode
            if (status in 300..399) {
                val location = candidate.getHeaderField("Location") ?: throw UpdateError("source")
                val next = URL(URL(address), location).toString()
                candidate.disconnect()
                if (!UpdatePolicy.redirectAllowed(next)) throw UpdateError("source")
                address = next
                continue
            }
            if (status != 200) { candidate.disconnect(); throw UpdateError("download") }
            if (candidate.contentLengthLong >= 0 && candidate.contentLengthLong != expectedSize) throw UpdateError("size")
            response = candidate
            break
        }
        val stream = response?.inputStream ?: throw UpdateError("source")
        val digest = MessageDigest.getInstance("SHA-256")
        var received = 0L
        var lastEvent = 0L
        stream.use { input ->
            partial.outputStream().use { output ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    checkAllowed()
                    val count = input.read(buffer)
                    if (count < 0) break
                    received += count
                    if (received > expectedSize) throw UpdateError("size")
                    digest.update(buffer, 0, count)
                    output.write(buffer, 0, count)
                    val now = System.currentTimeMillis()
                    if (now - lastEvent > 250) {
                        lastEvent = now
                        val progress = received.toDouble() / expectedSize
                        handler.post { channel.invokeMethod("progress", progress) }
                    }
                }
            }
        }
        checkAllowed()
        if (!UpdatePolicy.matchingContent(received, expectedSize, hex(digest.digest()), apk["sha256"] as String))
            throw UpdateError("hash")
        validate(partial, metadata, false)
        checkAllowed()
        if (!partial.renameTo(ready)) throw UpdateError("space")
        ready.setReadOnly()
        verified = metadata
        handler.post { channel.invokeMethod("progress", 1.0) }
    }

    @Suppress("DEPRECATION")
    private fun installed(): PackageInfo = activity.packageManager.getPackageInfo(activity.packageName,
        if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES)
    @Suppress("DEPRECATION")
    private fun code(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
    @Suppress("DEPRECATION")
    private fun signers(info: PackageInfo): Set<String> {
        val certificates = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        return certificates?.map { hex(MessageDigest.getInstance("SHA-256").digest(it.toByteArray())) }?.toSet() ?: emptySet()
    }
    @Suppress("DEPRECATION")
    private fun validate(file: File, metadata: Map<*, *>, rehash: Boolean) {
        checkAllowed()
        val apk = metadata["apk"] as Map<*, *>
        if (!file.isFile || file.length() != (apk["size"] as Number).toLong()) throw UpdateError("size")
        if (rehash) {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    checkAllowed()
                    val count = input.read(buffer)
                    if (count < 0) break
                    digest.update(buffer, 0, count)
                }
            }
            if (hex(digest.digest()) != apk["sha256"]) throw UpdateError("hash")
        }
        val candidate = activity.packageManager.getPackageArchiveInfo(file.path,
            if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES)
            ?: throw UpdateError("invalidApk")
        val installed = installed()
        val abis = ZipFile(file).use { archive ->
            if (archive.getEntry("classes.dex") == null || archive.getEntry("lib/arm64-v8a/libflutter.so") == null ||
                archive.getEntry("lib/arm64-v8a/libapp.so") == null || !candidate.splitNames.isNullOrEmpty())
                throw UpdateError("split")
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
    private fun canInstall() = Build.VERSION.SDK_INT < 26 || activity.packageManager.canRequestPackageInstalls()
    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }
    override fun onDestroy(owner: LifecycleOwner) {
        cancelled.set(true)
        connection?.disconnect()
        executor.shutdownNow()
        channel.setMethodCallHandler(null)
    }
    private class UpdateError(val reason: String) : Exception()
}
