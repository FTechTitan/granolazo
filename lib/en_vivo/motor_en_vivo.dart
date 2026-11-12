import 'dart:io';

import 'package:whisper_ggml/whisper_ggml.dart';

import 'estado_en_vivo.dart';

/// El que convierte un trozo de audio en texto para el borrador en vivo.
///
/// Es una interfaz para poder probar el troceo y el estado sin cargar whisper.
abstract class MotorEnVivo {
  /// Transcribe un WAV de 16 kHz mono. Los tiempos de los segmentos son relativos al
  /// comienzo de ese archivo.
  Future<List<SegmentoEnVivo>> transcribir(File wav, {required String idioma});

  /// Suelta lo que haya en memoria (el modelo).
  Future<void> liberar();
}

/// Los modelos que se ofrecen para el borrador en vivo. `tiny` y `base` son los que
/// aguantan tiempo real en un equipo sin tarjeta de video; `small` queda para equipos
/// holgados.
enum ModeloEnVivo {
  tiny(WhisperModel.tiny, 'tiny', 75),
  base(WhisperModel.base, 'base', 148),
  small(WhisperModel.small, 'small', 488);

  const ModeloEnVivo(this.modelo, this.nombre, this.megas);

  final WhisperModel modelo;
  final String nombre;
  final int megas;

  static ModeloEnVivo? desdeNombre(String? n) {
    for (final m in values) {
      if (m.nombre == n) return m;
    }
    return null;
  }

  static ModeloEnVivo desdeNombreOBase(String? n) => desdeNombre(n) ?? ModeloEnVivo.base;
}

/// Whisper local con pocos hilos. Cada trozo corre en un isolate aparte (lo hace la
/// librería), así que no frena ni la interfaz ni la captura de audio.
class MotorEnVivoWhisper implements MotorEnVivo {
  MotorEnVivoWhisper({
    required this.modelo,
    required this.hilos,
    WhisperController? controlador,
  }) : _whisper = controlador ?? WhisperController();

  final ModeloEnVivo modelo;
  final int hilos;
  final WhisperController _whisper;

  /// ¿Está el archivo del modelo en la carpeta de datos?
  Future<bool> modeloDescargado() async => File(await _whisper.getPath(modelo.modelo)).exists();

  Future<String> rutaDelModelo() => _whisper.getPath(modelo.modelo);

  /// Baja el modelo (ver el aviso de memoria en `TranscriptorLocal.descargarModelo`).
  Future<String> descargarModelo() => _whisper.downloadModel(modelo.modelo);

  @override
  Future<List<SegmentoEnVivo>> transcribir(File wav, {required String idioma}) async {
    final ruta = await _whisper.getPath(modelo.modelo);
    if (!await File(ruta).exists()) {
      throw StateError('falta el modelo ${modelo.nombre} para la transcripción en vivo');
    }
    // Se llama a Whisper directo y no a WhisperController.transcribe porque este no deja
    // fijar los hilos, y el valor por defecto (6) le quita CPU a lo que se esté haciendo.
    final r = await Whisper(model: modelo.modelo).transcribe(
      transcribeRequest: TranscribeRequest(
        audio: wav.path,
        language: idioma,
        threads: hilos,
        isNoTimestamps: false,
        // Cada trozo se transcribe solo: arrastrar contexto entre trozos independientes
        // es receta para repeticiones inventadas.
        noContext: true,
        suppressNonSpeechTokens: true,
        keepModelLoaded: true,
      ),
      modelPath: ruta,
    );
    return [
      for (final s in r.segments ?? const <WhisperTranscribeSegment>[])
        if (s.text.trim().isNotEmpty)
          SegmentoEnVivo(
            desdeSeg: s.fromTs.inMilliseconds / 1000.0,
            hastaSeg: s.toTs.inMilliseconds / 1000.0,
            texto: s.text.trim(),
          ),
    ];
  }

  @override
  Future<void> liberar() async {
    try {
      await _whisper.releaseModel();
    } catch (_) {
      // Que no haya nada cargado no es un error.
    }
  }
}
