package dev.granolazo.app

import android.content.Context
import java.io.File
import java.security.SecureRandom

/**
 * La llave que protege el modo consola de Android.
 *
 * **Por que hace falta.** En Windows la consola la protege el sistema operativo: para
 * correr el ejecutable hay que ser el usuario. En Android un `BroadcastReceiver` exportado
 * lo puede invocar cualquier app instalada, y la consola de Granolazo sabe empezar a
 * grabar. Sin llave, cualquier app del telefono podria encender el microfono en silencio;
 * eso no es una consola, es un microfono ambiental para terceros.
 *
 * Comprobar el UID de quien llama no sirve: en un broadcast, `Binder.getCallingUid()`
 * dentro de `onReceive` devuelve el UID propio, porque la entrega es asincrona. Y una
 * permission con `protectionLevel="signature"` tampoco, porque dejaria afuera a `adb`,
 * que es justamente quien tiene que poder usarla.
 *
 * La llave se genera sola la primera vez y se lee con:
 *
 *     adb shell run-as dev.granolazo.app cat files/cli-token
 *
 * y tambien se muestra en los ajustes de la app, para cuando el APK no sea depurable.
 */
object TokenCli {
    private const val ARCHIVO = "cli-token"

    fun leer(contexto: Context): String {
        val f = File(contexto.filesDir, ARCHIVO)
        if (f.exists()) {
            val t = f.readText().trim()
            if (t.isNotEmpty()) return t
        }
        val bytes = ByteArray(24)
        SecureRandom().nextBytes(bytes)
        val token = bytes.joinToString("") { "%02x".format(it) }
        f.writeText(token)
        return token
    }

    fun valido(contexto: Context, candidato: String?): Boolean {
        if (candidato.isNullOrBlank()) return false
        val bueno = leer(contexto)
        if (candidato.length != bueno.length) return false
        // Comparacion de tiempo constante: comparar con equals filtra el largo del prefijo
        // correcto por el tiempo que tarda en fallar.
        var diferencia = 0
        for (i in bueno.indices) diferencia = diferencia or (bueno[i].code xor candidato[i].code)
        return diferencia == 0
    }
}
