package nl.jknaapen.fladder.messengers

import java.net.URI

internal fun nativePlaybackUri(address: String, offline: Boolean): String =
    if (offline && address.startsWith('/')) {
        // Media3 reads the decoded URI path, so escape literal query and fragment characters.
        URI("file", "", address, null).toASCIIString()
    } else {
        address
    }
