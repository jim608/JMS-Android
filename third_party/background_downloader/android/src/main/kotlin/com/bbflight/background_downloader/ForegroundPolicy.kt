package com.bbflight.background_downloader

import kotlinx.coroutines.delay

/** Separates mandatory foreground-service notices from optional notification-drawer posts. */
internal object ForegroundPolicy {
    fun runsInForeground(eligible: Boolean, thresholdMiB: Int, contentLength: Long): Boolean =
        eligible && thresholdMiB >= 0 &&
            (thresholdMiB == 0 || contentLength > (thresholdMiB.toLong() shl 20))

    suspend fun deliverNotification(
        foreground: Boolean,
        running: Boolean,
        active: Boolean,
        canPostNotifications: Boolean,
        startForeground: suspend () -> Unit,
        postNotification: suspend () -> Unit
    ) {
        // POST_NOTIFICATIONS controls drawer visibility, not permission to start an FGS.
        // A running FGS still requires its notification, including when permission is denied.
        if (foreground && running && active) {
            startForeground()
            return
        }
        if (!canPostNotifications) return
        if (foreground) delay(200)
        postNotification()
    }
}
