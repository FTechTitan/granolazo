package dev.granolazo.app

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/**
 * El punto por donde Kotlin y Dart se hablan, y la poca memoria compartida que hace falta.
 *
 * Existe como objeto suelto y no dentro de `MainActivity` porque los servicios y los
 * receptores viven mas que la pantalla: el vigilante sigue corriendo con la app cerrada y
 * necesita saber si se esta grabando, y el boton "Grabar" de una notificacion tiene que
 * poder llegar a Dart aunque en ese momento no haya ninguna actividad visible.
 */
object CanalGranolazo {
    const val CANAL = "granolazo/android"
    const val EXTRA_ORDEN = "granolazo_orden"

    /** La lee [ServicioVigilante] para no ofrecer grabar cuando ya se esta grabando. */
    @Volatile var grabando = false

    /** Lo pone [MainActivity] mientras esta viva; vuelve a null al destruirse. */
    @Volatile var canal: MethodChannel? = null

    /**
     * Manda una orden a Dart. Devuelve `false` si no habia nadie escuchando, y entonces
     * quien llama abre la app pasandola como extra del intent.
     */
    fun entregar(orden: String): Boolean {
        val c = canal ?: return false
        Handler(Looper.getMainLooper()).post {
            try {
                c.invokeMethod("orden", orden)
            } catch (_: Throwable) {
                // Si el motor se fue entre el chequeo y el envio, se pierde la orden. El
                // camino de respaldo -abrir la app con el extra puesto- ya cubre eso.
            }
        }
        return true
    }

    /** Avisa a Dart como salio la captura del audio del sistema, que se resuelve tarde. */
    fun avisarCaptura(error: String?) {
        val c = canal ?: return
        Handler(Looper.getMainLooper()).post {
            try {
                c.invokeMethod("captura", error)
            } catch (_: Throwable) {
            }
        }
    }
}
