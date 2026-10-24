package nl.jknaapen.fladder.utility

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class JoystickDirectionSelectorTest {
    @Test
    fun ignoresDriftAndUsesHysteresisUntilNeutral() {
        val selector = JoystickDirectionSelector()
        assertNull(selector.select(0.20f, -0.10f))
        assertEquals(JoystickDirection.RIGHT, selector.select(0.7f, 0f))
        assertEquals(JoystickDirection.RIGHT, selector.select(0.25f, 0f))
        assertNull(selector.select(0.1f, 0.1f))
        assertNull(selector.select(0.25f, 0f))
    }

    @Test
    fun dominantAxisIsStableAndPhysicalDpadTakesPriority() {
        val selector = JoystickDirectionSelector()
        assertEquals(JoystickDirection.DOWN, selector.select(0.2f, 0.8f))
        assertEquals(JoystickDirection.DOWN, selector.select(0.85f, 0.8f))
        assertEquals(JoystickDirection.RIGHT, selector.select(1f, 0.6f))
        assertEquals(JoystickDirection.UP, selector.select(1f, 0f, 0f, -1f))
        assertEquals(JoystickDirection.LEFT, selector.select(0f, 0f, -1f, 0f))
    }

    @Test
    fun respectsDeviceDeadzoneAndResetsOnFocusLoss() {
        val selector = JoystickDirectionSelector()
        assertNull(selector.select(0.4f, 0f, flatX = 0.5f))
        assertEquals(JoystickDirection.UP, selector.select(0f, -0.8f))
        selector.clear()
        assertNull(selector.select(0f, -0.25f))
    }

    @Test
    fun ignoresAnAxisInsideItsDeviceDeadzoneWhenChoosingTheDominantAxis() {
        val selector = JoystickDirectionSelector()
        assertEquals(JoystickDirection.DOWN,
            selector.select(0.4f, 0.36f, flatX = 0.5f))
        selector.clear()
        assertEquals(JoystickDirection.LEFT,
            selector.select(-0.36f, 0.4f, flatY = 0.5f))
    }
}
