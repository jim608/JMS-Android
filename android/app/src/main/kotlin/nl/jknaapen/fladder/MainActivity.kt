package nl.jknaapen.fladder

import BatteryOptimizationPigeon
import FlutterError
import LocalNetworkPermissionPigeon
import NativeVideoActivity
import PlayerSettingsPigeon
import StartResult
import TranslationsPigeon
import VideoPlayerApi
import VideoPlayerControlsCallback
import VideoPlayerListenerCallback
import android.annotation.SuppressLint
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.net.Uri
import android.util.Log
import android.provider.Settings
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import nl.jknaapen.fladder.objects.PlayerSettingsObject
import nl.jknaapen.fladder.objects.TranslationsMessenger
import nl.jknaapen.fladder.objects.VideoPlayerObject
import nl.jknaapen.fladder.utility.leanBackEnabled
import nl.jknaapen.fladder.utility.JoystickDirection
import nl.jknaapen.fladder.utility.JoystickDirectionSelector
import androidx.core.net.toUri
import nl.jknaapen.fladder.wallpaper.WallpaperApi
import nl.jknaapen.fladder.wallpaper.WallpaperApiUtility
import java.io.File
import java.util.Objects

class WallpaperFileProvider : FileProvider()

class MainActivity : AudioServiceFragmentActivity(), NativeVideoActivity {
    private val joystickDirections = JoystickDirectionSelector()
    private val joystickHandler = Handler(Looper.getMainLooper())
    private var joystickKey: Int? = null
    private var joystickDeviceId = -1
    private var joystickDownTime = 0L
    private var joystickRepeatCount = 0
    private val repeatJoystickKey = object : Runnable {
        override fun run() {
            if (joystickKey == null) return
            if (!hasWindowFocus() || InputDevice.getDevice(joystickDeviceId) == null) {
                releaseJoystickKey()
                joystickDirections.clear()
                return
            }
            joystickRepeatCount++
            sendJoystickKey(KeyEvent.ACTION_DOWN)
            joystickHandler.postDelayed(this, 120L)
        }
    }

    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean {
        if ((!event.isFromSource(InputDevice.SOURCE_JOYSTICK) &&
                !event.isFromSource(InputDevice.SOURCE_DPAD)) ||
            event.actionMasked != MotionEvent.ACTION_MOVE) {
            return super.dispatchGenericMotionEvent(event)
        }
        val direction = joystickDirections.select(
            event.getAxisValue(MotionEvent.AXIS_X),
            event.getAxisValue(MotionEvent.AXIS_Y),
            event.getAxisValue(MotionEvent.AXIS_HAT_X),
            event.getAxisValue(MotionEvent.AXIS_HAT_Y),
            event.device?.getMotionRange(MotionEvent.AXIS_X, event.source)?.flat ?: 0f,
            event.device?.getMotionRange(MotionEvent.AXIS_Y, event.source)?.flat ?: 0f,
        )
        val nextKey = when (direction) {
            JoystickDirection.UP -> KeyEvent.KEYCODE_DPAD_UP
            JoystickDirection.DOWN -> KeyEvent.KEYCODE_DPAD_DOWN
            JoystickDirection.LEFT -> KeyEvent.KEYCODE_DPAD_LEFT
            JoystickDirection.RIGHT -> KeyEvent.KEYCODE_DPAD_RIGHT
            null -> null
        }
        if (nextKey != joystickKey || event.deviceId != joystickDeviceId) {
            releaseJoystickKey()
            joystickDeviceId = event.deviceId
            joystickKey = nextKey
            if (nextKey != null) {
                joystickDownTime = SystemClock.uptimeMillis()
                joystickRepeatCount = 0
                sendJoystickKey(KeyEvent.ACTION_DOWN)
                joystickHandler.postDelayed(repeatJoystickKey, 350L)
            }
        }
        return true
    }

    private fun sendJoystickKey(action: Int) {
        val key = joystickKey ?: return
        dispatchKeyEvent(KeyEvent(
            joystickDownTime, SystemClock.uptimeMillis(), action, key,
            joystickRepeatCount, 0, joystickDeviceId, 0, 0, InputDevice.SOURCE_DPAD,
        ))
    }

    private fun releaseJoystickKey() {
        joystickHandler.removeCallbacks(repeatJoystickKey)
        sendJoystickKey(KeyEvent.ACTION_UP)
        joystickKey = null
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        if (!hasFocus) {
            releaseJoystickKey()
            joystickDirections.clear()
        }
        super.onWindowFocusChanged(hasFocus)
    }

    override fun onPause() {
        releaseJoystickKey()
        joystickDirections.clear()
        super.onPause()
    }

    private lateinit var videoPlayerLauncher: ActivityResultLauncher<Intent>
    private var videoPlayerCallback: ((Result<StartResult>) -> Unit)? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        SeerrSessionBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        nl.jknaapen.fladder.updates.AndroidUpdateBridge(this, flutterEngine.dartExecutor.binaryMessenger)

        val videoPlayerHost = VideoPlayerObject
        NativeVideoActivity.setUp(
            flutterEngine.dartExecutor.binaryMessenger,
            this
        )
        WallpaperApi.setUp(
            flutterEngine.dartExecutor.binaryMessenger,
            WallpaperApiUtility(this, wallpaperLauncher)
        )
        VideoPlayerApi.setUp(
            flutterEngine.dartExecutor.binaryMessenger,
            videoPlayerHost.implementation
        )
        videoPlayerHost.videoPlayerListener =
            VideoPlayerListenerCallback(flutterEngine.dartExecutor.binaryMessenger)

        videoPlayerHost.videoPlayerControls =
            VideoPlayerControlsCallback(flutterEngine.dartExecutor.binaryMessenger)

        TranslationsMessenger.translation =
            TranslationsPigeon(flutterEngine.dartExecutor.binaryMessenger)

        PlayerSettingsPigeon.setUp(
            flutterEngine.dartExecutor.binaryMessenger,
            api = PlayerSettingsObject
        )

        BatteryOptimizationPigeon.setUp(
            flutterEngine.dartExecutor.binaryMessenger,
            api = object : BatteryOptimizationPigeon {
                override fun isIgnoringBatteryOptimizations(): Boolean {
                    val pm = getSystemService(POWER_SERVICE) as PowerManager
                    return pm.isIgnoringBatteryOptimizations(packageName)
                }

                override fun openBatteryOptimizationSettings() {
                    startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                }
            }
        )

        LocalNetworkPermissionPigeon.setUp(
            flutterEngine.dartExecutor.binaryMessenger,
            api = object : LocalNetworkPermissionPigeon {
                override fun getAndroidSdkInt(): Long = Build.VERSION.SDK_INT.toLong()
            }
        )

        videoPlayerLauncher = registerForActivityResult(
            ActivityResultContracts.StartActivityForResult()
        ) { result ->
            val callback = videoPlayerCallback
            videoPlayerCallback = null

            val startResult = if (result.resultCode == RESULT_OK) {
                StartResult(resultValue = result.data?.getStringExtra("result") ?: "Finished")
            } else {
                StartResult(resultValue = "Cancelled")
            }

            VideoPlayerObject.implementation.player?.stop()
            VideoPlayerObject.implementation.player?.release()
            callback?.invoke(Result.success(startResult))
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Ensure the Activity's intent is updated so Flutter (and plugins / AutoRoute) receive runtime deep-links.
        setIntent(intent)
    }

    private val wallpaperLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        // Handle the result of the wallpaper intent if needed
    }

    override fun launchActivity(callback: (Result<StartResult>) -> Unit) {
        try {
            videoPlayerCallback = callback
            val intent = Intent(this, VideoPlayerActivity::class.java)
            videoPlayerLauncher.launch(intent)
        } catch (e: Exception) {
            e.printStackTrace()
            callback(Result.failure(e))
        }
    }

    override fun disposeActivity() {
        VideoPlayerObject.implementation.player?.stop()
        VideoPlayerObject.implementation.player?.release()
        VideoPlayerObject.currentActivity?.finish()
    }

    override fun isLeanBackEnabled(): Boolean = leanBackEnabled(applicationContext)
}
