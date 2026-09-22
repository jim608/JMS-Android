package nl.jknaapen.fladder

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class SeerrSessionBridge(context: Context, messenger: BinaryMessenger) {
    private val directory = File(context.noBackupFilesDir, "seerr-sessions")
    private val alias = "jms-seerr-session-v1"

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }

    init {
        MethodChannel(messenger, "com.jim608.jms/seerr-session").setMethodCallHandler { call, result ->
            try {
                val scope = call.argument<String>("key") ?: error("Missing scope")
                require(Regex("[a-f0-9]{64}").matches(scope))
                val file = File(directory, scope)
                when (call.method) {
                    "read" -> {
                        if (!file.exists()) {
                            result.success(null)
                        } else {
                            require(file.length() < 32768)
                            val parts = AtomicFile(file).readFully().toString(Charsets.UTF_8).split(':')
                            require(parts.size == 2)
                            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)))
                            cipher.updateAAD(scope.toByteArray())
                            result.success(cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)).toString(Charsets.UTF_8))
                        }
                    }
                    "write" -> {
                        val value = call.argument<String>("value")
                        if (value.isNullOrEmpty()) {
                            AtomicFile(file).delete()
                        } else {
                            require(value.length <= 8192)
                            directory.mkdirs()
                            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                            cipher.init(Cipher.ENCRYPT_MODE, key())
                            cipher.updateAAD(scope.toByteArray())
                            val encrypted = cipher.doFinal(value.toByteArray())
                            val payload = Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" + Base64.encodeToString(encrypted, Base64.NO_WRAP)
                            val atomic = AtomicFile(file)
                            val output = atomic.startWrite()
                            try {
                                output.write(payload.toByteArray())
                                atomic.finishWrite(output)
                            } catch (failure: Exception) {
                                atomic.failWrite(output)
                                throw failure
                            }
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (failure: Exception) {
                result.error("secure_storage_unavailable", "Seerr session storage unavailable", null)
            }
        }
    }
}
