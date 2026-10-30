package bo.handimanya.handimanya

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.animation.DecelerateInterpolator
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FragmentActivity: la huella y el rostro del teléfono (local_auth) lo necesitan.
class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannel()
        // Android 12+: su pantalla de arranque muestra el logo a 36 dp de alto
        // (lo más que entra en su círculo). Cuando Flutter ya dibujó SplashPage
        // debajo, el logo crece hasta los 46 dp de SplashPage y la pantalla del
        // sistema se quita: el logo queda en el mismo lugar y del mismo tamaño.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            splashScreen.setOnExitAnimationListener { view ->
                val icon = view.iconView
                if (icon == null) {
                    view.remove()
                    return@setOnExitAnimationListener
                }
                icon.animate()
                    .scaleX(LOGO_GROWTH)
                    .scaleY(LOGO_GROWTH)
                    .setDuration(GROW_MS)
                    .setInterpolator(DecelerateInterpolator())
                    .withEndAction { view.remove() }
                    .start()
            }
        }
    }

    // Android 8+: sin un canal, en Ajustes → Notificaciones el interruptor de la
    // app puede quedar gris hasta el primer aviso. El canal existe desde que se
    // abre la app, y Firebase lo usa para los avisos push (AndroidManifest.xml).
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(CHANNEL_ID, "Avisos de HandiMan ¡Ya!", NotificationManager.IMPORTANCE_HIGH)
        channel.description = "Pedidos nuevos, mensajes y cambios de tus solicitudes"
        getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bo.handimanya/notifications")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Los ajustes de avisos de esta app (en Android viejo, los de la app).
                    "openSettings" -> {
                        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                        } else {
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null))
                        }
                        startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private companion object {
        // También en AndroidManifest.xml (default_notification_channel_id).
        const val CHANNEL_ID = "avisos"

        // Alto del logo en SplashPage / alto en el ícono de arranque (tool/make_splash.py).
        const val LOGO_GROWTH = 46f / 36f
        const val GROW_MS = 200L
    }
}
