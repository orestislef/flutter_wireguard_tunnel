package gr.orestislef.flutter_wireguard_tunnel

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import com.wireguard.android.backend.BackendException
import com.wireguard.android.backend.GoBackend
import com.wireguard.android.backend.Tunnel
import com.wireguard.config.BadConfigException
import com.wireguard.config.Config
import com.wireguard.config.InetAddresses
import com.wireguard.config.InetEndpoint
import com.wireguard.config.InetNetwork
import com.wireguard.config.Interface
import com.wireguard.config.ParseException
import com.wireguard.config.Peer
import com.wireguard.crypto.Key
import com.wireguard.crypto.KeyFormatException
import com.wireguard.crypto.KeyPair
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.security.KeyStore
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The WireGuard tunnel on Android, on top of the userspace GoBackend.
 *
 * The private key is made here, kept encrypted with a key from the Android
 * Keystore, and never leaves the device. Dart only ever sees the public key.
 */
class FlutterWireguardTunnelPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.ActivityResultListener {

    companion object {
        private const val CHANNEL = "flutter_wireguard_tunnel"
        private const val REQUEST_VPN = 51820
        private const val TAG = "WireGuardTunnel"
        private const val PREFS = "flutter_wireguard_tunnel"
        private const val PREF_KEY = "private_key"
        private const val KEYSTORE = "AndroidKeyStore"
        private const val WRAP_ALIAS = "flutter_wireguard_tunnel_key"
        private const val TUNNEL_NAME = "wireguard"
    }

    private lateinit var appContext: Context
    private var channel: MethodChannel? = null
    private var io: ExecutorService? = null
    private val main = Handler(Looper.getMainLooper())
    private val backend: GoBackend by lazy { GoBackend(appContext) }

    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPrepare: MethodChannel.Result? = null

    @Volatile
    private var state = Tunnel.State.DOWN

    private val tunnel = object : Tunnel {
        override fun getName(): String = TUNNEL_NAME
        override fun onStateChange(newState: Tunnel.State) {
            state = newState
            Log.i(TAG, "state $newState")
        }
    }

    // ---- engine ----

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        io = Executors.newSingleThreadExecutor()
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    /**
     * The Flutter engine is going away (the app was swiped away or closed).
     * The VPN service would otherwise keep the process and the tunnel alive
     * with nothing behind it: a key icon in the status bar, and keepalives
     * that make the server think the device is still there.
     */
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        pendingPrepare = null
        val io = io ?: return
        this.io = null
        if (state != Tunnel.State.DOWN) {
            io.execute {
                try {
                    down()
                    Log.i(TAG, "down: the app closed")
                } catch (e: Throwable) {
                    Log.w(TAG, "down on close failed: $e")
                }
            }
        }
        io.shutdown()
    }

    // ---- activity, for the VPN prompt ----

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_VPN) return false
        val result = pendingPrepare ?: return true
        pendingPrepare = null
        result.success(resultCode == Activity.RESULT_OK)
        return true
    }

    // ---- calls ----

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "publicKey" -> background(result) { keyPair().publicKey.toBase64() }
            "isPrepared" -> result.success(VpnService.prepare(appContext) == null)
            "prepare" -> prepare(result)
            "up" -> background(result) { up(call); true }
            "down" -> background(result) { down(); true }
            "state" -> result.success(if (state == Tunnel.State.UP) "up" else "down")
            else -> result.notImplemented()
        }
    }

    /** Android's own "Connection request" dialog, once per install. */
    private fun prepare(result: MethodChannel.Result) {
        if (VpnService.prepare(appContext) == null) {
            result.success(true)
            return
        }
        val activity = activityBinding?.activity
        if (activity == null) {
            result.error("no_activity", "The VPN prompt needs an activity", null)
            return
        }
        val intent = VpnService.prepare(activity)
        if (intent == null) {
            result.success(true)
            return
        }
        if (pendingPrepare != null) {
            result.error("busy", "The VPN prompt is already open", null)
            return
        }
        pendingPrepare = result
        try {
            activity.startActivityForResult(intent, REQUEST_VPN)
        } catch (e: Exception) {
            pendingPrepare = null
            result.error("failed", e.message ?: e.javaClass.simpleName, null)
        }
    }

    private fun up(call: MethodCall) {
        val addresses = call.argument<List<String>>("address").orEmpty()
        if (addresses.isEmpty()) throw IllegalArgumentException("address is empty")
        val serverKey = call.argument<String>("serverPublicKey")
            ?: throw IllegalArgumentException("serverPublicKey is missing")
        val endpoint = call.argument<String>("endpoint")
            ?: throw IllegalArgumentException("endpoint is missing")
        val allowed = call.argument<List<String>>("allowedIps").orEmpty()
        if (allowed.isEmpty()) throw IllegalArgumentException("allowedIps is empty")
        val dns = call.argument<List<String>>("dns").orEmpty()
        val privateKey = call.argument<String>("privateKey")
        val presharedKey = call.argument<String>("presharedKey")
        val keepalive = call.argument<Int>("keepalive") ?: 25
        val mtu = call.argument<Int>("mtu") ?: 1280

        val keys = if (privateKey != null) KeyPair(Key.fromBase64(privateKey)) else keyPair()
        val iface = Interface.Builder().setKeyPair(keys).setMtu(mtu)
        for (address in addresses) iface.addAddress(InetNetwork.parse(address))
        for (server in dns) iface.addDnsServer(InetAddresses.parse(server))

        val peer = Peer.Builder()
            .setPublicKey(Key.fromBase64(serverKey))
            .setEndpoint(InetEndpoint.parse(endpoint))
            .setPersistentKeepalive(keepalive)
        if (presharedKey != null) peer.setPreSharedKey(Key.fromBase64(presharedKey))
        for (ip in allowed) peer.addAllowedIp(InetNetwork.parse(ip))

        val config = Config.Builder().setInterface(iface.build()).addPeer(peer.build()).build()
        // A running tunnel takes the new config in place.
        state = backend.setState(tunnel, Tunnel.State.UP, config)
        Log.i(TAG, "up $addresses via $endpoint allowed=$allowed")
    }

    private fun down() {
        if (state == Tunnel.State.DOWN) return
        state = backend.setState(tunnel, Tunnel.State.DOWN, null)
    }

    private fun <T> background(result: MethodChannel.Result, block: () -> T) {
        val io = io
        if (io == null) {
            result.error("failed", "The plugin is detached", null)
            return
        }
        io.execute {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (e: Throwable) {
                Log.w(TAG, "failed: $e")
                main.post { result.error(codeFor(e), messageFor(e), null) }
            }
        }
    }

    private fun codeFor(e: Throwable): String = when (e) {
        is BackendException ->
            if (e.reason == BackendException.Reason.VPN_NOT_AUTHORIZED) "not_prepared" else "failed"
        is IllegalArgumentException,
        is BadConfigException,
        is ParseException,
        is KeyFormatException -> "bad_config"
        else -> "failed"
    }

    private fun messageFor(e: Throwable): String = when (e) {
        is BackendException -> when (e.reason) {
            BackendException.Reason.VPN_NOT_AUTHORIZED -> "VPN permission not given, call prepare() first"
            BackendException.Reason.DNS_RESOLUTION_FAILURE -> "Could not resolve the endpoint"
            BackendException.Reason.UNABLE_TO_START_VPN -> "Android did not start the VPN service"
            BackendException.Reason.TUN_CREATION_ERROR -> "Android did not create the tunnel interface"
            else -> "WireGuard failed: ${e.reason}"
        }
        else -> e.message ?: e.javaClass.simpleName
    }

    // ---- key, made once and kept encrypted ----

    @Synchronized
    private fun keyPair(): KeyPair {
        val prefs = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val stored = prefs.getString(PREF_KEY, null)
        if (stored != null) {
            try {
                return KeyPair(Key.fromBase64(decrypt(stored)))
            } catch (e: Exception) {
                // The Keystore key is gone (backup restored on a new phone):
                // a new key pair, the server needs the new public key.
                Log.w(TAG, "stored key unreadable, making a new one: $e")
            }
        }
        val pair = KeyPair()
        prefs.edit().putString(PREF_KEY, encrypt(pair.privateKey.toBase64())).apply()
        return pair
    }

    private fun wrapKey(): SecretKey {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (store.getKey(WRAP_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                WRAP_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build()
        )
        return generator.generateKey()
    }

    private fun encrypt(plain: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, wrapKey())
        val sealed = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" +
            Base64.encodeToString(sealed, Base64.NO_WRAP)
    }

    private fun decrypt(stored: String): String {
        val parts = stored.split(":")
        if (parts.size != 2) throw IllegalStateException("bad stored key")
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            wrapKey(),
            GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP))
        )
        return String(cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)), Charsets.UTF_8)
    }
}
