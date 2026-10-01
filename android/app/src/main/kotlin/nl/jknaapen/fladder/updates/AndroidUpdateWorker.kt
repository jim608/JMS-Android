package nl.jknaapen.fladder.updates

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.Data
import androidx.work.ForegroundInfo
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import nl.jknaapen.fladder.R
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.Executor

class AndroidUpdateWorker(context: Context, parameters: WorkerParameters) : Worker(context, parameters) {
    @Volatile private var transfer: AndroidUpdateTransfer? = null
    private var metadata: Map<String, Any?>? = null

    override fun doWork(): Result {
        val engine = AndroidUpdateTransfer(applicationContext)
        transfer = engine
        try {
            val text = inputData.getString(METADATA) ?: throw UpdateError("invalidApk")
            if (text.toByteArray(Charsets.UTF_8).size > 8192) throw UpdateError("invalidApk")
            val request = JSONObject(text).asMap() + ("_workId" to id.toString())
            metadata = request
            if (engine.key(request) != inputData.getString(BINDING)) throw UpdateError("source")
            engine.saveRequest(request, id.toString())
            setForegroundAsync(foreground(0.0)).get()
            var lastNotification = 0L
            engine.download(request, { isStopped }) { progress ->
                setProgressAsync(Data.Builder().putDouble(PROGRESS, progress).build())
                val now = System.currentTimeMillis()
                if (now - lastNotification >= 1000) {
                    lastNotification = now
                    setForegroundAsync(foreground(progress))
                }
            }
            return Result.success()
        } catch (error: Exception) {
            if (isStopped) return Result.failure()
            if (error is IOException && runAttemptCount < MAX_NETWORK_RETRIES) return Result.retry()
            metadata?.let { engine.clearIfBound(it) }
            val reason = (error as? UpdateError)?.reason ?: "download"
            return Result.failure(Data.Builder().putString(FAILURE, reason).build())
        } finally { transfer = null }
    }

    override fun onStopped() {
        transfer?.stop()
        // System interruptions keep a hash-bound partial for bounded resumption.
        // An explicit app/notification cancellation clears only this work's files.
        val request = metadata ?: return
        val manager = WorkManager.getInstance(applicationContext)
        val future = manager.getWorkInfoById(id)
        future.addListener({
            runCatching {
                if (future.get()?.state == androidx.work.WorkInfo.State.CANCELLED) {
                    AndroidUpdateTransfer(applicationContext).clearIfBound(request)
                }
            }
        }, Executor { it.run() })
    }

    private fun foreground(progress: Double): ForegroundInfo {
        val manager = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(NotificationChannel(
            CHANNEL, applicationContext.getString(R.string.jms_update_channel), NotificationManager.IMPORTANCE_LOW))
        val notification = NotificationCompat.Builder(applicationContext, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(applicationContext.getString(R.string.jms_update_downloading))
            .setProgress(100, (progress * 100).toInt(), progress <= 0)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(android.R.drawable.ic_delete, applicationContext.getString(R.string.jms_update_cancel),
                WorkManager.getInstance(applicationContext).createCancelPendingIntent(id))
            .build()
        return if (Build.VERSION.SDK_INT >= 29)
            ForegroundInfo(NOTIFICATION, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        else ForegroundInfo(NOTIFICATION, notification)
    }

    companion object {
        const val UNIQUE_WORK = "jms-verified-apk-update"
        const val TAG_PREFIX = "jms-transfer:"
        const val METADATA = "metadata"
        const val BINDING = "binding"
        const val PROGRESS = "progress"
        const val FAILURE = "failure"
        const val MAX_NETWORK_RETRIES = 3
        private const val CHANNEL = "jms-apk-download"
        private const val NOTIFICATION = 60827
    }
}
