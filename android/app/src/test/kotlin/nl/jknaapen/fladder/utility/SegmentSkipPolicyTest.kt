package nl.jknaapen.fladder.utility

import org.junit.Assert.*
import org.junit.Test

class SegmentSkipPolicyTest {
    private val intro = SegmentSkipRange("intro-10-20", 10, 20)
    private val outro = SegmentSkipRange("outro-80-100", 80, 100)

    private fun SegmentSkipPolicy.tick(
        position: Long = 10, value: Long = 1, ranges: List<SegmentSkipRange> = listOf(intro, outro),
        mode: SegmentSkipMode = SegmentSkipMode.AUTO, canAutoSkip: Boolean = true,
    ) = evaluate(value, ranges, position, 100, true, canAutoSkip) { mode }

    @Test fun automaticIsOnceAndEndExclusive() {
        val policy = SegmentSkipPolicy()
        assertTrue(policy.tick()!!.automatic)
        assertFalse(policy.tick()!!.automatic)
        assertNull(policy.tick(position = 20))
        assertTrue(policy.tick(position = 80)!!.automatic)
        assertNull(policy.tick(position = 100))
    }

    @Test fun rejectsMissingInvalidAndOutOfDurationBounds() {
        val policy = SegmentSkipPolicy()
        assertNull(policy.tick(ranges = emptyList()))
        assertNull(policy.tick(ranges = listOf(SegmentSkipRange("negative", -1, 20))))
        assertNull(policy.tick(ranges = listOf(SegmentSkipRange("reversed", 20, 10))))
        assertNull(policy.tick(ranges = listOf(SegmentSkipRange("zero", 10, 10))))
        assertNull(policy.tick(ranges = listOf(SegmentSkipRange("beyond", 10, 101))))
    }

    @Test fun duplicateMetadataAndEventsCannotRepeatAutomaticSeek() {
        val policy = SegmentSkipPolicy()
        val duplicates = listOf(outro, intro, intro)
        assertTrue(policy.tick(ranges = duplicates)!!.automatic)
        assertFalse(policy.tick(ranges = duplicates)!!.automatic)
        assertNull(SegmentSkipPolicy().tick(ranges = listOf(intro, SegmentSkipRange("conflict", 15, 30))))
    }

    @Test fun manualEntryAndReplayStayPromptOnlyUntilNewPlayback() {
        val policy = SegmentSkipPolicy()
        policy.manualSeek(1, 15, listOf(intro))
        assertFalse(policy.tick(position = 15)!!.automatic)
        assertNull(policy.tick(position = 25))
        assertFalse(policy.tick(position = 11)!!.automatic)
        assertTrue(policy.tick(value = 2)!!.automatic)
    }

    @Test fun rewindingAcrossUnconsumedSegmentAllowsWatchingItAgain() {
        val policy = SegmentSkipPolicy()
        assertNull(policy.tick(position = 25))
        policy.manualSeek(1, 0, listOf(intro), from = 25)
        assertFalse(policy.tick(position = 10)!!.automatic)
        assertFalse(policy.tick(position = 15)!!.automatic)
        assertTrue(policy.tick(value = 2)!!.automatic)
    }

    @Test fun cancellationAndModeChangeDoNotCauseSurpriseSeek() {
        val policy = SegmentSkipPolicy()
        assertFalse(policy.tick(mode = SegmentSkipMode.PROMPT)!!.automatic)
        assertFalse(policy.tick(mode = SegmentSkipMode.AUTO)!!.automatic)
        policy.cancel(intro)
        assertNull(policy.tick())
        assertNull(policy.tick(mode = SegmentSkipMode.OFF))
        assertTrue(policy.tick(value = 2)!!.automatic)
    }

    @Test fun unauthorizedAutomaticBecomesPromptWithoutConsumingAttempt() {
        val policy = SegmentSkipPolicy()
        assertFalse(policy.tick(canAutoSkip = false)!!.automatic)
        assertTrue(policy.tick(canAutoSkip = true)!!.automatic)
    }

    @Test fun chapterTargetsNormalizeAndNeverWrapAtBoundary() {
        val chapters = listOf(30L, 0L, 20L, 20L, -1L, 100L, 101L)
        assertNull(chapterTarget(chapters, 0, 100, false))
        assertEquals(20L, chapterTarget(chapters, 0, 100, true))
        assertEquals(0L, chapterTarget(chapters, 20, 100, false))
        assertEquals(30L, chapterTarget(chapters, 20, 100, true))
        assertNull(chapterTarget(chapters, 30, 100, true))
        assertNull(chapterTarget(emptyList(), 0, 100, true))
        var position = 0L
        repeat(4) { position = chapterTarget(chapters, position, 100, true) ?: position }
        assertEquals(30L, position)
    }
}
