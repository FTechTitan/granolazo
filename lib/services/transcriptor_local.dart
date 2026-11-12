import 'dart:io';

import 'package:whisper_ggml/whisper_ggml.dart';

import '../models/segmento.dart';
import 'transcriptor.dart';

/// Los modelos de Whisper que la app ofrece, con lo que cuesta cada uno.
///
/// No se exponen todos los que trae la librería: los `*.en` son solo inglés y acá el
/// idioma habitual es el español, así que sobran. `large` tampoco entra: son casi 3 GB y
/// en un equipo sin GPU tarda más de lo que dura la reunión.
enum ModeloLocal {
  base(WhisperModel.base, 'base', 148, 'rápido, sirve para audio limpio'),
  small(WhisperModel.small, 'small', 488, 'el equilibrio recomendado'),
  medium(WhisperModel.medium, 'medium', 1530, 'el mejor, pero lento sin tarjeta de video');

  const ModeloLocal(this.modelo, this.nombre, this.megas, this.descripcion);

  final WhisperModel modelo;
  final String nombre;
  final int megas;
  final String descripcion;

  static ModeloLocal desdeNombre(String? n) =>
      ModeloLocal.values.firstWhere((m) => m.nombre == n, orElse: () => ModeloLocal.small);
}

/// Transcribe con el procesador de este equipo, sin llamar a ningún servicio.
///
/// Usa whisper.cpp a través de `whisper_ggml`. Existe porque la vía por API cobra por
/// minuto y obliga a tener una clave del proveedor en el dispositivo: para el grueso de
/// las reuniones, que no son urgentes, el propio equipo alcanza y sale gratis.
///
/// **Formato del audio.** whisper.cpp come WAV de 16 kHz mono. En Android la librería trae
/// su propio ffmpeg y convierte sola; en Windows y Linux usa el `ffmpeg` del sistema si
/// está en el PATH. Por eso [ffmpegDisponible] se consulta antes de ofrecer este motor
/// para un audio que no sea WAV.
class TranscriptorLocal implements Transcriptor {
  TranscriptorLocal({WhisperController? controlador, this.modelo = ModeloLocal.small})
      : _whisper = controlador ?? WhisperController();

  final WhisperController _whisper;
  final ModeloLocal modelo;

  @override
  String get nombre => 'local';

  @override
  Future<Transcripcion> transcribir(
    File audio, {
    required String idioma,
    void Function(int porcentaje)? onProgreso,
  }) async {
    if (!await audio.exists()) {
      throw ErrorTranscripcion('el archivo de audio ya no está en el dispositivo');
    }
    if (await audio.length() == 0) {
      throw ErrorTranscripcion('la grabación quedó vacía');
    }
    if (!await puedeConEste(audio)) {
      throw ErrorTranscripcion(
        'para transcribir un audio que no es WAV hace falta ffmpeg instalado y en el '
        'PATH. Instalarlo, o transcribir por el servicio en línea.',
      );
    }

    final String texto;
    final segmentos = <Segmento>[];
    try {
      // El tipo del resultado no lo exporta la librería: queda inferido.
      final r = await _whisper.transcribe(
        model: modelo.modelo,
        audioPath: audio.path,
        // El modelo se queda cargado en memoria: al procesar una cola entera, evita
        // pagar varios segundos de carga por cada grabación.
        keepModelLoaded: true,
        lang: idioma,
        // Con esto cada tramo viene con su momento dentro de la grabación, que es lo
        // que permite saber cuándo se dijo algo y saltar ahí para escucharlo.
        withSegments: true,
        onProgress: onProgreso,
      );
      texto = r?.transcription.text.trim() ?? '';
      for (final s in r?.transcription.segments ?? const []) {
        final t = s.text.trim();
        if (t.isEmpty) continue;
        segmentos.add(Segmento(desde: s.fromTs, hasta: s.toTs, texto: t));
      }
    } catch (e) {
      throw ErrorTranscripcion('falló la transcripción en este equipo: $e');
    }

    if (texto.isEmpty && segmentos.isEmpty) {
      throw ErrorTranscripcion('la transcripción volvió vacía');
    }
    return Transcripcion(
      texto: texto.isNotEmpty ? texto : Segmento.textoPlano(segmentos),
      segmentos: segmentos,
    );
  }

  /// ¿Está el modelo ya bajado? Bajarlo son cientos de megas, así que conviene avisar
  /// antes en vez de que la primera transcripción se quede colgada sin explicación.
  Future<bool> modeloDescargado() async {
    final ruta = await _whisper.getPath(modelo.modelo);
    return File(ruta).exists();
  }

  Future<String> rutaDelModelo() => _whisper.getPath(modelo.modelo);

  /// Baja el modelo. Devuelve la ruta donde quedó.
  ///
  /// Ojo: la librería arma el archivo entero en memoria antes de escribirlo, así que
  /// bajar `medium` necesita más de 1,5 GB de RAM libre en el momento.
  Future<String> descargarModelo() => _whisper.downloadModel(modelo.modelo);

  /// Suelta el modelo de la memoria nativa. Llamarlo al terminar una tanda.
  Future<void> soltarModelo() async {
    try {
      await _whisper.releaseModel();
    } catch (_) {
      // Que no haya nada cargado no es un error.
    }
  }

  /// ¿Se puede transcribir este archivo en este equipo?
  Future<bool> puedeConEste(File audio) async {
    if (audio.path.toLowerCase().endsWith('.wav')) return true;
    return ffmpegDisponible();
  }

  /// ¿Hay un ffmpeg utilizable? En Android e iOS la librería trae el suyo.
  static Future<bool> ffmpegDisponible() async {
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) return true;
    try {
      final r = await Process.run('ffmpeg', ['-version']);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {}
}
