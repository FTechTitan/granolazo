package dev.granolazo.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder

/** Las acciones van sin icono: la sobrecarga con `Int` esta obsoleta y un null pelado
 * seria ambiguo para el compilador. */
private val sinIcono: Icon? = null

/**
 * Mantiene viva la grabacion cuando la app deja de estar en pantalla, y es quien toma la
 * proyeccion de medios.
 *
 * **Sin esto la app no sirve en un telefono.** Android congela los procesos en segundo
 * plano: basta cambiar de app o apagar la pantalla para que la grabacion se corte sola a
 * los pocos segundos. Un servicio en primer plano es la unica forma de pedirle al sistema
 * que no lo haga, y el precio que cobra Android es una notificacion permanente -que de
 * paso cumple el papel del icono de la bandeja en Windows: es el rastro visible de que la
 * app esta trabajando, y desde ahi se la detiene.
 *
 * **Por que la proyeccion se pide aca y no en la actividad.** Desde Android 10 el sistema
 * exige que un servicio en primer plano con el tipo `mediaProjection` ya este corriendo
 * cuando se llama a `getMediaProjection()`; si no, lanza `SecurityException`. Hacerlo
 * desde la actividad obligaria a arrancar el servicio y adivinar cuanto esperar a que el
 * sistema lo registre. Aca no hay que adivinar: el propio servicio la pide despues de su
 * `startForeground`, que es exactamente el momento en que ya es legal.
 */
class ServicioGrabacion : Service() {

    companion object {
        const val CANAL = "granolazo_grabacion"
        const val ID_NOTIFICACION = 1001
        const val ACCION_DETENER = "dev.granolazo.app.DETENER_GRABACION"

        private const val EXTRA_CODIGO = "codigo"
        private const val EXTRA_DATOS = "datos"
        private const val EXTRA_RUTA = "ruta"

        /** Arranca el servicio sin captura de la salida: solo para sostener el microfono. */
        fun arrancar(contexto: Context) = lanzar(contexto, Intent(contexto, ServicioGrabacion::class.java))

        /** Arranca el servicio y, ya en primer plano, toma la proyeccion y captura. */
        fun arrancarConCaptura(contexto: Context, codigo: Int, datos: Intent, ruta: String) {
            val i = Intent(contexto, ServicioGrabacion::class.java)
                .putExtra(EXTRA_CODIGO, codigo)
                .putExtra(EXTRA_DATOS, datos)
                .putExtra(EXTRA_RUTA, ruta)
            lanzar(contexto, i)
        }

        fun parar(contexto: Context) {
            contexto.stopService(Intent(contexto, ServicioGrabacion::class.java))
        }

        private fun lanzar(contexto: Context, i: Intent) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                contexto.startForegroundService(i)
            } else {
                contexto.startService(i)
            }
        }
    }

    private var proyeccion: MediaProjection? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        crearCanal()
        ponerseEnPrimerPlano()

        val ruta = intent?.getStringExtra(EXTRA_RUTA)
        val codigo = intent?.getIntExtra(EXTRA_CODIGO, 0) ?: 0
        @Suppress("DEPRECATION")
        val datos = intent?.getParcelableExtra<Intent>(EXTRA_DATOS)

        if (ruta != null && datos != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            CanalGranolazo.avisarCaptura(tomarLaSalida(codigo, datos, ruta))
        }

        // START_NOT_STICKY: si el sistema mata el proceso, la grabacion ya se perdio.
        // Revivir el cascaron solo dejaria una notificacion mintiendo que se esta grabando.
        return START_NOT_STICKY
    }

    /** Devuelve `null` si la captura arranco, o el motivo si no. */
    private fun tomarLaSalida(codigo: Int, datos: Intent, ruta: String): String? = try {
        val mpm = getSystemService(MediaProjectionManager::class.java)
        val p = mpm.getMediaProjection(codigo, datos)
            ?: throw IllegalStateException("el sistema no entrego la proyeccion")
        // Desde Android 14 hay que registrar un callback o `createVirtualDisplay` y la
        // captura falla en silencio. Aca no se crea pantalla virtual -solo interesa el
        // audio- asi que el callback es lo unico que el sistema pide.
        p.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                CapturaSistema.detener()
            }
        }, null)
        proyeccion = p
        CapturaSistema.iniciar(p, ruta)
        null
    } catch (e: SecurityException) {
        "Android no autorizo la captura de la salida de audio"
    } catch (e: Throwable) {
        e.message ?: "no pude capturar el audio del equipo"
    }

    private fun ponerseEnPrimerPlano() {
        val n = construirNotificacion()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val tipos = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            startForeground(ID_NOTIFICACION, n, tipos)
        } else {
            startForeground(ID_NOTIFICACION, n)
        }
    }

    private fun crearCanal() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CANAL) != null) return
        // LOW: tiene que verse, no sonar. Es un aviso de estado, no una alerta.
        val canal = NotificationChannel(
            CANAL, "Grabacion en curso", NotificationManager.IMPORTANCE_LOW
        )
        canal.description = "Avisa que Granolazo esta grabando"
        canal.setShowBadge(false)
        nm.createNotificationChannel(canal)
    }

    private fun construirNotificacion(): Notification {
        val alTocar = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java)
                .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val alDetener = PendingIntent.getBroadcast(
            this, 1,
            Intent(this, ReceptorAvisos::class.java).setAction(ACCION_DETENER),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CANAL)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(this)
        }
        return b
            .setContentTitle("Granolazo esta grabando")
            .setContentText("Toca para volver a la app")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentIntent(alTocar)
            .setOngoing(true)
            .setUsesChronometer(true)
            .addAction(Notification.Action.Builder(sinIcono, "Detener", alDetener).build())
            .build()
    }

    override fun onDestroy() {
        CapturaSistema.detener()
        try { proyeccion?.stop() } catch (_: Throwable) {}
        proyeccion = null
        super.onDestroy()
    }
}
