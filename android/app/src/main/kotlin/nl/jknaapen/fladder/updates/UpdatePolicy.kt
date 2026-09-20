package nl.jknaapen.fladder.updates

import java.net.URI

object UpdatePolicy {
    const val MAX_BYTES = 300L * 1024 * 1024
    fun assetAllowed(address: String, repository: String): Boolean = runCatching {
        val uri = URI(address)
        val parts = repository.split("/")
        val path = uri.path.split("/")
        parts.size == 2 && Regex("[A-Za-z0-9][A-Za-z0-9-]{0,38}").matches(parts[0]) &&
            Regex("[A-Za-z0-9][A-Za-z0-9_.-]{0,99}").matches(parts[1]) &&
            repository.lowercase() != "donutware/fladder" && uri.scheme == "https" &&
            uri.host == "github.com" && uri.port in listOf(-1, 443) &&
            uri.userInfo == null && uri.query == null && uri.fragment == null &&
            path.size == 7 && path[1] == parts[0] && path[2] == parts[1] &&
            path[3] == "releases" && path[4] == "download"
    }.getOrDefault(false)
    fun redirectAllowed(address: String): Boolean = runCatching {
        val uri = URI(address)
        uri.scheme == "https" && uri.port in listOf(-1, 443) && uri.userInfo == null &&
            uri.host in setOf("release-assets.githubusercontent.com", "objects.githubusercontent.com")
    }.getOrDefault(false)
    fun matchingSigners(installed: Set<String>, candidate: Set<String>): Boolean =
        installed.isNotEmpty() && installed == candidate
    fun compatible(packageId: String, installedId: String, code: Long, installedCode: Long,
                   expectedCode: Long, name: String?, expectedName: String, sdk: Int,
                   expectedSdk: Int, deviceSdk: Int, abis: Set<String>, deviceAbis: Set<String>): Boolean =
        packageId == installedId && packageId == "com.jim608.jms" && code > installedCode &&
            code == expectedCode && name == expectedName && sdk == expectedSdk && sdk <= deviceSdk &&
            sdk >= 24 && abis == setOf("arm64-v8a") && deviceAbis.contains("arm64-v8a")
    fun matchingContent(size: Long, expectedSize: Long, digest: String, expectedDigest: String): Boolean =
        expectedSize in 1..MAX_BYTES && size == expectedSize &&
            Regex("[a-f0-9]{64}").matches(expectedDigest) && digest == expectedDigest
}
