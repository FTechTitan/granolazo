import 'dart:async';
import 'dart:convert';

import 'estado_en_vivo.dart';

/// `granolazo en-vivo`: lee el borrador de la grabación en curso desde otro proceso.
///
/// Códigos de salida: **0** hay una grabación en vivo y se mostró; **3** no hay ninguna
/// en curso (no existe el archivo, ya terminó, o quedó de una sesión que se cortó);
/// **1** no se pudo leer. Con `--json` siempre responde una línea de JSON, también en el
/// caso 3, para que un agente pueda decidir sin interpretar texto.
class ComandoEnVivo {
  ComandoEnVivo({
    required this.archivo,
    required this.escribir,
    this.json = false,
    DateTime Function()? ahora,
    this.sondeo = const Duration(seconds: 1),
  }) : _ahora = ahora ?? DateTime.now;

  final ArchivoEnVivo archivo;
  final void Function(String linea) escribir;
  final bool json;
  final Duration sondeo;
  final DateTime Function() _ahora;

  static const salidaSinGrabacion = 3;

  Future<int> ejecutar({bool seguir = false, bool ultima = false}) async {
    final e = await archivo.leer();
    if (ultima) {
      // La última sesión que dejó texto, aunque ya haya terminado.
      if (e == null) return _sinGrabacion(null, 'todavía no hubo ninguna grabación con transcripción en vivo');
      _mostrar(e);
      return 0;
    }
    if (e == null) {
      return _sinGrabacion(null, 'no hay ninguna grabación con transcripción en vivo');
    }
    if (!estaVigente(e, ahora: _ahora())) {
      return _sinGrabacion(
        e,
        e.activa
            ? 'la última grabación en vivo dejó de actualizarse (la app se cerró o se cayó)'
            : 'no hay una grabación en curso; la última ya terminó (granolazo en-vivo --ultima la muestra)',
      );
    }
    if (!seguir) {
      _mostrar(e);
      return 0;
    }
    return _seguir(e);
  }

  int _sinGrabacion(EstadoEnVivo? e, String motivo) {
    if (json) {
      escribir(jsonEncode({
        'activa': false,
        'motivo': motivo,
        if (e != null) 'ultima_grabacion': e.idGrabacion,
        if (e != null) 'ultima_actualizacion': e.ultimaActualizacion.toUtc().toIso8601String(),
      }));
    } else {
      escribir('sin transcripción en vivo en curso: $motivo');
    }
    return salidaSinGrabacion;
  }

  void _mostrar(EstadoEnVivo e) {
    if (json) {
      escribir(jsonEncode(e.toJson()));
      return;
    }
    escribir(_encabezado(e));
    for (final s in e.segmentos) {
      escribir('${_marca(s.desdeSeg)} ${s.texto}');
    }
  }

  String _encabezado(EstadoEnVivo e) {
    final estado = e.activa ? (e.finalizando ? 'terminando' : 'en curso') : 'terminada';
    return 'BORRADOR en vivo · grabación ${e.idGrabacion} · $estado · modelo ${e.modelo} · '
        'trozos de ${e.trozoSeg} s · rezago ${e.rezagoSeg.toStringAsFixed(1)} s'
        '${e.aviso != null ? " · aviso: ${e.aviso}" : ""}';
  }

  static String _marca(double seg) {
    final t = seg.floor();
    final h = t ~/ 3600;
    final m = ((t % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (t % 60).toString().padLeft(2, '0');
    return '[${h > 0 ? "$h:" : ""}$m:$s]';
  }

  /// Muestra el texto nuevo a medida que aparece, hasta que la grabación termina.
  Future<int> _seguir(EstadoEnVivo primero) async {
    var visto = 0;
    var actual = primero;
    if (!json) escribir(_encabezado(actual));
    while (true) {
      for (var i = visto; i < actual.segmentos.length; i++) {
        final s = actual.segmentos[i];
        escribir(json ? jsonEncode({'segmento': s.toJson()}) : '${_marca(s.desdeSeg)} ${s.texto}');
      }
      visto = actual.segmentos.length;
      if (!actual.activa || !estaVigente(actual, ahora: _ahora())) break;
      await Future<void>.delayed(sondeo);
      final nuevo = await archivo.leer();
      if (nuevo == null || nuevo.idGrabacion != actual.idGrabacion) break;
      actual = nuevo;
    }
    escribir(json
        ? jsonEncode({'fin': true, 'id_grabacion': actual.idGrabacion, 'segmentos': visto})
        : '— fin del borrador (${actual.idGrabacion}) —');
    return 0;
  }
}
