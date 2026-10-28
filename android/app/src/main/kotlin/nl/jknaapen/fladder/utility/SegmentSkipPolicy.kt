package nl.jknaapen.fladder.utility

internal data class SegmentSkipRange(val key: String, val start: Long, val end: Long) {
    fun contains(position: Long) = position >= start && position < end
    fun valid(duration: Long) = duration > 0 && start >= 0 && end > start && end <= duration
}

internal enum class SegmentSkipMode { OFF, PROMPT, AUTO }

internal data class SegmentSkipDecision(val range: SegmentSkipRange, val automatic: Boolean)

/** Per-playback state. Every automatic attempt is consumed before seeking. */
internal class SegmentSkipPolicy {
    private var occurrence: Long? = null
    private val attempted = mutableSetOf<String>()
    private val manualReplay = mutableSetOf<String>()
    private val cancelled = mutableSetOf<String>()
    private val priorModes = mutableMapOf<String, SegmentSkipMode>()

    fun beginPlayback(value: Long) {
        if (occurrence == value) return
        occurrence = value
        attempted.clear()
        manualReplay.clear()
        cancelled.clear()
        priorModes.clear()
    }

    fun manualSeek(value: Long, target: Long, ranges: List<SegmentSkipRange>, from: Long? = null) {
        beginPlayback(value)
        ranges.filter {
            it.contains(target) || (from != null && from > target && from >= it.start && target < it.end)
        }.forEach { manualReplay.add(it.key) }
    }

    fun cancel(range: SegmentSkipRange) { cancelled.add(range.key) }
    fun markSkipped(range: SegmentSkipRange) { attempted.add(range.key) }

    fun evaluate(
        value: Long,
        ranges: List<SegmentSkipRange>,
        position: Long,
        duration: Long,
        playing: Boolean,
        canAutoSkip: Boolean = true,
        mode: (SegmentSkipRange) -> SegmentSkipMode,
    ): SegmentSkipDecision? {
        beginPlayback(value)
        val normalized = ranges.filter { it.valid(duration) }.distinctBy { it.key }.sortedBy { it.start }
        // Conflicting overlapping metadata cannot identify one safe skip target.
        val valid = normalized.filter { range ->
            normalized.none { other -> other != range && range.start < other.end && other.start < range.end }
        }
        val active = valid.firstOrNull { it.contains(position) }
        for (range in valid) {
            val current = mode(range)
            val previous = priorModes.put(range.key, current)
            // Enabling automatic mode mid-segment should not surprise a viewer.
            if (range == active && previous != null && previous != current && current == SegmentSkipMode.AUTO) {
                manualReplay.add(range.key)
            }
        }
        active ?: return null
        if (active.key in cancelled || mode(active) == SegmentSkipMode.OFF) return null
        val automatic = mode(active) == SegmentSkipMode.AUTO && playing && canAutoSkip &&
            active.key !in attempted && active.key !in manualReplay
        if (automatic) attempted.add(active.key)
        return SegmentSkipDecision(active, automatic)
    }
}

internal fun chapterTarget(timestamps: List<Long>, position: Long, duration: Long, next: Boolean): Long? {
    if (duration <= 0) return null
    val valid = timestamps.filter { it >= 0 && it < duration }.distinct().sorted()
    return if (next) valid.firstOrNull { it > position } else valid.lastOrNull { it < position }
}
