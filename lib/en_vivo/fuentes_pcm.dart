import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:record/record.dart';

import 'pcm.dart';

/// De dónde sale el audio del borrador en vivo: PCM16 mono de 16 kHz en paquetes.
abstract class FuentePcm {
  Stream<Uint8List> get pcm;

  /// Si la fuente tuvo que degradarse (por ejemplo, sin micrófono), el motivo.
  String? get aviso;

  Future<void> abrir();
  Future<void> cerrar();
}

/// Cola de bytes de la que se saca por delante, para alinear dos pistas.
class ColaBytes {
  Uint8List _buf = Uint8List(0);

  int get largo => _buf.length;

  void agregar(Uint8List b) {
    if (b.isEmpty) return;
    final nuevo = Uint8List(_buf.length + b.length)
      ..setRange(0, _buf.length, _buf)
      ..setRange(_buf.length, _buf.length + b.length, b);
    _buf = nuevo;
  }

  /// Saca hasta [n] bytes del frente.
  Uint8List sacar(int n) {
    final k = math.min(n, _buf.length);
    final out = Uint8List.fromList(_buf.sublist(0, k));
    _buf = Uint8List.fromList(_buf.sublist(k));
    return out;
  }

  /// Deja como mucho [max] bytes, tirando lo más viejo.
  void recortarA(int max) {
    if (_buf.length > max) _buf = Uint8List.fromList(_buf.sublist(_buf.length - max));
  }
}

/// El micrófono como flujo PCM, con el audio del equipo mezclado cuando se está
/// capturando.
///
/// Abre un **segundo** grabador del micrófono, solo para el borrador: el que escribe el
/// archivo de la grabación real no se toca. Si el segundo no puede abrirse (o falla), la
/// grabación sigue igual; el borrador se queda sin voz propia y lo dice en [aviso].
///
/// El audio del equipo (lo que dice el otro en una llamada) no sale en un flujo: la parte
/// nativa lo va escribiendo a un WAV. Acá se lee ese archivo a medida que crece, se pasa a
/// mono 16 kHz y se suma al micrófono. Es un borrador, así que la alineación entre las dos
/// pistas es aproximada (cuestión de décimas de segundo).
class FuenteMicrofonoYSistema implements FuentePcm {
  FuenteMicrofonoYSistema({this.rutaSistema});

  /// Ruta del WAV del audio del equipo mientras se graba, o `null` si no se captura.
  /// Es una función para poder preguntarlo después de que la captura arrancó.
  final String? Function()? rutaSistema;

  final AudioRecorder _rec = AudioRecorder();
  final StreamController<Uint8List> _salida = StreamController<Uint8List>();
  StreamSubscription<Uint8List>? _subMic;
  Timer? _timerBase;
  Timer? _timerSistema;
  final ColaBytes _colaSistema = ColaBytes();
  String? _aviso;

  RandomAccessFile? _lectorSistema;
  ConversorAMono16k? _conversor;
  int _offsetSistema = 0;
  bool _leyendoSistema = false;

  @override
  Stream<Uint8List> get pcm => _salida.stream;

  @override
  String? get aviso => _aviso;

  @override
  Future<void> abrir() async {
    try {
      final flujo = await _rec.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: Pcm.tasa,
        numChannels: 1,
      ));
      _subMic = flujo.listen(_alMicrofono, onError: (Object e) {
        _aviso = 'el micrófono del borrador falló: $e';
      });
    } catch (e) {
      _aviso = 'el borrador no pudo abrir el micrófono ($e); la grabación sigue normal';
      // Sin micrófono se sigue al ritmo de un reloj, para que el audio del equipo, si
      // existe, igual llegue.
      _timerBase = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => _alMicrofono(Pcm.silencio(0.1)),
      );
    }
    if (rutaSistema != null) {
      _timerSistema = Timer.periodic(const Duration(milliseconds: 250), (_) => _leerSistema());
    }
  }

  void _alMicrofono(Uint8List mic) {
    if (_salida.isClosed) return;
    final sis = _colaSistema.sacar(mic.length);
    _salida.add(sis.isEmpty ? mic : Pcm.mezclar(mic, sis));
  }

  Future<void> _leerSistema() async {
    if (_leyendoSistema || _salida.isClosed) return;
    final ruta = rutaSistema?.call();
    if (ruta == null) return;
    _leyendoSistema = true;
    try {
      _lectorSistema ??= await File(ruta).open();
      final lector = _lectorSistema!;
      if (_conversor == null) {
        await lector.setPosition(0);
        final cab = await lector.read(4096);
        final c = CabeceraWav.leer(Uint8List.fromList(cab));
        if (c == null) return; // La cabecera todavía no está escrita.
        _conversor = ConversorAMono16k(c);
        _offsetSistema = c.inicioDatos;
      }
      await lector.setPosition(_offsetSistema);
      final nuevos = await lector.read(1 << 20);
      if (nuevos.isEmpty) return;
      _offsetSistema += nuevos.length;
      _colaSistema.agregar(_conversor!.convertir(Uint8List.fromList(nuevos)));
      // Más de ~1,5 s acumulados quiere decir que el micrófono se retrasó: se tira lo
      // viejo para no ir desfasado.
      _colaSistema.recortarA(Pcm.bytesPorSegundo * 3 ~/ 2);
    } catch (e) {
      _aviso = 'el borrador no pudo leer el audio del equipo ($e)';
      _timerSistema?.cancel();
      _timerSistema = null;
    } finally {
      _leyendoSistema = false;
    }
  }

  @override
  Future<void> cerrar() async {
    _timerBase?.cancel();
    _timerSistema?.cancel();
    await _subMic?.cancel();
    try {
      await _rec.stop();
    } catch (_) {}
    try {
      await _rec.dispose();
    } catch (_) {}
    await _lectorSistema?.close();
    _lectorSistema = null;
    if (!_salida.isClosed) await _salida.close();
  }
}

/// Reproduce un WAV de 16 kHz mono PCM16 como si fuera el micrófono, a velocidad real.
///
/// **Es el modo de prueba**: sirve para ensayar el borrador sin micrófono y con una voz
/// conocida. No se usa en la operación normal (se activa a propósito con
/// `GRANOLAZO_EN_VIVO_WAV` o con el comando `en-vivo-prueba`).
class FuenteWavPrueba implements FuentePcm {
  FuenteWavPrueba(this.archivo, {this.velocidad = 1.0, this.paso = const Duration(milliseconds: 100)});

  final File archivo;

  /// 1 = tiempo real. Mayor, más rápido que el tiempo real.
  final double velocidad;
  final Duration paso;

  final StreamController<Uint8List> _salida = StreamController<Uint8List>();
  Timer? _timer;
  String? _aviso;

  @override
  Stream<Uint8List> get pcm => _salida.stream;

  @override
  String? get aviso => _aviso;

  @override
  Future<void> abrir() async {
    final bytes = await archivo.readAsBytes();
    final cab = CabeceraWav.leer(bytes);
    if (cab == null || cab.tasaHz != Pcm.tasa || cab.canales != 1 || cab.bits != 16 || cab.flotante) {
      throw StateError('el WAV de prueba debe ser PCM 16 bits, mono, 16 kHz');
    }
    final datos = Uint8List.sublistView(bytes, cab.inicioDatos);
    final porPaso = (Pcm.bytesPorSegundo * paso.inMilliseconds / 1000 * velocidad).round() & ~1;
    var pos = 0;
    _timer = Timer.periodic(paso, (t) {
      if (_salida.isClosed) return t.cancel();
      if (pos >= datos.length) {
        t.cancel();
        _aviso = 'se acabó el audio de prueba';
        return;
      }
      final fin = math.min(pos + porPaso, datos.length);
      _salida.add(Uint8List.sublistView(datos, pos, fin));
      pos = fin;
    });
  }

  @override
  Future<void> cerrar() async {
    _timer?.cancel();
    if (!_salida.isClosed) await _salida.close();
  }
}
