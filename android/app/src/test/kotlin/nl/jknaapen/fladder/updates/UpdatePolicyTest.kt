package nl.jknaapen.fladder.updates

import org.junit.Assert.*
import org.junit.Test

class UpdatePolicyTest {
    private val digest = "a".repeat(64)
    @Test fun onlyOfficialHttpsAssets() {
        assertTrue(UpdatePolicy.assetAllowed("https://github.com/test/jms/releases/download/v6/JMS.apk", "test/jms"))
        for (url in listOf("http://github.com/test/jms/releases/download/v6/JMS.apk",
            "https://evil.test/test/jms/releases/download/v6/JMS.apk",
            "https://github.com/other/jms/releases/download/v6/JMS.apk"))
            assertFalse(UpdatePolicy.assetAllowed(url, "test/jms"))
        assertFalse(UpdatePolicy.assetAllowed("https://github.com/DonutWare/Fladder/releases/download/v6/Fladder.apk", "DonutWare/Fladder"))
        assertTrue(UpdatePolicy.redirectAllowed("https://release-assets.githubusercontent.com/path?signature=fixture"))
        assertFalse(UpdatePolicy.redirectAllowed("http://release-assets.githubusercontent.com/path"))
        assertFalse(UpdatePolicy.redirectAllowed("https://release-assets.githubusercontent.com.evil.test/path"))
    }
    @Test fun signerMustMatchInstalledNotRemoteJson() {
        assertTrue(UpdatePolicy.matchingSigners(setOf("local"), setOf("local")))
        assertFalse(UpdatePolicy.matchingSigners(setOf("local"), setOf("remote")))
        assertFalse(UpdatePolicy.matchingSigners(emptySet(), emptySet()))
    }
    @Test fun hashAndSizeBothRequired() {
        assertTrue(UpdatePolicy.matchingContent(10, 10, digest, digest))
        assertFalse(UpdatePolicy.matchingContent(10, 10, "b".repeat(64), digest))
        assertFalse(UpdatePolicy.matchingContent(9, 10, digest, digest))
        assertFalse(UpdatePolicy.matchingContent(0, 0, digest, digest))
        assertFalse(UpdatePolicy.matchingContent(UpdatePolicy.MAX_BYTES + 1, UpdatePolicy.MAX_BYTES + 1, digest, digest))
    }
    @Test fun actualArchiveMustMatchMetadataAndDevice() {
        fun valid(packageId: String = "com.jim608.jms", code: Long = 2006, name: String = "v6",
                  sdk: Int = 24, abis: Set<String> = setOf("arm64-v8a")) =
            UpdatePolicy.compatible(packageId, "com.jim608.jms", code, 2005, 2006, name, "v6", sdk, 24, 35,
                abis, setOf("arm64-v8a"))
        assertTrue(valid())
        assertFalse(valid(packageId = "com.other"))
        assertFalse(valid(code = 2005))
        assertFalse(valid(code = 2004))
        assertFalse(valid(code = 2007))
        assertFalse(valid(name = "other"))
        assertFalse(valid(sdk = 36))
        assertFalse(valid(abis = setOf("x86_64")))
    }
}
