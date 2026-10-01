package nl.jknaapen.fladder.updates

import java.net.URI
import java.security.MessageDigest

object UpdatePolicy {
    const val MAX_BYTES = 300L * 1024 * 1024
    fun transferBinding(repository: String, address: String, versionName: String, versionCode: Long,
                        minSdk: Int, sourceCommit: String, size: Long, digest: String): String? {
        if (!assetAllowed(address, repository) || versionName.isBlank() || versionCode <= 0 ||
            minSdk < 24 || size !in 1..MAX_BYTES || !Regex("[a-f0-9]{64}").matches(digest) ||
            !Regex("[a-f0-9]{40}").matches(sourceCommit)) return null
        val identity = listOf(repository, address, "com.jim608.jms", "android", "arm64-v8a",
            versionName, versionCode, minSdk, sourceCommit, size, digest).joinToString("\n")
        return MessageDigest.getInstance("SHA-256").digest(identity.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    }
    fun partialBinding(transferKey: String, workId: String): String? =
        if (Regex("[a-f0-9]{64}").matches(transferKey) &&
            Regex("[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}").matches(workId))
            "$transferKey\n$workId" else null
    fun responseStart(status: Int, contentRange: String?, offset: Long, expectedSize: Long): Long? {
        if (expectedSize !in 1..MAX_BYTES || offset !in 0 until expectedSize) return null
        if (status == 200) return 0
        if (status != 206 || offset == 0L) return null
        val match = Regex("bytes (\\d+)-(\\d+)/(\\d+)").matchEntire(contentRange ?: "") ?: return null
        val values = match.groupValues.drop(1).map { it.toLongOrNull() ?: return null }
        return if (values == listOf(offset, expectedSize - 1, expectedSize)) offset else null
    }
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
