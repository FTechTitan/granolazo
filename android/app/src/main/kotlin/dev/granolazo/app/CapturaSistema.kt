package dev.granolazo.app

import android.annotation.SuppressLint
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.os.Build
import androidx.annotation.RequiresApi
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread
import kotlin.math.log10
import kotlin.math.sqrt

/**
 * Graba lo que suena en el telefono, en paralelo al microfono.
 *
 * **Lo que Android deja capturar y lo que no.** La captura de reproduccion existe desde
 * Android 10, pero el sistema solo entrega los usos MEDIA, GAME y UNKNOWN. El audio de una
 * llamada -USAGE_VOICE_COMMUNICATION- esta excluido a proposito por el sistema operativo, y
 * no hay permiso que lo habilite: un telefono que deja grabar la voz del otro sin que se
 * entere es exactamente lo que Google decidio impedir.
 *
 * O sea: aca sirve para grabar un video, un podcast o una reunion que se esta
 * reproduciendo; para una llamada en vivo la voz del otro entra por el microfono, con el
 * altavoz puesto. Es una diferencia real con Windows y la interfaz la dice, en vez de
 * ofrecer algo que el sistema va a negar en silencio.
 *
 * Ademas una app puede marcarse como no capturable (allowAudioPlaybackCapture=false) y
 * entonces entrega silencio. Por eso el nivel se mide siempre: sin medidor no habria forma
 * de distinguir "no sonaba nada" de "esta app no se deja grabar".
 */
@RequiresApi(Build.VERSION_CODES.Q)
object CapturaSistema {

    /** 16 kHz mono, el mismo perfil del microfono: asi mezclar despues es directo. */
    private const val MUESTREO = 16000
    private const val SILENCIO = -160.0

    private var grabador: AudioRecord? = null
    private var proyeccion: MediaProjection? = null
    private var hilo: Thread? = null
    private var archivo: RandomAccessFile? = null

    @Volatile private var corriendo = false
    @Volatile private var nivelActual = SILENCIO
    @Volatile private var bytesEscritos = 0L

    var rutaActual: String? = null
        private set

    val capturando: Boolean get() = corriendo

    fun nivel(): Double = if (corriendo) nivelActual else SILENCIO

    /**
     * Arranca la captura hacia [ruta]. Lanza si no se puede, para que el lado Dart reciba
     * el motivo y lo muestre en vez de quedarse esperando audio que no llega.
     */
    @SuppressLint("MissingPermission")
    fun iniciar(proyeccionMedia: MediaProjection, ruta: String) {
        if (corriendo) return

        val config = AudioPlaybackCaptureConfiguration.Builder(proyeccionMedia)
            // Los tres usos que el sistema permite. VOICE_COMMUNICATION no esta en la
            // lista y agregarlo lanza IllegalArgumentException.
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()

        val formato = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(MUESTREO)
            .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
            .build()

        val minimo = AudioRecord.getMinBufferSize(
            MUESTREO, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        // El minimo del sistema es lo justo para no perder muestras; se pide el cuadruple
        // para aguantar un hipo del hilo sin que el buffer se pise.
        val tamanoBuffer = if (minimo > 0) minimo * 4 else MUESTREO * 4

        val rec = AudioRecord.Builder()
            .setAudioFormat(formato)
            .setBufferSizeInBytes(tamanoBuffer)
            .setAudioPlaybackCaptureConfig(config)
            .build()

        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            throw IllegalStateException("el sistema no entrego la captura de reproduccion")
        }

        val destino = File(ruta)
        destino.parentFile?.mkdirs()
        if (destino.exists()) destino.delete()
        val raf = RandomAccessFile(destino, "rw")
        escribirCabecera(raf, 0L)
        raf.seek(44L)

        proyeccion = proyeccionMedia
        grabador = rec
        archivo = raf
        rutaActual = ruta
        bytesEscritos = 0
        nivelActual = SILENCIO
        corriendo = true

        rec.startRecording()
        hilo = thread(name = "granolazo-captura-sistema", isDaemon = true) {
            val buffer = ByteArray(tamanoBuffer)
            try {
                while (corriendo) {
                    val leidos = rec.read(buffer, 0, buffer.size)
                    if (leidos <= 0) continue
                    synchronized(CapturaSistema) {
                        archivo?.write(buffer, 0, leidos)
                    }
                    bytesEscritos += leidos
                    nivelActual = medir(buffer, leidos)
                }
            } catch (_: Throwable) {
                // Que se caiga la captura de la salida no puede tumbar la grabacion del
                // microfono, que es el minimo indispensable.
            }
        }
    }

    /** Detiene y cierra el WAV. Devuelve la ruta si quedo algo, o null. */
    fun detener(): String? {
        val ruta = rutaActual
        if (!corriendo && ruta == null) return null
        corriendo = false
        try { hilo?.join(1500) } catch (_: InterruptedException) {}
        hilo = null

        try { grabador?.stop() } catch (_: Throwable) {}
        try { grabador?.release() } catch (_: Throwable) {}
        grabador = null

        synchronized(CapturaSistema) {
            try {
                archivo?.let { escribirCabecera(it, bytesEscritos) }
                archivo?.close()
            } catch (_: Throwable) {}
            archivo = null
        }

        try { proyeccion?.stop() } catch (_: Throwable) {}
        proyeccion = null

        rutaActual = null
        nivelActual = SILENCIO
        return ruta
    }

    /** RMS del bloque, en dBFS: 0 es el maximo y los valores son negativos. */
    private fun medir(buffer: ByteArray, largo: Int): Double {
        if (largo < 2) return SILENCIO
        val bb = ByteBuffer.wrap(buffer, 0, largo).order(ByteOrder.LITTLE_ENDIAN)
        var suma = 0.0
        var n = 0
        while (bb.remaining() >= 2) {
            val m = bb.short.toDouble() / 32768.0
            suma += m * m
            n++
        }
        if (n == 0) return SILENCIO
        val rms = sqrt(suma / n)
        if (rms <= 0.0000001) return SILENCIO
        return 20.0 * log10(rms)
    }

    /**
     * Cabecera WAV de 44 bytes. Se escribe una vez con largo 0 al abrir y se reescribe con
     * el largo real al cerrar: hasta que no se termina de grabar no se sabe cuanto mide.
     */
    private fun escribirCabecera(raf: RandomAccessFile, bytesDeAudio: Long) {
        val canales = 1
        val bits = 16
        val byteRate = MUESTREO * canales * bits / 8
        val cab = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        cab.put("RIFF".toByteArray())
        cab.putInt((36 + bytesDeAudio).toInt())
        cab.put("WAVE".toByteArray())
        cab.put("fmt ".toByteArray())
        cab.putInt(16)
        cab.putShort(1.toShort())  // PCM: formato sin comprimir
        cab.putShort(canales.toShort())
        cab.putInt(MUESTREO)
        cab.putInt(byteRate)
        cab.putShort((canales * bits / 8).toShort())
        cab.putShort(bits.toShort())
        cab.put("data".toByteArray())
        cab.putInt(bytesDeAudio.toInt())
        val posicion = raf.filePointer
        raf.seek(0)
        raf.write(cab.array())
        raf.seek(if (bytesDeAudio == 0L) 44L else posicion)
    }
}
