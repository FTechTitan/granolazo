import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import 'audio_sistema_service.dart';
import 'ffmpeg.dart';
import 'puente_android.dart';

/// Captura de audio del dispositivo, igual en escritorio y en móvil.
///
/// Graba en AAC dentro de un contenedor m4a, mono y a 32 kbps: es el mismo perfil que el
/// worker de transcripción usa al trocear, pesa poco para subir desde el celular y la
/// calidad alcanza de sobra para voz. Una hora de reunión queda en unos 14 MB.
class GrabadorService {
  GrabadorService({
    AudioRecorder? grabador,
    AudioSistemaService? audioSistema,
    PuenteAndroid? puente,
  })  : _grabador = grabador ?? AudioRecorder(),
        _sistema = audioSistema ?? AudioSistemaService(),
        _puente = puente ?? PuenteAndroid();

  final AudioRecorder _grabador;
  final AudioSistemaService _sistema;
  final PuenteAndroid _puente;

  /// Cuánto se sube o baja cada fuente al mezclar. 1 es dejarla como está.
  ///
  /// Se aplica al mezclar, o sea al detener: si se mueve durante la grabación, vale el
  /// valor que estaba al parar. Es una decisión, no un descuido — aplicarlo en vivo
  /// obligaría a reprocesar el audio mientras entra, y no aportaría nada.
  double gananciaMicrofono = 1.0;
  double gananciaSistema = 1.0;
  Timer? _cronometro;
  final _duracion = StreamController<Duration>.broadcast();
  final _nivel = StreamController<double>.broadcast();
  final _nivelSistema = StreamController<double>.broadcast();
  StreamSubscription<Amplitude>? _subNivel;
  Timer? _sondeoSistema;
  double _nivelSistemaActual = AudioSistemaService.silencio;

  /// Último nivel medido de la salida de audio, en dBFS.
  double get nivelSistemaActual => _nivelSistemaActual;
  double _nivelMaximoSistema = _silencioDigital;
  String? _avisoSistema;
  DateTime? _inicio;
  String? _rutaActual;
  double _nivelMaximo = _silencioDigital;

  /// Por debajo de esto no hay nada que transcribir.
  ///
  /// El grabador informa el nivel en dBFS: 0 es el máximo y los valores son negativos.
  /// Un micrófono mudo o desconectado entrega alrededor de -91 dBFS de forma constante;
  /// una habitación en silencio con el micrófono vivo ronda -50. El umbral va en el medio,
  /// lejos de los dos, para no confundir "grabó bajito" con "no grabó nada".
  static const double umbralDeSilencio = -70.0;
  static const double _silencioDigital = -160.0;

  /// Emite la duración mientras se graba, para la UI.
  Stream<Duration> get duracion => _duracion.stream;

  /// Emite el nivel del micrófono en dBFS mientras se graba, para el medidor.
  Stream<double> get nivel => _nivel.stream;

  /// Emite el nivel del audio que sale por los parlantes, para el segundo medidor.
  Stream<double> get nivelSistema => _nivelSistema.stream;

  /// ¿Se está capturando también lo que suena en el equipo?
  bool get capturandoSistema => _sistema.rutaActual != null;

  /// Por qué no se pudo capturar la salida de audio, si no se pudo.
  String? get avisoSistema => _avisoSistema;

  /// ¿Esta plataforma puede capturar la salida de audio?
  bool get puedeCapturarSistema => _sistema.soportado;

  /// ¿Esa captura incluye la voz del otro en una llamada?
  ///
  /// En Windows sí. En Android **no**, y no es un pendiente: el sistema excluye a propósito
  /// el audio de llamadas de la captura de reproducción, y no hay permiso que lo habilite.
  bool get capturaLlamadas => _sistema.tomaLlamadas;

  /// El nivel más alto que entró en la grabación en curso.
  double get nivelMaximo => _nivelMaximo;

  bool get grabando => _rutaActual != null;

  /// Ruta del WAV donde se está escribiendo el audio del equipo, si se captura. La lee la
  /// transcripción en vivo para sumarlo al micrófono sin tocar la grabación.
  String? get rutaSistemaActual => _sistema.rutaActual;

  /// Pide permiso de micrófono. En escritorio el sistema lo resuelve solo.
  Future<bool> tienePermiso() async {
    if (Platform.isAndroid || Platform.isIOS) {
      final estado = await Permission.microphone.request();
      if (!estado.isGranted) return false;
    }
    return _grabador.hasPermission();
  }

  /// Carpeta donde viven los audios de la app.
  static Future<Directory> carpetaGrabaciones() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}Granolazo');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Arranca la grabación y devuelve la ruta del archivo que se está escribiendo.
  Future<String> iniciar() async {
    if (grabando) throw StateError('ya hay una grabación en curso');
    if (!await tienePermiso()) {
      throw StateError('sin permiso de micrófono');
    }
    // Antes de abrir el micrófono: en Android, si la app deja de estar en pantalla sin un
    // servicio en primer plano sosteniéndola, el sistema congela el proceso y la grabación
    // se corta sola a los pocos segundos. Es la diferencia entre grabar una reunión y
    // grabar los diez segundos que el usuario tardó en cambiar de aplicación.
    await _puente.marcarGrabando(true);

    final dir = await carpetaGrabaciones();
    final marca = DateTime.now().toUtc().millisecondsSinceEpoch;
    final ruta = '${dir.path}${Platform.pathSeparator}grabacion-$marca.m4a';

    await _grabador.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 32000,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: ruta,
    );

    // La salida de audio se captura aparte y se mezcla al final: es lo que dice el otro
    // en una llamada, y el micrófono no lo toma —y si lo tomara, entraría con eco.
    _avisoSistema = await _sistema.iniciar('$ruta.sistema.wav');
    _sondeoSistema = Timer.periodic(const Duration(milliseconds: 300), (_) async {
      final n = await _sistema.nivel();
      _nivelSistemaActual = n;
      if (n > _nivelMaximoSistema) _nivelMaximoSistema = n;
      if (!_nivelSistema.isClosed) _nivelSistema.add(n);
    });

    _rutaActual = ruta;
    _inicio = DateTime.now();
    _nivelMaximo = _silencioDigital;
    _nivelMaximoSistema = _silencioDigital;
    _nivelSistemaActual = AudioSistemaService.silencio;
    _cronometro = Timer.periodic(const Duration(seconds: 1), (_) {
      final desde = _inicio;
      if (desde != null) _duracion.add(DateTime.now().difference(desde));
    });
    // Se mira el nivel mientras se graba, no después: es la unica forma de saber si el
    // micrófono estaba entregando algo, y permite avisar en el momento en vez de al final.
    _subNivel = _grabador
        .onAmplitudeChanged(const Duration(milliseconds: 300))
        .listen((a) {
      if (a.current > _nivelMaximo) _nivelMaximo = a.current;
      _nivel.add(a.current);
    }, onError: (_) {
      // Que la plataforma no informe el nivel no puede cortar la grabación.
    });
    return ruta;
  }

  /// Detiene la grabación.
  ///
  /// Devuelve también [mudo]: si el micrófono nunca entregó nada. Interesa distinguirlo de
  /// un archivo vacío, porque el archivo existe y pesa —son 30 segundos de silencio
  /// perfectamente codificados— y sin este aviso el silencio llega a transcribirse, donde
  /// el modelo inventa algo como "[Música]" y eso termina subido a Granolazo como si fuera
  /// una reunión.
  Future<
      ({
        String ruta,
        Duration duracion,
        int bytes,
        bool mudo,
        double nivelMaximo,
        bool conSistema,
        bool soloSistema,
      })?> detener() async {
    if (!grabando) return null;
    final desde = _inicio;
    _cronometro?.cancel();
    _cronometro = null;
    await _subNivel?.cancel();
    _subNivel = null;
    _sondeoSistema?.cancel();
    _sondeoSistema = null;

    final ruta = await _grabador.stop() ?? _rutaActual!;
    await _puente.marcarGrabando(false);
    final transcurrido =
        desde == null ? Duration.zero : DateTime.now().difference(desde);
    _rutaActual = null;
    _inicio = null;

    final delSistema = await _sistema.detener();
    final hayAudioDelSistema = _nivelMaximoSistema > umbralDeSilencio;

    // Se mezcla solo si de verdad sonó algo: mezclar un WAV mudo no aporta nada y
    // arriesga estropear un audio de micrófono que estaba bien.
    var rutaFinal = ruta;
    var conSistema = false;
    if (delSistema != null && hayAudioDelSistema) {
      final mezclado = await _mezclar(ruta, delSistema.path);
      if (mezclado != null) {
        rutaFinal = mezclado;
        conSistema = true;
      }
    }
    if (delSistema != null) {
      try {
        await delSistema.delete();
      } catch (_) {
        // Un temporal que no se puede borrar no es motivo para perder la grabación.
      }
    }

    final archivo = File(rutaFinal);
    final bytes = await archivo.exists() ? await archivo.length() : 0;
    return (
      ruta: rutaFinal,
      duracion: transcurrido,
      bytes: bytes,
      // Con audio del sistema no hay silencio que valga: hubo contenido aunque el
      // micrófono estuviera mudo.
      mudo: _nivelMaximo <= umbralDeSilencio && !hayAudioDelSistema,
      nivelMaximo: _nivelMaximo,
      conSistema: conSistema,
      soloSistema: _nivelMaximo <= umbralDeSilencio && hayAudioDelSistema,
    );
  }

  /// Junta el micrófono y la salida de audio en un solo archivo.
  ///
  /// Lo hace ffmpeg: el del sistema en escritorio, el que viene dentro del APK en Android
  /// —ahí no existe un binario suelto en el PATH ni forma de poner uno—. Si no está, se
  /// devuelve `null` y queda el audio del micrófono solo: media grabación es mejor que
  /// ninguna.
  ///
  /// `amix` con `normalize=0` a propósito: con la normalización por defecto, ffmpeg
  /// divide el volumen entre la cantidad de entradas y las dos voces quedan a la mitad.
  Future<String?> _mezclar(String rutaMicrofono, String rutaSistema) async {
    final destino = '$rutaMicrofono.mezcla.m4a';
    final gm = gananciaMicrofono.toStringAsFixed(2);
    final gs = gananciaSistema.toStringAsFixed(2);
    try {
      final salioBien = await Ffmpeg.correr([
        '-y',
        '-i', rutaMicrofono,
        '-i', rutaSistema,
        '-filter_complex',
        '[0:a]aresample=16000,volume=$gm[m];[1:a]aresample=16000,volume=$gs[s];'
            '[m][s]amix=inputs=2:duration=longest:normalize=0,'
            // Un limitador suave al final: si se suben las dos, la suma puede pasarse y
            // recortar. Esto lo contiene sin achatar lo que ya estaba bien.
            'alimiter=limit=0.97[a]',
        '-map', '[a]',
        '-ac', '1',
        '-ar', '16000',
        '-c:a', 'aac',
        '-b:a', '32k',
        destino,
      ]);
      final f = File(destino);
      if (!salioBien || !await f.exists() || await f.length() == 0) {
        // No dejar el archivo a medias tirado: confunde al mirar la carpeta.
        if (await f.exists()) {
          try {
            await f.delete();
          } catch (_) {}
        }
        return null;
      }
      // El micrófono solo ya no hace falta: lo que vale es la mezcla.
      try {
        await File(rutaMicrofono).delete();
      } catch (_) {}
      return destino;
    } catch (_) {
      // Sin ffmpeg no se puede mezclar. Queda el micrófono.
      return null;
    }
  }

  /// Reenvia al servicio de captura el fallo que llego tarde desde Android.
  void anotarFallaDeCaptura(String? motivo) {
    if (motivo == null) return;
    _avisoSistema = motivo;
    _sistema.anotarFalla(motivo);
  }

  /// Cancela y borra lo grabado.
  Future<void> cancelar() async {
    if (!grabando) return;
    _cronometro?.cancel();
    _cronometro = null;
    await _subNivel?.cancel();
    _subNivel = null;
    _sondeoSistema?.cancel();
    _sondeoSistema = null;
    final delSistema = await _sistema.detener();
    if (delSistema != null) {
      try {
        await delSistema.delete();
      } catch (_) {}
    }
    final ruta = _rutaActual;
    _rutaActual = null;
    _inicio = null;
    await _grabador.stop();
    await _puente.marcarGrabando(false);
    if (ruta != null) {
      final f = File(ruta);
      if (await f.exists()) await f.delete();
    }
  }

  Future<void> dispose() async {
    _cronometro?.cancel();
    _sondeoSistema?.cancel();
    await _subNivel?.cancel();
    await _duracion.close();
    await _nivel.close();
    await _nivelSistema.close();
    await _grabador.dispose();
  }
}
