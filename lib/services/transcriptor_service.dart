import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/granolazo_config.dart';
import '../models/segmento.dart';
import 'transcriptor.dart';

export 'transcriptor.dart' show ErrorTranscripcion;

/// Convierte audio en texto mandándolo a un servicio en línea.
///
/// Usa el mismo modelo que la vía rápida que ya existe en el backend
/// (`openai-transcription-worker.py`), así una grabación de la app y una del pool quedan
/// con transcripciones comparables.
///
/// El endpoint es configurable: por defecto va directo a OpenAI con la clave que el dueño
/// del dispositivo guarda en el almacén seguro, y se puede apuntar a una función propia
/// del backend para que ninguna clave viva en el dispositivo.
class TranscriptorService implements Transcriptor {
  TranscriptorService({http.Client? cliente, required this.clave})
      : _cliente = cliente ?? http.Client();

  final http.Client _cliente;

  /// Clave del proveedor. Viene del almacén seguro del dispositivo, nunca del binario.
  final String clave;

  @override
  String get nombre => 'api';

  /// Límite duro de la API de audio. Se deja margen para el sobre del multipart.
  static const int _maxBytesPorEnvio = 24 * 1024 * 1024;

  /// Transcribe un archivo completo.
  ///
  /// [onProgreso] recibe 0 a 100. Hoy el audio se manda en un solo envío; si supera el
  /// límite, falla con un mensaje claro en vez de cortar el audio en silencio, porque
  /// trocear bien exige recodificar y eso se resuelve en la fase siguiente.
  @override
  Future<Transcripcion> transcribir(
    File audio, {
    required String idioma,
    void Function(int porcentaje)? onProgreso,
  }) async {
    if (!await audio.exists()) {
      throw ErrorTranscripcion('el archivo de audio ya no está en el dispositivo');
    }
    final bytes = await audio.length();
    if (bytes == 0) {
      throw ErrorTranscripcion('la grabación quedó vacía');
    }
    if (bytes > _maxBytesPorEnvio) {
      final mb = (bytes / (1024 * 1024)).toStringAsFixed(1);
      throw ErrorTranscripcion(
        'la grabación pesa $mb MB y supera el máximo por envío. '
        'Grabaciones muy largas todavía no se dividen solas.',
      );
    }

    onProgreso?.call(10);

    final uri = Uri.parse(GranolazoConfig.transcriptionEndpoint);
    final peticion = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $clave'
      ..fields['model'] = GranolazoConfig.transcriptionModel
      ..fields['language'] = idioma
      // verbose_json y no json: es el que trae los tiempos de cada tramo. Cuesta lo
      // mismo y el texto viene igual, así que no hay motivo para pedir el otro.
      ..fields['response_format'] = 'verbose_json'
      ..files.add(await http.MultipartFile.fromPath('file', audio.path));

    onProgreso?.call(25);

    http.StreamedResponse respuesta;
    try {
      respuesta = await _cliente.send(peticion).timeout(const Duration(minutes: 15));
    } on SocketException {
      throw ErrorTranscripcion('sin conexión para transcribir');
    } catch (e) {
      throw ErrorTranscripcion('no se pudo contactar el servicio de transcripción: $e');
    }

    onProgreso?.call(80);
    final cuerpo = await respuesta.stream.bytesToString();

    if (respuesta.statusCode == 401 || respuesta.statusCode == 403) {
      throw ErrorTranscripcion(
        'la clave de transcripción fue rechazada. Revisala en Ajustes.',
        codigo: respuesta.statusCode,
      );
    }
    if (respuesta.statusCode == 429) {
      throw ErrorTranscripcion('el servicio está saturado, hay que probar de nuevo en un rato',
          codigo: 429);
    }
    if (respuesta.statusCode >= 400) {
      throw ErrorTranscripcion(
        'el servicio respondió ${respuesta.statusCode}: ${_resumirError(cuerpo)}',
        codigo: respuesta.statusCode,
      );
    }

    onProgreso?.call(95);

    final r = _interpretar(cuerpo);
    if (r.texto.trim().isEmpty && r.segmentos.isEmpty) {
      throw ErrorTranscripcion('la transcripción volvió vacía');
    }
    onProgreso?.call(100);
    return r;
  }

  /// Lee la respuesta, con o sin tiempos.
  ///
  /// El formato detallado trae `segments` con `start` y `end` en segundos. Si el endpoint
  /// es propio y devuelve solo texto, se acepta igual: perder los tiempos no puede
  /// significar perder la transcripción.
  Transcripcion _interpretar(String cuerpo) {
    try {
      final j = jsonDecode(cuerpo);
      if (j is Map) {
        final segmentos = <Segmento>[];
        for (final s in (j['segments'] as List?) ?? const []) {
          if (s is! Map) continue;
          final t = (s['text'] ?? '').toString().trim();
          if (t.isEmpty) continue;
          segmentos.add(Segmento(
            desde: _segundos(s['start']),
            hasta: _segundos(s['end']),
            texto: t,
          ));
        }
        final texto = j['text'] is String
            ? (j['text'] as String).trim()
            : Segmento.textoPlano(segmentos);
        return Transcripcion(texto: texto, segmentos: segmentos);
      }
    } catch (_) {
      // Un endpoint propio puede devolver texto plano.
    }
    return Transcripcion(texto: cuerpo.trim());
  }

  static Duration _segundos(Object? v) {
    final n = v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
    return Duration(milliseconds: (n * 1000).round());
  }

  String _resumirError(String cuerpo) {
    try {
      final j = jsonDecode(cuerpo);
      if (j is Map && j['error'] is Map && j['error']['message'] is String) {
        return j['error']['message'] as String;
      }
    } catch (_) {}
    return cuerpo.length > 160 ? '${cuerpo.substring(0, 160)}…' : cuerpo;
  }

  @override
  void dispose() => _cliente.close();
}
