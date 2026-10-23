package bo.handimanya.handimanya

import android.os.Build
import android.os.Bundle
import android.view.animation.DecelerateInterpolator
import io.flutter.embedding.android.FlutterFragmentActivity

// FragmentActivity: la huella y el rostro del teléfono (local_auth) lo necesitan.
class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
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

    private companion object {
        // Alto del logo en SplashPage / alto en el ícono de arranque (tool/make_splash.py).
        const val LOGO_GROWTH = 46f / 36f
        const val GROW_MS = 200L
    }
}
