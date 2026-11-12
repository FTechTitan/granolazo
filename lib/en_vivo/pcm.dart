import 'dart:math' as math;
import 'dart:typed_data';

/// Utilidades de audio PCM para la transcripción en vivo. Todo el borrador trabaja en
/// 16 kHz, mono, 16 bits: el formato que come whisper.cpp.
abstract final class Pcm {
  static const int tasa = 16000;
  static const int bytesPorSegundo = tasa * 2;

  /// Envuelve PCM16 mono de 16 kHz en un WAV completo (cabecera de 44 bytes).
  static Uint8List aWav(Uint8List pcm, {int tasaHz = tasa}) {
    final out = BytesBuilder(copy: false);
    final cab = ByteData(44);
    void texto(int off, String s) {
      for (var i = 0; i < s.length; i++) {
        cab.setUint8(off + i, s.codeUnitAt(i));
      }
    }

    texto(0, 'RIFF');
    cab.setUint32(4, 36 + pcm.length, Endian.little);
    texto(8, 'WAVE');
    texto(12, 'fmt ');
    cab.setUint32(16, 16, Endian.little);
    cab.setUint16(20, 1, Endian.little); // PCM
    cab.setUint16(22, 1, Endian.little); // mono
    cab.setUint32(24, tasaHz, Endian.little);
    cab.setUint32(28, tasaHz * 2, Endian.little);
    cab.setUint16(32, 2, Endian.little);
    cab.setUint16(34, 16, Endian.little);
    texto(36, 'data');
    cab.setUint32(40, pcm.length, Endian.little);
    out.add(cab.buffer.asUint8List());
    out.add(pcm);
    return out.takeBytes();
  }

  /// Nivel RMS en dBFS (0 = máximo, negativo hacia el silencio). -160 si no hay muestras.
  static double rmsDbfs(Uint8List pcm) {
    final n = pcm.length ~/ 2;
    if (n == 0) return -160;
    final bd = ByteData.sublistView(pcm);
    var suma = 0.0;
    for (var i = 0; i < n; i++) {
      final v = bd.getInt16(i * 2, Endian.little) / 32768.0;
      suma += v * v;
    }
    final rms = math.sqrt(suma / n);
    return rms <= 0 ? -160 : 20 * (math.log(rms) / math.ln10);
  }

  /// Suma dos pistas PCM16 mono (con tope, sin desbordar). La más corta se completa con
  /// silencio.
  static Uint8List mezclar(Uint8List a, Uint8List b) {
    final largo = math.max(a.length, b.length) ~/ 2;
    final out = Uint8List(largo * 2);
    final bo = ByteData.sublistView(out);
    final ba = ByteData.sublistView(a);
    final bb = ByteData.sublistView(b);
    for (var i = 0; i < largo; i++) {
      final x = i * 2 + 1 < a.length ? ba.getInt16(i * 2, Endian.little) : 0;
      final y = i * 2 + 1 < b.length ? bb.getInt16(i * 2, Endian.little) : 0;
      bo.setInt16(i * 2, (x + y).clamp(-32768, 32767), Endian.little);
    }
    return out;
  }

  /// Genera [segundos] de silencio PCM16.
  static Uint8List silencio(double segundos) => Uint8List((segundos * bytesPorSegundo).round() & ~1);
}

/// Lo que dice la cabecera de un WAV.
class CabeceraWav {
  const CabeceraWav({
    required this.flotante,
    required this.canales,
    required this.tasaHz,
    required this.bits,
    required this.inicioDatos,
  });

  final bool flotante;
  final int canales;
  final int tasaHz;
  final int bits;

  /// Byte donde empiezan las muestras.
  final int inicioDatos;

  int get bytesPorCuadro => canales * (bits ~/ 8);

  /// Lee la cabecera buscando el chunk `data` (no asume 44 bytes). `null` si no es un
  /// WAV reconocible o todavía no se escribió la cabecera entera.
  ///
  /// Un WAV que se está escribiendo tiene los tamaños en cero; por eso el chunk `data`
  /// no se valida contra su largo declarado.
  static CabeceraWav? leer(Uint8List b) {
    if (b.length < 44) return null;
    String tag(int o) => String.fromCharCodes(b.sublist(o, o + 4));
    if (tag(0) != 'RIFF' || tag(8) != 'WAVE') return null;
    final bd = ByteData.sublistView(b);
    int? formato, canales, tasa, bits;
    var pos = 12;
    while (pos + 8 <= b.length) {
      final id = tag(pos);
      final tam = bd.getUint32(pos + 4, Endian.little);
      if (id == 'fmt ' && pos + 8 + 16 <= b.length) {
        formato = bd.getUint16(pos + 8, Endian.little);
        canales = bd.getUint16(pos + 10, Endian.little);
        tasa = bd.getUint32(pos + 12, Endian.little);
        bits = bd.getUint16(pos + 22, Endian.little);
        if (formato == 0xFFFE && tam >= 40 && pos + 8 + 26 <= b.length) {
          // WAVE_FORMAT_EXTENSIBLE: el formato real va en el subformato.
          formato = bd.getUint16(pos + 8 + 24, Endian.little);
        }
      } else if (id == 'data') {
        if (formato == null || canales == null || tasa == null || bits == null) return null;
        if (canales < 1 || (bits != 16 && bits != 32 && bits != 8 && bits != 24)) return null;
        return CabeceraWav(
          flotante: formato == 3,
          canales: canales,
          tasaHz: tasa,
          bits: bits,
          inicioDatos: pos + 8,
        );
      }
      pos += 8 + tam + (tam.isOdd ? 1 : 0);
    }
    return null;
  }
}

/// Convierte audio de cualquier WAV común (estéreo, 44,1/48 kHz, float o entero) a mono
/// 16 kHz PCM16, de a pedazos y sin perder el resto de un cuadro partido entre dos
/// lecturas. Promedia las muestras de cada ventana en vez de saltarlas, que es un
/// remuestreo grosero pero sobra para un borrador de voz.
class ConversorAMono16k {
  ConversorAMono16k(this.cabecera);

  final CabeceraWav cabecera;
  final BytesBuilder _resto = BytesBuilder();
  double _suma = 0;
  int _cuenta = 0;
  int _fase = 0;

  /// Convierte [datos] (muestras crudas, sin cabecera) y devuelve PCM16 mono de 16 kHz.
  Uint8List convertir(Uint8List datos) {
    _resto.add(datos);
    final todo = _resto.takeBytes();
    final cuadro = cabecera.bytesPorCuadro;
    final cuadros = todo.length ~/ cuadro;
    final usados = cuadros * cuadro;
    if (usados < todo.length) _resto.add(Uint8List.sublistView(todo, usados));

    final bd = ByteData.sublistView(todo);
    final salida = BytesBuilder(copy: false);
    final tmp = ByteData(2);
    final tasaIn = cabecera.tasaHz;
    final bytesMuestra = cabecera.bits ~/ 8;

    for (var c = 0; c < cuadros; c++) {
      var m = 0.0;
      for (var ch = 0; ch < cabecera.canales; ch++) {
        final o = c * cuadro + ch * bytesMuestra;
        m += _muestra(bd, o);
      }
      m /= cabecera.canales;
      if (tasaIn <= Pcm.tasa) {
        // Sin remuestreo hacia arriba: se deja pasar (un equipo con salida a 16 kHz o
        // menos no existe en la práctica; la prueba sintética ya viene a 16 kHz).
        tmp.setInt16(0, (m * 32767).round().clamp(-32768, 32767), Endian.little);
        salida.add(tmp.buffer.asUint8List(0, 2).sublist(0));
        continue;
      }
      _suma += m;
      _cuenta++;
      _fase += Pcm.tasa;
      if (_fase >= tasaIn) {
        _fase -= tasaIn;
        final prom = _suma / _cuenta;
        tmp.setInt16(0, (prom * 32767).round().clamp(-32768, 32767), Endian.little);
        salida.add(tmp.buffer.asUint8List(0, 2).sublist(0));
        _suma = 0;
        _cuenta = 0;
      }
    }
    return salida.takeBytes();
  }

  /// Una muestra normalizada a -1..1.
  double _muestra(ByteData bd, int o) {
    switch (cabecera.bits) {
      case 8:
        return (bd.getUint8(o) - 128) / 128.0;
      case 16:
        return bd.getInt16(o, Endian.little) / 32768.0;
      case 24:
        final v = bd.getUint8(o) | (bd.getUint8(o + 1) << 8) | (bd.getInt8(o + 2) << 16);
        return v / 8388608.0;
      case 32:
        return cabecera.flotante
            ? bd.getFloat32(o, Endian.little).clamp(-1.0, 1.0)
            : bd.getInt32(o, Endian.little) / 2147483648.0;
    }
    return 0;
  }
}
