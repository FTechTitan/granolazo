import 'dart:convert';
import 'dart:io';

import '../models/grabacion.dart';
import 'datos_app.dart';

/// Guarda la lista de grabaciones en disco.
///
/// Existe para que una grabación no se pierda si la app se cierra antes de transcribir o
/// subir: al volver a abrir, la cola sigue ahí y se puede reintentar. Es el mismo criterio
/// que usan los workers con sus archivos de control.
class RepositorioGrabaciones {
  static const _nombreArchivo = 'grabaciones.json';

  Future<File> _archivo() async {
    final base = await DatosApp.carpeta();
    return File('${base.path}${Platform.pathSeparator}$_nombreArchivo');
  }

  Future<List<Grabacion>> cargar() async {
    try {
      final f = await _archivo();
      if (!await f.exists()) return const [];
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return const [];
      return Grabacion.listaDesdeJson(raw);
    } on FormatException {
      // Un archivo corrupto no puede dejar la app inservible: se descarta y se sigue.
      return const [];
    } catch (_) {
      return const [];
    }
  }

  Future<void> guardar(List<Grabacion> items) async {
    final f = await _archivo();
    // Escritura atómica: primero a un temporal y después se reemplaza, para no dejar un
    // JSON a medio escribir si el proceso muere en el medio.
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(Grabacion.listaAJson(items), flush: true);
    await tmp.rename(f.path);
  }

  /// Borra el audio del disco. La fila se conserva: interesa el registro aunque el
  /// archivo ya no esté.
  Future<void> borrarAudio(Grabacion g) async {
    final f = File(g.rutaArchivo);
    if (await f.exists()) await f.delete();
  }

  /// Espacio ocupado por los audios que siguen en el dispositivo.
  Future<int> bytesEnDisco(List<Grabacion> items) async {
    var total = 0;
    for (final g in items) {
      final f = File(g.rutaArchivo);
      if (await f.exists()) total += await f.length();
    }
    return total;
  }

  /// Exporta la transcripción a un archivo de texto junto al audio.
  Future<File?> exportarTexto(Grabacion g) async {
    // Con las marcas de tiempo: un texto exportado sin ellas pierde justamente lo que
    // permite volver al audio.
    final texto = g.textoConMarcas;
    if (texto.trim().isEmpty) return null;
    final destino = File('${g.rutaArchivo}.txt');
    final encabezado = jsonEncode({
      'titulo': g.tituloVisible,
      'grabada_en': g.grabadaEn.toUtc().toIso8601String(),
      'duracion_segundos': g.duracionSegundos,
      'item_granolazo': g.itemIdRemoto,
      'con_marcas_de_tiempo': g.hayTiempos,
    });
    await destino.writeAsString('$encabezado\n\n$texto', flush: true);
    return destino;
  }
}
