package nl.jknaapen.fladder.messengers

import java.net.URI
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class OfflinePlaybackUriTest {
    @Test
    fun localVideoAndSubtitlePathsRoundTrip() {
        val paths = listOf("/storage/emulated/0/JMS/電影 #3%20?.mkv", "/storage/影片 #1/字幕%20.ass")
        for (path in paths) {
            val uri = URI.create(nativePlaybackUri(path, offline = true))
            assertEquals("file", uri.scheme)
            assertEquals(path, uri.path)
            assertNull(uri.query)
            assertNull(uri.fragment)
        }
    }

    @Test
    fun existingUrisAndOnlineAddressesStayIntact() {
        for (uri in listOf("https://example.invalid/play?name=a%23b", "content://downloads/movie", "file:///dir/%23.mkv")) {
            assertEquals(uri, nativePlaybackUri(uri, offline = true))
            assertEquals(uri, nativePlaybackUri(uri, offline = false))
        }
        val onlinePath = "/existing#behaviour.m3u8"
        assertEquals(onlinePath, nativePlaybackUri(onlinePath, offline = false))
    }
}
