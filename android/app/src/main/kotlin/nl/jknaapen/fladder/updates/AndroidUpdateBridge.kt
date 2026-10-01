package nl.jknaapen.fladder.updates

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.FileProvider
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.Observer
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class UpdateFileProvider : FileProvider()

class AndroidUpdateBridge(private val activity: AudioServiceFragmentActivity, messenger: BinaryMessenger) :
    DefaultLifecycleObserver {
    private val channel = MethodChannel(messenger, "com.jim608.jms/updates")
    private val handler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private val allowed = AtomicBoolean(true)
    private val installing = AtomicBoolean(false)
    private val manager = WorkManager.getInstance(activity.applicationContext)
    private val transfer = AndroidUpdateTransfer(activity.applicationContext)
    private var observedId: UUID? = null
    private var observer: Observer<WorkInfo?>? = null
    private var downloadResult: MethodChannel.Result? = null
    private var installResult: MethodChannel.Result? = null
    private val installer = activity.registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        installResult?.success(if (result.resultCode == Activity.RESULT_CANCELED) "installCancelled" else "installPending")
        installResult = null
        installing.set(false)
    }

    init {
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
                    if (!allowed.get()) cancelActive()
                    result.success(null)
                }
                "cancel" -> executor.execute {
                    try {
                        synchronized(workLock) {
                            manager.cancelUniqueWork(AndroidUpdateWorker.UNIQUE_WORK).result.get(10, TimeUnit.SECONDS)
                            transfer.clear()
                        }
                        handler.post { result.success(null) }
                    } catch (_: Exception) {
                        handler.post { result.error("download", "Update cancellation unavailable", null) }
                    }
                }
                "restore" -> restore(result)
                "canInstall" -> result.success(canInstall())
                "permission" -> {
                    if (!foreground() || !allowed.get()) { result.error("playback", "Installation deferred", null) }
                    else try {
                        if (Build.VERSION.SDK_INT >= 26) activity.startActivity(
                            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + activity.packageName)))
                        result.success(null)
                    } catch (_: Exception) { result.error("systemBlocked", "System settings unavailable", null) }
                }
                "download" -> download(call.arguments as? Map<*, *>, result)
                "install" -> install(result)
                else -> result.notImplemented()
            }
        }
    }

    private fun currentWork(): WorkInfo? {
        val active = manager.getWorkInfosForUniqueWork(AndroidUpdateWorker.UNIQUE_WORK)
            .get(10, TimeUnit.SECONDS).filter { !it.state.isFinished }
        if (active.size > 1) throw UpdateError("busy")
        if (active.isNotEmpty()) return active.single()
        return transfer.jobId()?.let {
            manager.getWorkInfoById(UUID.fromString(it)).get(10, TimeUnit.SECONDS)
        }
    }

    private fun cancelActive() {
        executor.execute {
            runCatching {
                synchronized(workLock) {
                    val work = currentWork()
                    if (work != null && !work.state.isFinished) {
                        manager.cancelWorkById(work.id).result.get(10, TimeUnit.SECONDS)
                        transfer.clear()
                    }
                }
            }
        }
    }

    private fun restore(result: MethodChannel.Result) {
        executor.execute {
            val value = runCatching {
                val metadata = transfer.request() ?: return@runCatching null
                val work = currentWork() ?: return@runCatching null
                if (metadata["_workId"] != work.id.toString()) return@runCatching null
                val status = when (work.state) {
                    WorkInfo.State.ENQUEUED, WorkInfo.State.RUNNING, WorkInfo.State.BLOCKED -> "downloading"
                    WorkInfo.State.SUCCEEDED -> {
                        val verified = transfer.verified() ?: return@runCatching null
                        if (!transfer.installFile().isFile || transfer.key(verified) != transfer.key(metadata)) return@runCatching null
                        "downloaded"
                    }
                    WorkInfo.State.FAILED -> "failed"
                    WorkInfo.State.CANCELLED -> "cancelled"
                }
                mapOf("status" to status, "metadata" to metadata,
                    "progress" to if (status == "downloaded") 1.0 else transfer.progress(metadata),
                    "failure" to work.outputData.getString(AndroidUpdateWorker.FAILURE))
            }.getOrNull()
            handler.post { result.success(value) }
        }
    }

    private fun download(metadata: Map<*, *>?, result: MethodChannel.Result) {
        if (!allowed.get()) { result.error("playback", "Playback active", null); return }
        if (installing.get()) { result.error("busy", "Installation in progress", null); return }
        val userInitiatedInForeground = foreground()
        executor.execute {
            synchronized(workLock) {
            try {
                val request = metadata ?: throw UpdateError("invalidApk")
                val key = transfer.key(request)
                if (!allowed.get()) throw UpdateError("cancelled")
                val old = currentWork()
                val previous = transfer.request()
                if (old != null && !old.state.isFinished) {
                    if (previous == null || previous["_workId"] != old.id.toString() ||
                        transfer.key(previous) != key || !old.tags.contains(AndroidUpdateWorker.TAG_PREFIX + key))
                        throw UpdateError("busy")
                    handler.post { observe(old.id, result) }
                    return@execute
                }
                val verified = transfer.verified()
                if (verified != null && transfer.key(verified) == key) {
                    transfer.validate(transfer.installFile(), verified, true)
                    handler.post { result.success(null) }
                    return@execute
                }
                if (!userInitiatedInForeground) throw UpdateError("playback")
                val worker = OneTimeWorkRequestBuilder<AndroidUpdateWorker>()
                    .addTag(AndroidUpdateWorker.TAG_PREFIX + key)
                    .setInputData(Data.Builder().putString(AndroidUpdateWorker.METADATA, JSONObject(request).toString())
                        .putString(AndroidUpdateWorker.BINDING, key).build())
                    .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                    .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 10, TimeUnit.SECONDS)
                    .build()
                manager.enqueueUniqueWork(AndroidUpdateWorker.UNIQUE_WORK, ExistingWorkPolicy.KEEP, worker)
                    .result.get(10, TimeUnit.SECONDS)
                transfer.saveRequest(request, worker.id.toString())
                handler.post { observe(worker.id, result) }
            } catch (error: Exception) {
                handler.post { result.error((error as? UpdateError)?.reason ?: "download", "Update transfer unavailable", null) }
            }
            }
        }
    }

    private fun observe(id: UUID, result: MethodChannel.Result) {
        detachObserver()
        downloadResult?.error("detached", "Update observer replaced", null)
        downloadResult = result
        observedId = id
        val listener = Observer<WorkInfo?> { work ->
            if (work == null) return@Observer
            val progress = work.progress.getDouble(AndroidUpdateWorker.PROGRESS, -1.0)
            if (progress >= 0.0) channel.invokeMethod("progress", progress)
            if (work.state.isFinished) {
                val pending = downloadResult
                downloadResult = null
                detachObserver()
                when (work.state) {
                    WorkInfo.State.SUCCEEDED -> pending?.success(null)
                    WorkInfo.State.CANCELLED -> pending?.error("cancelled", "Update cancelled", null)
                    else -> pending?.error(work.outputData.getString(AndroidUpdateWorker.FAILURE) ?: "download", "Update download stopped", null)
                }
            }
        }
        observer = listener
        manager.getWorkInfoByIdLiveData(id).observe(activity, listener)
    }

    private fun install(result: MethodChannel.Result) {
        if (!foreground() || !allowed.get()) { result.error("playback", "Installation deferred", null); return }
        if (!canInstall()) { result.error("permission", "Install permission required", null); return }
        if (!installing.compareAndSet(false, true)) { result.error("busy", "Installation in progress", null); return }
        executor.execute {
            try {
                if (currentWork()?.state?.isFinished == false) throw UpdateError("busy")
                val verified = transfer.verified() ?: throw UpdateError("notVerified")
                transfer.validate(transfer.installFile(), verified, true)
                handler.post {
                    if (!foreground() || !allowed.get() || !canInstall()) {
                        installing.set(false)
                        result.error("permission", "Installation deferred", null)
                    } else try {
                        val uri = FileProvider.getUriForFile(activity, activity.packageName + ".update_provider", transfer.installFile())
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            putExtra(Intent.EXTRA_RETURN_RESULT, true)
                        }
                        installResult = result
                        installer.launch(intent)
                    } catch (_: Exception) {
                        installResult = null
                        installing.set(false)
                        result.error("systemBlocked", "System installer unavailable", null)
                    }
                }
            } catch (error: Exception) {
                installing.set(false)
                handler.post { result.error((error as? UpdateError)?.reason ?: "invalidApk", "APK verification failed", null) }
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun installed(): PackageInfo = activity.packageManager.getPackageInfo(activity.packageName,
        if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES)
    @Suppress("DEPRECATION")
    private fun code(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
    private fun foreground() = activity.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
    private fun canInstall() = Build.VERSION.SDK_INT < 26 || activity.packageManager.canRequestPackageInstalls()
    private fun detachObserver() {
        val oldId = observedId
        val oldObserver = observer
        observedId = null
        observer = null
        if (oldId != null && oldObserver != null) manager.getWorkInfoByIdLiveData(oldId).removeObserver(oldObserver)
    }
    override fun onDestroy(owner: LifecycleOwner) {
        detachObserver()
        downloadResult?.error("detached", "Update observer detached", null)
        downloadResult = null
        executor.shutdown()
        channel.setMethodCallHandler(null)
        // The application-context Worker owns transport; Activity destruction must not cancel it.
    }
    companion object { private val workLock = Any() }
}
