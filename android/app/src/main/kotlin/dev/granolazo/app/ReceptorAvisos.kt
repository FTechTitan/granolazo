package dev.granolazo.app

import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Atiende los botones del aviso de reunion y el "Detener" de la grabacion.
 *
 * En Windows el aviso es una ventanita abajo a la derecha; en Android el equivalente
 * discreto es una notificacion con botones. No se usa una ventana flotante a proposito:
 * exige el permiso de "mostrar sobre otras apps", que es de los mas invasivos que hay, y
 * taparle la pantalla a alguien que esta en una llamada es lo contrario de sutil.
 */
class ReceptorAvisos : BroadcastReceiver() {

    override fun onReceive(contexto: Context, intent: Intent) {
        val nm = contexto.getSystemService(NotificationManager::class.java)
        when (intent.action) {
            ServicioVigilante.ACCION_GRABAR -> {
                nm.cancel(ServicioVigilante.ID_NOTIFICACION + 1)
                ServicioVigilante.silenciado = true
                abrirLaApp(contexto, "grabar")
            }

            ServicioVigilante.ACCION_DESCARTAR -> {
                nm.cancel(ServicioVigilante.ID_NOTIFICACION + 1)
                // Se levanta solo cuando termina la llamada: "ahora no" no puede
                // significar "volve a preguntar en ocho segundos".
                ServicioVigilante.silenciado = true
            }

            ServicioVigilante.ACCION_NO_AVISAR -> {
                nm.cancel(ServicioVigilante.ID_NOTIFICACION + 1)
                Preferencias.guardarBool(contexto, Preferencias.DETECTAR, false)
                ServicioVigilante.parar(contexto)
            }

            ServicioGrabacion.ACCION_DETENER -> abrirLaApp(contexto, "detener")
        }
    }

    /**
     * La grabacion la maneja Dart, no el servicio: quien sabe donde va el archivo, con que
     * ganancias mezclar y en que estado queda la ficha es el lado Flutter. Asi que el boton
     * trae la app al frente con la orden puesta, en vez de duplicar esa logica en Kotlin.
     */
    private fun abrirLaApp(contexto: Context, orden: String) {
        if (CanalGranolazo.entregar(orden)) return
        val i = Intent(contexto, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(CanalGranolazo.EXTRA_ORDEN, orden)
        }
        contexto.startActivity(i)
    }
}
