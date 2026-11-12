package dev.granolazo.app

import android.content.Context

/**
 * Los dos ajustes que el lado nativo necesita leer **sin Flutter vivo**.
 *
 * El resto de las preferencias vive donde siempre, del lado Dart. Estas dos no pueden:
 * quien decide si arrancar el vigilante al encender el telefono es un `BroadcastReceiver`
 * que corre antes de que exista un motor de Flutter, y no puede esperar a preguntarle.
 *
 * Se guardan en un archivo propio y no en el de `shared_preferences` a proposito: ese
 * formato es un detalle interno del plugin -prefijos, tipos envueltos, y una migracion a
 * DataStore en curso- y escribirlo a mano desde Kotlin es atarse a algo que puede cambiar
 * en cualquier actualizacion. Dart llega a estos valores por el canal, que es un contrato
 * explicito.
 */
object Preferencias {
    private const val ARCHIVO = "granolazo_nativo"

    const val DETECTAR = "detectar_reuniones"
    const val ARRANCAR = "arrancar_con_el_sistema"

    fun leerBool(contexto: Context, clave: String, porDefecto: Boolean): Boolean =
        contexto.getSharedPreferences(ARCHIVO, Context.MODE_PRIVATE)
            .getBoolean(clave, porDefecto)

    fun guardarBool(contexto: Context, clave: String, valor: Boolean) {
        contexto.getSharedPreferences(ARCHIVO, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(clave, valor)
            .apply()
    }
}
