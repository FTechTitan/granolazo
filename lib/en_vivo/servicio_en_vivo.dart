import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'estado_en_vivo.dart';
import 'motor_en_vivo.dart';
import 'pcm.dart';

/// Transcripción en vivo (borrador) mientras se graba.
///
/// Recibe el audio como PCM16 mono de 16 kHz, lo junta en trozos de unos [trozoSeg]
/// segundos, los pasa de a uno por el [MotorEnVivo] y va acumulando los segmentos con su
/// hora relativa al inicio. Cada cambio queda en `en-vivo.json` (escritura atómica).
///
/// **Nunca debe afectar la grabación.** Todo error del motor, del disco o de la fuente de
/// audio se anota en `aviso` y se sigue; nada se propaga a quien grabó.
///
/// **Sin cola infinita.** Mientras el motor trabaja en un trozo, el audio nuevo se junta
/// en un solo pendiente. Si el motor se atrasa, el próximo trozo sale más largo (hasta
/// [maxTrozosJuntos] trozos); pasado eso se descarta lo más viejo y se cuenta en
/// `descartado_seg`. `rezago_seg` dice cuánto audio capturado todavía no tiene texto.
class ServicioEnVivo {
  ServicioEnVivo({
    required this.motor,
    required this.archivo,
    required this.modelo,
    this.trozoSeg = 20,
    this.idioma = 'es',
    this.maxTrozosJuntos = 3,
    this.minimoSeg = 1.5,
    this.umbralSilencioDb = -58,
    this.latido = const Duration(seconds: 5),
    this.carpetaTemporal,
    DateTime Function()? ahora,
  }) : _ahora = ahora ?? DateTime.now;

  final MotorEnVivo motor;
  final ArchivoEnVivo archivo;
  final String modelo;
  final int trozoSeg;
  final String idioma;
  final int maxTrozosJuntos;

  /// Trozos más cortos que esto no se mandan al motor: no dicen nada.
  final double minimoSeg;

  /// Un trozo por debajo de este nivel RMS es silencio: no se gasta CPU en él (y de paso
  /// se evita que el modelo invente texto sobre el silencio).
  final double umbralSilencioDb;

  /// Cada cuánto se reescribe el estado aunque no haya texto nuevo, para que quien lo
  /// lea sepa que la grabación sigue viva y cuánto rezago hay.
  final Duration latido;

  /// Dónde se escriben los WAV temporales de cada trozo (por defecto, la temporal del sistema).
  final Directory? carpetaTemporal;
  final DateTime Function() _ahora;

  EstadoEnVivo? _estado;
  StreamSubscription<Uint8List>? _sub;
  Timer? _timerLatido;
  final _cambios = StreamController<EstadoEnVivo>.broadcast();

  final BytesBuilder _pendiente = BytesBuilder();
  int _byteSobrante = -1;
  double _inicioPendienteSeg = 0;
  double _capturadoSeg = 0;
  double _finProcesadoSeg = 0;
  double _descartadoSeg = 0;
  bool _ocupado = false;
  bool _detenido = false;
  Future<void>? _trabajoActual;
  int _trozosProcesados = 0;
  int _fallosSeguidos = 0;
  String? _aviso;

  /// Último estado publicado, o `null` si todavía no se inició.
  EstadoEnVivo? get estado => _estado;
  Stream<EstadoEnVivo> get cambios => _cambios.stream;
  bool get activo => _estado?.activa ?? false;

  /// Cuántos trozos pasaron por el motor (los silenciosos no cuentan).
  int get trozosProcesados => _trozosProcesados;

  Future<void> iniciar({
    required String idGrabacion,
    required Stream<Uint8List> pcm,
    DateTime? inicio,
  }) async {
    if (_estado != null) throw StateError('la transcripción en vivo ya se inició');
    final ahora = _ahora();
    _estado = EstadoEnVivo(
      idGrabacion: idGrabacion,
      inicio: inicio ?? ahora,
      activa: true,
      ultimaActualizacion: ahora,
      modelo: modelo,
      trozoSeg: trozoSeg,
    );
    await _publicar();
    _sub = pcm.listen(
      _alLlegarAudio,
      onError: (Object e) {
        _aviso = 'la fuente de audio falló: $e';
        unawaited(_publicar());
      },
    );
    _timerLatido = Timer.periodic(latido, (_) => unawaited(_publicar()));
  }

  void _alLlegarAudio(Uint8List datos) {
    if (_detenido) return;
    var bytes = datos;
    if (_byteSobrante >= 0) {
      // Un muestreo de 16 bits partido entre dos paquetes: se recompone.
      final b = BytesBuilder()
        ..addByte(_byteSobrante)
        ..add(bytes);
      bytes = b.takeBytes();
      _byteSobrante = -1;
    }
    if (bytes.length.isOdd) {
      _byteSobrante = bytes.last;
      bytes = Uint8List.sublistView(bytes, 0, bytes.length - 1);
    }
    if (bytes.isEmpty) return;
    _pendiente.add(bytes);
    _capturadoSeg += bytes.length / Pcm.bytesPorSegundo;
    _intentarProcesar();
  }

  double get _pendienteSeg => _pendiente.length / Pcm.bytesPorSegundo;

  void _intentarProcesar({bool vaciar = false}) {
    if (_ocupado) return;
    final seg = _pendienteSeg;
    if (seg < (vaciar ? minimoSeg : trozoSeg.toDouble())) return;

    var bytes = _pendiente.takeBytes();
    var desde = _inicioPendienteSeg;
    final tope = (trozoSeg * maxTrozosJuntos) * Pcm.bytesPorSegundo;
    if (bytes.length > tope) {
      final sobra = bytes.length - tope;
      _descartadoSeg += sobra / Pcm.bytesPorSegundo;
      desde += sobra / Pcm.bytesPorSegundo;
      bytes = Uint8List.sublistView(bytes, sobra);
    }
    _inicioPendienteSeg = desde + bytes.length / Pcm.bytesPorSegundo;
    _ocupado = true;
    _trabajoActual = _procesar(bytes, desde).whenComplete(() {
      _ocupado = false;
      _trabajoActual = null;
      if (!_detenido) _intentarProcesar();
    });
  }

  Future<void> _procesar(Uint8List bytes, double desdeSeg) async {
    final duracion = bytes.length / Pcm.bytesPorSegundo;
    try {
      if (Pcm.rmsDbfs(bytes) > umbralSilencioDb) {
        final nuevos = await _transcribir(bytes, desdeSeg);
        _trozosProcesados++;
        _fallosSeguidos = 0;
        if (nuevos.isNotEmpty) {
          _estado = _estado!.copiarCon(segmentos: [..._estado!.segmentos, ...nuevos]);
        }
      }
    } catch (e) {
      _fallosSeguidos++;
      _aviso = 'un tramo del borrador no se pudo transcribir ($e)';
    } finally {
      _finProcesadoSeg = desdeSeg + duracion;
      await _publicar();
    }
  }

  Future<List<SegmentoEnVivo>> _transcribir(Uint8List bytes, double desdeSeg) async {
    final dir = carpetaTemporal ?? Directory.systemTemp;
    final wav = File('${dir.path}${Platform.pathSeparator}'
        'granolazo-envivo-${_estado!.idGrabacion}-${_trozosProcesados + 1}.wav');
    try {
      await wav.writeAsBytes(Pcm.aWav(bytes), flush: true);
      final crudos = await motor.transcribir(wav, idioma: idioma);
      return [
        for (final s in crudos)
          if (_esHabla(s.texto))
            SegmentoEnVivo(
              desdeSeg: desdeSeg + s.desdeSeg,
              hastaSeg: desdeSeg + s.hastaSeg,
              texto: s.texto.trim(),
            ),
      ];
    } finally {
      // El conversor de la librería deja un `.wav.wav` al lado: también se limpia.
      for (final f in [wav, File('${wav.path}.wav')]) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
  }

  /// Whisper responde `[BLANK_AUDIO]`, `(música)`, `♪` y similares sobre lo que no es
  /// voz. No son texto de la reunión.
  static bool _esHabla(String t) {
    final s = t.trim();
    if (s.isEmpty) return false;
    if (RegExp(r'^[\[\(\*].*[\]\)\*]$').hasMatch(s)) return false;
    if (RegExp(r'^[♪♫\s\.\-–—…]+$').hasMatch(s)) return false;
    return true;
  }

  Future<void> _publicar({bool? activa, bool? finalizando}) async {
    final e = _estado;
    if (e == null) return;
    final rezago = (_capturadoSeg - _finProcesadoSeg).clamp(0.0, double.infinity);
    _estado = e.copiarCon(
      ultimaActualizacion: _ahora(),
      rezagoSeg: rezago,
      descartadoSeg: _descartadoSeg,
      aviso: _aviso,
      activa: activa,
      finalizando: finalizando,
    );
    await archivo.escribir(_estado!);
    if (!_cambios.isClosed) _cambios.add(_estado!);
  }

  /// Corta la captura y deja el estado final (`activa: false`).
  ///
  /// Con [vaciar] saca el texto de lo último que quedó sin transcribir, esperando como
  /// mucho [esperaMax]; pasado ese tiempo se cierra igual. La grabación ya terminó para
  /// quien llama: esto solo completa el borrador.
  Future<void> detener({bool vaciar = true, Duration esperaMax = const Duration(seconds: 90)}) async {
    if (_estado == null || _detenido) return;
    _detenido = true;
    await _sub?.cancel();
    _sub = null;
    _timerLatido?.cancel();
    _timerLatido = null;
    await _publicar(finalizando: true);
    try {
      await (() async {
        await _trabajoActual;
        if (vaciar && _pendienteSeg >= minimoSeg) {
          _intentarProcesar(vaciar: true);
          await _trabajoActual;
        }
      })()
          .timeout(esperaMax);
    } on TimeoutException {
      _aviso = 'el último tramo no alcanzó a transcribirse';
    } catch (_) {
      // El borrador no puede romper el cierre de la grabación.
    }
    await _publicar(activa: false, finalizando: false);
    await motor.liberar();
    await _cambios.close();
  }

  /// Termina sin esperar nada (la grabación se descartó).
  Future<void> cancelar() => detener(vaciar: false, esperaMax: const Duration(seconds: 5));

  int get fallosSeguidos => _fallosSeguidos;
}
