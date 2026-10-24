package nl.jknaapen.fladder.utility

import kotlin.math.abs
import kotlin.math.max

enum class JoystickDirection { UP, DOWN, LEFT, RIGHT }

/** Turns left-stick/hat motion into one stable focus direction, never a cursor. */
class JoystickDirectionSelector {
    private var previous: JoystickDirection? = null

    fun clear() {
        previous = null
    }

    fun select(
        x: Float,
        y: Float,
        hatX: Float = 0f,
        hatY: Float = 0f,
        flatX: Float = 0f,
        flatY: Float = 0f,
    ): JoystickDirection? {
        // The physical D-pad has priority when both inputs are held.
        val hatActive = abs(hatX) > 0.5f || abs(hatY) > 0.5f
        val rawHorizontal = if (hatActive) hatX else x
        val rawVertical = if (hatActive) hatY else y
        val heldHorizontal = previous == JoystickDirection.LEFT || previous == JoystickDirection.RIGHT
        val heldVertical = previous == JoystickDirection.UP || previous == JoystickDirection.DOWN
        val thresholdX = if (hatActive) 0.5f else max(flatX, if (heldHorizontal) 0.20f else 0.35f)
        val thresholdY = if (hatActive) 0.5f else max(flatY, if (heldVertical) 0.20f else 0.35f)
        val horizontal = if (abs(rawHorizontal) > thresholdX) rawHorizontal else 0f
        val vertical = if (abs(rawVertical) > thresholdY) rawVertical else 0f
        val next = when {
            abs(horizontal) <= thresholdX && abs(vertical) <= thresholdY -> null
            // A small diagonal wobble should not swap direction mid-scroll.
            previous == JoystickDirection.LEFT && horizontal < -thresholdX &&
                abs(vertical) < abs(horizontal) + 0.15f -> previous
            previous == JoystickDirection.RIGHT && horizontal > thresholdX &&
                abs(vertical) < abs(horizontal) + 0.15f -> previous
            previous == JoystickDirection.UP && vertical < -thresholdY &&
                abs(horizontal) < abs(vertical) + 0.15f -> previous
            previous == JoystickDirection.DOWN && vertical > thresholdY &&
                abs(horizontal) < abs(vertical) + 0.15f -> previous
            abs(horizontal) > abs(vertical) ->
                if (horizontal < 0) JoystickDirection.LEFT else JoystickDirection.RIGHT
            else -> if (vertical < 0) JoystickDirection.UP else JoystickDirection.DOWN
        }
        previous = next
        return next
    }
}
