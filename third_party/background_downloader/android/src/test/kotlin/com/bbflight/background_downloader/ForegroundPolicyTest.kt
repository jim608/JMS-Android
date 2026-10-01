package com.bbflight.background_downloader

import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

class ForegroundPolicyTest {
    @Test fun alwaysModeDoesNotRequireAContentLengthOrFirstByte() {
        for (length in listOf(-1L, 0L, 1L, 20L shl 20)) {
            assertTrue(ForegroundPolicy.runsInForeground(true, 0, length))
        }
        assertFalse(ForegroundPolicy.runsInForeground(false, 0, -1))
        assertFalse(ForegroundPolicy.runsInForeground(true, -1, 20L shl 20))
    }

    @Test fun explicitSizeThresholdKeepsItsOriginalMeaning() {
        assertFalse(ForegroundPolicy.runsInForeground(true, 10, -1))
        assertFalse(ForegroundPolicy.runsInForeground(true, 10, 10L shl 20))
        assertTrue(ForegroundPolicy.runsInForeground(true, 10, (10L shl 20) + 1))
    }

    @Test fun deniedDrawerPermissionStillStartsTheRunningForegroundService() = runTest {
        val calls = mutableListOf<String>()
        ForegroundPolicy.deliverNotification(true, true, true, false,
            { calls.add("foreground") }, { calls.add("drawer") })
        assertEquals(listOf("foreground"), calls)
    }

    @Test fun grantedPermissionDoesNotCreateADuplicateOrdinaryNotice() = runTest {
        val calls = mutableListOf<String>()
        ForegroundPolicy.deliverNotification(true, true, true, true,
            { calls.add("foreground") }, { calls.add("drawer") })
        assertEquals(listOf("foreground"), calls)
    }

    @Test fun denialStillBlocksOptionalCompletePausedAndOrdinaryNotices() = runTest {
        for ((foreground, running, active) in listOf(
            Triple(false, true, true), Triple(true, false, true), Triple(true, true, false))) {
            var calls = 0
            ForegroundPolicy.deliverNotification(foreground, running, active, false,
                { calls++ }, { calls++ })
            assertEquals(0, calls)
        }
    }

    @Test fun optionalCompletionNoticeRetainsTheForegroundShutdownDelay() = runTest {
        var notices = 0
        val start = testScheduler.currentTime
        ForegroundPolicy.deliverNotification(true, false, true, true,
            { fail("Completed work must not start a foreground service") }, { notices++ })
        assertEquals(1, notices)
        assertEquals(200L, testScheduler.currentTime - start)
    }

    @Test fun serviceStartErrorsPropagateInsteadOfPretendingForegroundIsActive() = runTest {
        var posted = false
        try {
            ForegroundPolicy.deliverNotification(true, true, true, false,
                { throw IllegalStateException("fixture-service-error") }, { posted = true })
            fail("A service failure must reach the worker")
        } catch (_: IllegalStateException) {
            assertFalse(posted)
        }
    }
}
