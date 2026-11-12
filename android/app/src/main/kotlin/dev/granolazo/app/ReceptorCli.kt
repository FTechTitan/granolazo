package dev.granolazo.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * El modo consola en Android, por `adb`.
 *
 * Regla de diseno: todo lo que se puede hacer con el dedo se tenga que poder
 * hacer por linea de comandos, porque si no, la herramienta no se puede automatizar. Un
 * telefono no tiene terminal, asi que la superficie equivalente es `adb`:
 *
 *     adb shell am broadcast -a dev.granolazo.app.CLI \
 *       -n dev.granolazo.app/.ReceptorCli \
 *       --es token "<el token>" --es cmd "listar --json"
 *
 * La respuesta sale por logcat con la etiqueta `granolazo-cli` y ademas queda en
 * `files/cli-salida.txt`, porque logcat trunca las lineas largas y un `listar --json` con
 * varias grabaciones no entra.
 *
 * **No reimplementa nada.** Levanta un motor de Flutter sin pantalla en el punto de
 * entrada `cliAndroid` y corre el mismo [GranolazoCli] que usa Windows, con la misma
 * salida y los mismos codigos de retorno. Duplicar la logica en Kotlin habria garantizado
 * que las dos versiones se separaran en la primera semana.
 */
class ReceptorCli : BroadcastReceiver() {

    companion object {
        private const val ETIQUETA = "granolazo-cli"
        private const val CANAL = "granolazo/cli"
        private const val SALIDA = "cli-salida.txt"
    }

    override fun onReceive(contexto: Context, intent: Intent) {
        val pendiente = goAsync()

        if (!TokenCli.valido(contexto, intent.getStringExtra("token"))) {
            Log.w(ETIQUETA, "token invalido: se ignora el comando")
            pendiente.finish()
            return
        }

        val comando = intent.getStringExtra("cmd").orEmpty().trim()
        if (comando.isEmpty()) {
            Log.w(ETIQUETA, "falta --es cmd \"<comando>\"")
            pendiente.finish()
            return
        }

        // El motor de Flutter tiene que vivir en el hilo principal.
        Handler(Looper.getMainLooper()).post {
            val motor = FlutterEngine(contexto.applicationContext)
            var cerrado = false
            fun cerrar() {
                if (cerrado) return
                cerrado = true
                try { motor.destroy() } catch (_: Throwable) {}
                pendiente.finish()
            }

            try {
                motor.dartExecutor.executeDartEntrypoint(
                    DartExecutor.DartEntrypoint(
                        io.flutter.FlutterInjector.instance().flutterLoader().findAppBundlePath(),
                        "cliAndroid"
                    )
                )
                val canal = MethodChannel(motor.dartExecutor.binaryMessenger, CANAL)
                // Un comando que se cuelga no puede dejar el proceso tomado para siempre.
                val reloj = Handler(Looper.getMainLooper())
                val vencimiento = Runnable {
                    Log.e(ETIQUETA, "el comando no contesto en 90 s")
                    cerrar()
                }
                reloj.postDelayed(vencimiento, 90_000L)

                canal.invokeMethod(
                    "ejecutar",
                    listOf(comando),
                    object : MethodChannel.Result {
                        override fun success(resultado: Any?) {
                            reloj.removeCallbacks(vencimiento)
                            @Suppress("UNCHECKED_CAST")
                            val m = resultado as? Map<String, Any?> ?: emptyMap()
                            val texto = (m["salida"] as? String).orEmpty()
                            val codigo = (m["codigo"] as? Int) ?: 0
                            publicar(contexto, comando, texto, codigo)
                            cerrar()
                        }

                        override fun error(codigo: String, mensaje: String?, detalle: Any?) {
                            reloj.removeCallbacks(vencimiento)
                            Log.e(ETIQUETA, "fallo: $codigo ${mensaje.orEmpty()}")
                            publicar(contexto, comando, "error: $codigo ${mensaje.orEmpty()}", 1)
                            cerrar()
                        }

                        override fun notImplemented() {
                            reloj.removeCallbacks(vencimiento)
                            Log.e(ETIQUETA, "el motor no expuso el canal de consola")
                            cerrar()
                        }
                    }
                )
            } catch (e: Throwable) {
                Log.e(ETIQUETA, "no pude levantar el motor: ${e.message}")
                cerrar()
            }
        }
    }

    private fun publicar(contexto: Context, comando: String, texto: String, codigo: Int) {
        Log.i(ETIQUETA, "> $comando")
        texto.lineSequence().forEach { if (it.isNotEmpty()) Log.i(ETIQUETA, it) }
        Log.i(ETIQUETA, "codigo=$codigo")
        try {
            File(contexto.filesDir, SALIDA).writeText(texto + "\ncodigo=" + codigo + "\n")
        } catch (_: Throwable) {
            // Sin archivo queda logcat, que para comandos cortos alcanza.
        }
    }
}
