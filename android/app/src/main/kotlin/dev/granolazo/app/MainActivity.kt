package dev.granolazo.app

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * La pantalla, y el unico lugar desde donde se puede pedir el consentimiento del usuario.
 *
 * Todo lo que necesita una actividad viva -el dialogo de la captura de pantalla, pedir
 * permisos- pasa por aca. Lo que tiene que sobrevivir a la pantalla vive en los servicios.
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val CANAL_AUDIO = "granolazo/audio_sistema"
        private const val PEDIDO_PROYECCION = 4711
        private const val PEDIDO_NOTIFICACIONES = 4712
    }

    private var esperandoProyeccion: MethodChannel.Result? = null
    private var rutaPendiente: String? = null
    private var ordenPendiente: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ordenPendiente = intent?.getStringExtra(CanalGranolazo.EXTRA_ORDEN)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val orden = intent.getStringExtra(CanalGranolazo.EXTRA_ORDEN) ?: return
        // Si el motor ya esta vivo la orden llega directo; si no, queda para que Dart la
        // pida cuando termine de arrancar.
        if (!CanalGranolazo.entregar(orden)) ordenPendiente = orden
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val mensajero = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(mensajero, CANAL_AUDIO).setMethodCallHandler { llamada, resultado ->
            atenderAudio(llamada, resultado)
        }

        val general = MethodChannel(mensajero, CanalGranolazo.CANAL)
        general.setMethodCallHandler { llamada, resultado -> atenderGeneral(llamada, resultado) }
        CanalGranolazo.canal = general
    }

    // ── audio del sistema ────────────────────────────────────────────────────────

    private fun atenderAudio(llamada: MethodCall, resultado: MethodChannel.Result) {
        when (llamada.method) {
            "soportado" -> resultado.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)

            "iniciar" -> {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                    resultado.error("viejo", "hace falta Android 10 o superior", null)
                    return
                }
                val ruta = llamada.arguments as? String
                if (ruta == null) {
                    resultado.error("ruta", "falta la ruta del archivo", null)
                    return
                }
                if (esperandoProyeccion != null) {
                    resultado.error("ocupado", "ya hay un permiso de captura en curso", null)
                    return
                }
                rutaPendiente = ruta
                esperandoProyeccion = resultado
                // El sistema obliga a preguntar cada vez: el permiso de captura no se
                // puede guardar, por diseno de Android. Es molesto y es a proposito.
                val mpm = getSystemService(MediaProjectionManager::class.java)
                startActivityForResult(mpm.createScreenCaptureIntent(), PEDIDO_PROYECCION)
            }

            "detener" -> {
                CapturaSistema.detener()
                ServicioGrabacion.parar(this)
                resultado.success(null)
            }

            "nivel" -> resultado.success(CapturaSistema.nivel())

            else -> resultado.notImplemented()
        }
    }

    override fun onActivityResult(pedido: Int, codigo: Int, datos: Intent?) {
        super.onActivityResult(pedido, codigo, datos)
        if (pedido != PEDIDO_PROYECCION) return

        val resultado = esperandoProyeccion
        val ruta = rutaPendiente
        esperandoProyeccion = null
        rutaPendiente = null
        if (resultado == null || ruta == null) return

        if (codigo != Activity.RESULT_OK || datos == null) {
            resultado.error("denegado", "no diste permiso para capturar la salida", null)
            return
        }
        ServicioGrabacion.arrancarConCaptura(this, codigo, datos, ruta)
        // Se contesta al toque y el resultado real llega despues por el evento `captura`:
        // esperar a que el servicio termine de arrancar retrasaria el microfono, que es
        // lo unico que no se puede perder.
        resultado.success(true)
    }

    // ── vigilante, arranque y permisos ───────────────────────────────────────────

    private fun atenderGeneral(llamada: MethodCall, resultado: MethodChannel.Result) {
        when (llamada.method) {
            "ordenPendiente" -> {
                resultado.success(ordenPendiente)
                ordenPendiente = null
            }

            "enLlamada" -> resultado.success(
                mapOf(
                    "activa" to ServicioVigilante.hayLlamada(this),
                    "app" to (ServicioVigilante.appEnLlamada
                        ?: ServicioVigilante.appAlFrente(this)),
                    "vigilando" to ServicioVigilante.vigilando,
                )
            )

            "vigilante" -> {
                val encender = llamada.arguments as? Boolean ?: false
                Preferencias.guardarBool(this, Preferencias.DETECTAR, encender)
                if (encender) ServicioVigilante.arrancar(this) else ServicioVigilante.parar(this)
                resultado.success(encender)
            }

            "detectarActivo" ->
                resultado.success(Preferencias.leerBool(this, Preferencias.DETECTAR, true))

            "arranque" -> {
                val encender = llamada.arguments as? Boolean ?: false
                Preferencias.guardarBool(this, Preferencias.ARRANCAR, encender)
                // Encender el arranque sin el vigilante no haria nada al reiniciar: lo
                // unico que se arranca al encender el telefono es el vigilante.
                if (encender) {
                    Preferencias.guardarBool(this, Preferencias.DETECTAR, true)
                    ServicioVigilante.arrancar(this)
                }
                resultado.success(encender)
            }

            "arranqueActivo" ->
                resultado.success(Preferencias.leerBool(this, Preferencias.ARRANCAR, false))

            "grabando" -> {
                val si = llamada.arguments as? Boolean ?: false
                CanalGranolazo.grabando = si
                if (si) ServicioGrabacion.arrancar(this) else ServicioGrabacion.parar(this)
                resultado.success(si)
            }

            "pedirNotificaciones" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                    checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                    PackageManager.PERMISSION_GRANTED
                ) {
                    requestPermissions(
                        arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                        PEDIDO_NOTIFICACIONES
                    )
                }
                resultado.success(true)
            }

            "abrirUsoDeApps" -> {
                // Opcional: solo sirve para poder nombrar la app que esta en llamada.
                try {
                    startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
                    resultado.success(true)
                } catch (_: Throwable) {
                    resultado.success(false)
                }
            }

            "cliToken" -> resultado.success(TokenCli.leer(this))

            else -> resultado.notImplemented()
        }
    }

    override fun onDestroy() {
        CanalGranolazo.canal = null
        super.onDestroy()
    }
}
