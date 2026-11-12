package dev.granolazo.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper

/** Las acciones van sin icono: la sobrecarga con `Int` esta obsoleta y un null pelado
 * seria ambiguo para el compilador. */
private val sinIcono: Icon? = null

/**
 * Se da cuenta de cuando empieza una reunion y ofrece grabarla.
 *
 * **Como lo sabe.** Cuando una app entra en una llamada -Discord, Meet, WhatsApp, Zoom,
 * Teams- le pide al sistema el modo `MODE_IN_COMMUNICATION`, porque lo necesita para
 * activar la cancelacion de eco y enrutar el audio al auricular. Ese modo es global y
 * cualquier app lo puede leer sin permisos especiales.
 *
 * Es el analogo exacto de lo que se mira en Windows -quien tiene tomado el microfono- y
 * comparte su mejor propiedad: **no depende de conocer cada programa**. Una app nueva que
 * salga manana va a entrar en modo llamada igual, porque si no lo hace no le funciona el
 * audio.
 *
 * Mirar que apps estan abiertas no habria servido: tener Discord abierto no es estar en
 * una llamada. Y la lista de quien esta grabando -`getActiveRecordingConfigurations`- en
 * Android 10 y posteriores viene filtrada a la propia app, asi que no sirve para esto.
 *
 * Desde Android 12 el sistema avisa el cambio de modo con un callback y no hay que
 * preguntar nada; en versiones anteriores se pregunta cada 8 segundos, que es barato -una
 * lectura de un entero- y no despierta radios ni discos.
 */
class ServicioVigilante : Service() {

    companion object {
        const val CANAL = "granolazo_reuniones"
        const val ID_NOTIFICACION = 2001
        const val ACCION_GRABAR = "dev.granolazo.app.GRABAR_REUNION"
        const val ACCION_DESCARTAR = "dev.granolazo.app.DESCARTAR_REUNION"
        const val ACCION_NO_AVISAR = "dev.granolazo.app.NO_AVISAR"

        /** Lo comparte con el canal de Dart para contestar `reuniones-en-curso`. */
        @Volatile var appEnLlamada: String? = null
            private set

        @Volatile var vigilando = false
            private set

        /**
         * "Ahora no" no puede significar "volve a preguntar en ocho segundos". Se levanta
         * solo cuando termina la llamada, que es cuando volveria a tener sentido.
         */
        @Volatile var silenciado = false

        fun arrancar(contexto: Context) {
            val i = Intent(contexto, ServicioVigilante::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                contexto.startForegroundService(i)
            } else {
                contexto.startService(i)
            }
        }

        fun parar(contexto: Context) {
            contexto.stopService(Intent(contexto, ServicioVigilante::class.java))
        }

        /**
         * Lee el modo de audio del sistema. Publico para que el canal de Dart pueda
         * contestar aunque el servicio no este corriendo.
         */
        fun hayLlamada(contexto: Context): Boolean {
            val am = contexto.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val modo = am.mode
            return modo == AudioManager.MODE_IN_COMMUNICATION || modo == AudioManager.MODE_IN_CALL
        }

        /**
         * Nombre de la app que esta al frente, si el usuario concedio el acceso al uso de
         * aplicaciones. Es opcional a proposito: pedir ese permiso para poder escribir un
         * nombre en un aviso no vale la molestia, asi que si no esta, el aviso dice
         * "una llamada" y funciona igual.
         */
        fun appAlFrente(contexto: Context): String? {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP_MR1) return null
            return try {
                val usm = contexto.getSystemService(Context.USAGE_STATS_SERVICE)
                    as? UsageStatsManager ?: return null
                val ahora = System.currentTimeMillis()
                val eventos = usm.queryEvents(ahora - 60_000, ahora)
                val e = UsageEvents.Event()
                var ultimo: String? = null
                while (eventos.hasNextEvent()) {
                    eventos.getNextEvent(e)
                    if (e.eventType == UsageEvents.Event.MOVE_TO_FOREGROUND) {
                        ultimo = e.packageName
                    }
                }
                if (ultimo == null || ultimo == contexto.packageName) return null
                nombreLegible(contexto, ultimo)
            } catch (_: Throwable) {
                // Sin el permiso concedido esto lanza o vuelve vacio. No es un error.
                null
            }
        }

        private fun nombreLegible(contexto: Context, paquete: String): String? = try {
            val pm = contexto.packageManager
            pm.getApplicationLabel(pm.getApplicationInfo(paquete, 0)).toString()
        } catch (_: Throwable) {
            paquete
        }
    }

    private val mano = Handler(Looper.getMainLooper())
    private var reloj: Runnable? = null
    private var escucha: AudioManager.OnModeChangedListener? = null
    private var avisando = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        crearCanales()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val tipo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            } else {
                0
            }
            if (tipo != 0) {
                startForeground(ID_NOTIFICACION, notificacionDeGuardia(), tipo)
            } else {
                startForeground(ID_NOTIFICACION, notificacionDeGuardia())
            }
        } else {
            startForeground(ID_NOTIFICACION, notificacionDeGuardia())
        }
        vigilando = true
        empezarAEscuchar()
        // START_STICKY aca si tiene sentido, al reves que en la grabacion: si el sistema
        // mata al vigilante, revivirlo lo devuelve a su unico trabajo, que es esperar.
        return START_STICKY
    }

    private fun empezarAEscuchar() {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val l = AudioManager.OnModeChangedListener { revisar() }
            escucha = l
            am.addOnModeChangedListener(mainExecutor, l)
            revisar()
        } else {
            val r = object : Runnable {
                override fun run() {
                    revisar()
                    mano.postDelayed(this, 8_000L)
                }
            }
            reloj = r
            mano.post(r)
        }
    }

    private fun revisar() {
        val enLlamada = hayLlamada(this)
        if (!enLlamada) {
            appEnLlamada = null
            if (avisando || silenciado) {
                avisando = false
                silenciado = false
                getSystemService(NotificationManager::class.java).cancel(ID_NOTIFICACION + 1)
            }
            return
        }
        appEnLlamada = appAlFrente(this) ?: "una llamada"
        // Ya se esta grabando: ofrecer grabar seria ruido.
        if (CanalGranolazo.grabando) return
        if (avisando || silenciado) return
        avisando = true
        getSystemService(NotificationManager::class.java)
            .notify(ID_NOTIFICACION + 1, avisoDeReunion(appEnLlamada!!))
    }

    private fun crearCanales() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CANAL) == null) {
            val guardia = NotificationChannel(
                CANAL, "Atento a reuniones", NotificationManager.IMPORTANCE_MIN
            )
            guardia.description = "Aviso permanente de que Granolazo esta atento"
            guardia.setShowBadge(false)
            nm.createNotificationChannel(guardia)
        }
        if (nm.getNotificationChannel(CANAL_AVISO) == null) {
            // DEFAULT y no HIGH: que aparezca arriba sin sonido ni vibracion. Sutil es un
            // requisito, no un adorno -si interrumpe, lo primero que se hace es apagarlo.
            val aviso = NotificationChannel(
                CANAL_AVISO, "Sugerencia de grabar", NotificationManager.IMPORTANCE_DEFAULT
            )
            aviso.description = "Ofrece grabar cuando empieza una reunion"
            aviso.setSound(null, null)
            aviso.enableVibration(false)
            nm.createNotificationChannel(aviso)
        }
    }

    private fun notificacionDeGuardia(): Notification {
        val abrir = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java)
                .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CANAL)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(this)
        }
        return b
            .setContentTitle("Granolazo esta atento")
            .setContentText("Avisa cuando empiece una reunion")
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setContentIntent(abrir)
            .setOngoing(true)
            .build()
    }

    private fun avisoDeReunion(app: String): Notification {
        fun emision(accion: String, codigo: Int) = PendingIntent.getBroadcast(
            this, codigo,
            Intent(this, ReceptorAvisos::class.java).setAction(accion),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CANAL_AVISO)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(this)
        }
        return b
            .setContentTitle("Grabo esta reunion?")
            .setContentText("$app esta en llamada")
            .setStyle(
                Notification.BigTextStyle().bigText(
                    "$app esta en llamada. Graba tu voz y queda en espera hasta que pidas " +
                        "transcribirla."
                )
            )
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setAutoCancel(true)
            .setContentIntent(emision(ACCION_GRABAR, 10))
            .addAction(Notification.Action.Builder(sinIcono, "Grabar", emision(ACCION_GRABAR, 11)).build())
            .addAction(Notification.Action.Builder(sinIcono, "Ahora no", emision(ACCION_DESCARTAR, 12)).build())
            .addAction(Notification.Action.Builder(sinIcono, "No avisar mas", emision(ACCION_NO_AVISAR, 13)).build())
            .build()
    }

    override fun onDestroy() {
        vigilando = false
        appEnLlamada = null
        reloj?.let { mano.removeCallbacks(it) }
        reloj = null
        escucha?.let {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                try { am.removeOnModeChangedListener(it) } catch (_: Throwable) {}
            }
        }
        escucha = null
        super.onDestroy()
    }
}

const val CANAL_AVISO = "granolazo_sugerencia"
