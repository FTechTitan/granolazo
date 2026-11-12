import 'dart:convert';
import 'dart:io';

import '../services/datos_app.dart';

/// Un tramo del borrador en vivo, con su momento dentro de la grabación (en segundos).
class SegmentoEnVivo {
  const SegmentoEnVivo({required this.desdeSeg, required this.hastaSeg, required this.texto});

  final double desdeSeg;
  final double hastaSeg;
  final String texto;

  Map<String, dynamic> toJson() => {
        'desde_seg': _redondear(desdeSeg),
        'hasta_seg': _redondear(hastaSeg),
        'texto': texto,
      };

  factory SegmentoEnVivo.fromJson(Map<String, dynamic> j) => SegmentoEnVivo(
        desdeSeg: (j['desde_seg'] as num?)?.toDouble() ?? 0,
        hastaSeg: (j['hasta_seg'] as num?)?.toDouble() ?? 0,
        texto: (j['texto'] ?? '').toString(),
      );

  static double _redondear(double v) => (v * 100).round() / 100;
}

/// Lo que se ve mientras se graba: el contrato que leen la interfaz, la consola y el
/// endpoint local. Vive en `en-vivo.json`, en la carpeta de datos de la app.
///
/// **Es un borrador.** La transcripción buena sigue saliendo al terminar, igual que
/// antes; esto solo existe para ver y consultar la reunión mientras ocurre.
class EstadoEnVivo {
  const EstadoEnVivo({
    required this.idGrabacion,
    required this.inicio,
    required this.activa,
    required this.ultimaActualizacion,
    required this.modelo,
    required this.trozoSeg,
    this.rezagoSeg = 0,
    this.finalizando = false,
    this.descartadoSeg = 0,
    this.aviso,
    this.segmentos = const [],
  });

  /// Id de la grabación en curso (el mismo con que queda en la cola al terminar).
  final String idGrabacion;
  final DateTime inicio;

  /// `true` mientras se graba (y mientras se vacía lo último que quedó por transcribir).
  final bool activa;
  final DateTime ultimaActualizacion;
  final String modelo;
  final int trozoSeg;

  /// Cuántos segundos de audio ya capturado todavía no tienen texto. Si crece sin parar,
  /// el equipo no da abasto con este modelo: conviene uno más chico o un trozo más largo.
  final double rezagoSeg;

  /// La grabación ya se detuvo y falta sacar el último trozo.
  final bool finalizando;

  /// Audio que se saltó el borrador para no quedar cada vez más atrás.
  final double descartadoSeg;

  /// Algo que el lector debería saber (la fuente falló, se perdió un tramo, etc.).
  final String? aviso;
  final List<SegmentoEnVivo> segmentos;

  String get texto => segmentos.map((s) => s.texto.trim()).where((t) => t.isNotEmpty).join(' ');

  EstadoEnVivo copiarCon({
    bool? activa,
    DateTime? ultimaActualizacion,
    double? rezagoSeg,
    bool? finalizando,
    double? descartadoSeg,
    String? aviso,
    List<SegmentoEnVivo>? segmentos,
  }) =>
      EstadoEnVivo(
        idGrabacion: idGrabacion,
        inicio: inicio,
        activa: activa ?? this.activa,
        ultimaActualizacion: ultimaActualizacion ?? this.ultimaActualizacion,
        modelo: modelo,
        trozoSeg: trozoSeg,
        rezagoSeg: rezagoSeg ?? this.rezagoSeg,
        finalizando: finalizando ?? this.finalizando,
        descartadoSeg: descartadoSeg ?? this.descartadoSeg,
        aviso: aviso ?? this.aviso,
        segmentos: segmentos ?? this.segmentos,
      );

  Map<String, dynamic> toJson() => {
        'id_grabacion': idGrabacion,
        'inicio': inicio.toUtc().toIso8601String(),
        'activa': activa,
        'finalizando': finalizando,
        'ultima_actualizacion': ultimaActualizacion.toUtc().toIso8601String(),
        'modelo': modelo,
        'trozo_seg': trozoSeg,
        'rezago_seg': (rezagoSeg * 10).round() / 10,
        'descartado_seg': (descartadoSeg * 10).round() / 10,
        'borrador': true,
        if (aviso != null) 'aviso': aviso,
        'texto': texto,
        'segmentos': [for (final s in segmentos) s.toJson()],
      };

  factory EstadoEnVivo.fromJson(Map<String, dynamic> j) => EstadoEnVivo(
        idGrabacion: (j['id_grabacion'] ?? '').toString(),
        inicio: DateTime.tryParse((j['inicio'] ?? '').toString()) ?? DateTime.fromMillisecondsSinceEpoch(0),
        activa: j['activa'] == true,
        finalizando: j['finalizando'] == true,
        ultimaActualizacion: DateTime.tryParse((j['ultima_actualizacion'] ?? '').toString()) ??
            DateTime.fromMillisecondsSinceEpoch(0),
        modelo: (j['modelo'] ?? '').toString(),
        trozoSeg: (j['trozo_seg'] as num?)?.toInt() ?? 0,
        rezagoSeg: (j['rezago_seg'] as num?)?.toDouble() ?? 0,
        descartadoSeg: (j['descartado_seg'] as num?)?.toDouble() ?? 0,
        aviso: j['aviso']?.toString(),
        segmentos: [
          for (final s in (j['segmentos'] as List? ?? const []))
            SegmentoEnVivo.fromJson(Map<String, dynamic>.from(s as Map)),
        ],
      );
}

/// El archivo `en-vivo.json`: escritura atómica y lectura tolerante.
class ArchivoEnVivo {
  ArchivoEnVivo({this.carpeta});

  /// Para tests. Sin esto, la carpeta de datos de la app ([DatosApp.carpeta]).
  final Directory? carpeta;

  static const nombre = 'en-vivo.json';

  Future<File> _archivo() async {
    final dir = carpeta ?? await DatosApp.carpeta();
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}$nombre');
  }

  /// Escribe a un temporal y lo renombra encima: un lector nunca ve un JSON a medias.
  ///
  /// En Windows el renombre falla si justo alguien tiene el destino abierto, así que se
  /// reintenta unas veces y, si no hay caso, se escribe directo. **No lanza**: que el
  /// borrador no se pueda guardar no puede afectar la grabación.
  Future<bool> escribir(EstadoEnVivo estado) async {
    try {
      final f = await _archivo();
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(estado.toJson()), flush: true);
      for (var i = 0; i < 5; i++) {
        try {
          await tmp.rename(f.path);
          return true;
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
      }
      await f.writeAsString(jsonEncode(estado.toJson()), flush: true);
      try {
        await tmp.delete();
      } catch (_) {}
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Lee el estado. `null` si no hay archivo o no se pudo interpretar.
  Future<EstadoEnVivo?> leer() async {
    for (var intento = 0; intento < 3; intento++) {
      try {
        final f = await _archivo();
        if (!await f.exists()) return null;
        final raw = await f.readAsString();
        return EstadoEnVivo.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
      } on FormatException {
        // Pudo agarrarse justo en el reemplazo (fallback de escritura directa).
        await Future<void>.delayed(const Duration(milliseconds: 60));
      } catch (_) {
        return null;
      }
    }
    return null;
  }
}

/// ¿El estado describe una grabación que de verdad sigue en curso?
///
/// Un `activa: true` que lleva rato sin actualizarse es el rastro de una app que se cerró
/// o se cayó: no debe hacerse pasar por una reunión viva. Se tolera el doble del trozo
/// (más un margen) porque entre actualizaciones pasa, como mínimo, un trozo entero.
bool estaVigente(EstadoEnVivo e, {DateTime? ahora}) {
  if (!e.activa) return false;
  final edad = (ahora ?? DateTime.now()).difference(e.ultimaActualizacion).inSeconds;
  final tolerancia = (e.trozoSeg * 3).clamp(45, 600);
  return edad <= tolerancia;
}
