package dev.granolazo.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Arranca el vigilante cuando se enciende el telefono.
 *
 * Es el equivalente de la clave `Run` del registro en Windows, y comparte su mejor
 * propiedad: **es visible y reversible sin pasar por la app**. En Android se apaga desde
 * los ajustes del sistema, quitandole a Granolazo el permiso de inicio automatico o
 * silenciando su notificacion permanente.
 *
 * Lo que arranca es el vigilante, no la app: abrir una pantalla sola cada vez que se
 * enciende el telefono seria motivo suficiente para desinstalarla.
 *
 * `QUICKBOOT_POWERON` y `HTC_QUICKBOOT` no son adorno: varios fabricantes -entre ellos
 * Samsung, que es el telefono del autor- usan un arranque rapido que no siempre emite
 * el `BOOT_COMPLETED` estandar.
 */
class ReceptorArranque : BroadcastReceiver() {

    override fun onReceive(contexto: Context, intent: Intent) {
        val accion = intent.action ?: return
        val esArranque = accion == Intent.ACTION_BOOT_COMPLETED ||
            accion == "android.intent.action.QUICKBOOT_POWERON" ||
            accion == "com.htc.intent.action.QUICKBOOT_POWERON" ||
            accion == Intent.ACTION_MY_PACKAGE_REPLACED
        if (!esArranque) return

        if (!Preferencias.leerBool(contexto, Preferencias.ARRANCAR, false)) return
        if (!Preferencias.leerBool(contexto, Preferencias.DETECTAR, true)) return

        ServicioVigilante.arrancar(contexto)
    }
}
