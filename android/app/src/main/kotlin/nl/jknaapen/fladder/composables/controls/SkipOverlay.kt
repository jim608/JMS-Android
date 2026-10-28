package nl.jknaapen.fladder.composables.controls

import MediaSegment
import MediaSegmentType
import SegmentSkip
import SegmentType
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeContentPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import nl.jknaapen.fladder.R
import nl.jknaapen.fladder.objects.Localized
import nl.jknaapen.fladder.objects.PlayerSettingsObject
import nl.jknaapen.fladder.objects.Translate
import nl.jknaapen.fladder.objects.VideoPlayerObject
import nl.jknaapen.fladder.utility.SegmentSkipDecision
import nl.jknaapen.fladder.utility.SegmentSkipMode
import nl.jknaapen.fladder.utility.SegmentSkipRange

@kotlin.OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun BoxScope.SegmentSkipOverlay(modifier: Modifier = Modifier, onFocused: (Boolean) -> Unit = {}) {
    val implementation = VideoPlayerObject.implementation
    val state by implementation.playbackData.collectAsState()
    val occurrence by implementation.playbackOccurrence.collectAsState()
    val position by VideoPlayerObject.position.collectAsState(0L)
    val duration by VideoPlayerObject.duration.collectAsState(0L)
    val playing by VideoPlayerObject.playing.collectAsState(false)
    val buffering by VideoPlayerObject.buffering.collectAsState(true)
    val skipMap by PlayerSettingsObject.skipMap.collectAsState(mapOf())
    val player = implementation.player
    val policy = implementation.segmentSkipPolicy
    val segments = state?.segments.orEmpty()
    val ranges = segments.map { it.skipRange }
    val currentRanges by rememberUpdatedState(ranges)
    var decision by remember(occurrence) { mutableStateOf<SegmentSkipDecision?>(null) }

    // Explicit seek discontinuities include jumps normal position ticks miss.
    DisposableEffect(player) {
        val listener = object : Player.Listener {
            override fun onPositionDiscontinuity(
                oldPosition: Player.PositionInfo, newPosition: Player.PositionInfo, reason: Int,
            ) {
                if (reason == Player.DISCONTINUITY_REASON_SEEK) {
                    policy.manualSeek(
                        implementation.playbackOccurrence.value, newPosition.positionMs, currentRanges, oldPosition.positionMs,
                    )
                    decision = null
                }
            }

            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                if (reason == Player.MEDIA_ITEM_TRANSITION_REASON_REPEAT) implementation.beginPlaybackOccurrence()
            }
        }
        player?.addListener(listener)
        onDispose { player?.removeListener(listener) }
    }

    LaunchedEffect(occurrence, segments, position, duration, playing, buffering, skipMap, player) {
        if (player == null) {
            decision = null
            return@LaunchedEffect
        }
        val next = policy.evaluate(occurrence, ranges, position, duration, playing && !buffering) { range ->
            val segment = segments.first { it.skipRange.key == range.key }
            when (skipMap[segment.type.toSegment] ?: SegmentSkip.ASK) {
                SegmentSkip.NONE -> SegmentSkipMode.OFF
                SegmentSkip.ASK -> SegmentSkipMode.PROMPT
                SegmentSkip.SKIP, SegmentSkip.SKIP_ONCE -> SegmentSkipMode.AUTO
            }
        }
        decision = next
        if (next?.automatic == true) player.seekTo(next.range.end)
    }

    val current = decision ?: return
    val segment = segments.firstOrNull { it.skipRange.key == current.range.key } ?: return
    if (current.automatic) return
    DisposableEffect(current.range.key) {
        onDispose { onFocused(false) }
    }
    val dismissLabel = stringResource(R.string.jms_dismiss_skip)
    val fallbackLabel = when (segment.type) {
        MediaSegmentType.INTRO -> stringResource(R.string.jms_skip_opening)
        MediaSegmentType.OUTRO -> stringResource(R.string.jms_skip_ending)
        else -> "Skip ${segment.name}"
    }
    // Prompt lifetime is independent of the controls' touch/auto-hide timer.
    // Focus remains where the user left it; D-pad navigation can reach either action.
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.align(Alignment.CenterEnd).padding(16.dp).safeContentPadding()
            .onFocusChanged { onFocused(it.hasFocus) }.focusGroup(),
    ) {
        Translate({ callback -> Localized.skip(segment.name.lowercase(), callback) }, key = segment.type) { label ->
            val buttonLabel = label.ifBlank { fallbackLabel }
            CustomButton(
                modifier = modifier.semantics { contentDescription = buttonLabel },
                backgroundColor = Color.Black.copy(alpha = 0.65f),
                shape = RoundedCornerShape(8.dp),
                enableScaledFocus = true,
                onClick = {
                    if (current.range.valid(player?.duration ?: 0) && current.range.contains(player?.currentPosition ?: -1)) {
                        policy.markSkipped(current.range)
                        decision = null
                        player?.seekTo(current.range.end)
                    }
                },
            ) {
                Text(buttonLabel, style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold))
            }
        }
        CustomButton(
            modifier = Modifier.semantics { contentDescription = dismissLabel },
            backgroundColor = Color.Black.copy(alpha = 0.65f),
            enableScaledFocus = true,
            onClick = {
                policy.cancel(current.range)
                decision = null
            },
        ) { Text("×", style = MaterialTheme.typography.titleLarge) }
    }
}

private val MediaSegment.skipRange: SegmentSkipRange
    get() = SegmentSkipRange("$type-$start-$end", start, end)

private val MediaSegmentType.toSegment: SegmentType
    get() = when (this) {
        MediaSegmentType.COMMERCIAL -> SegmentType.COMMERCIAL
        MediaSegmentType.PREVIEW -> SegmentType.PREVIEW
        MediaSegmentType.RECAP -> SegmentType.RECAP
        MediaSegmentType.INTRO -> SegmentType.INTRO
        MediaSegmentType.OUTRO -> SegmentType.OUTRO
    }
