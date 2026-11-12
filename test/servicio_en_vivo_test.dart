import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:granolazo_app/en_vivo/estado_en_vivo.dart';
import 'package:granolazo_app/en_vivo/motor_en_vivo.dart';
import 'package:granolazo_app/en_vivo/pcm.dart';
import 'package:granolazo_app/en_vivo/servicio_en_vivo.dart';

/// Un motor de mentira: cada trozo "dice" lo que se le programó, tarda lo que se le diga.
class MotorFalso implements MotorEnVivo {
  MotorFalso({this.demora = Duration.zero, this.falla = false});

  Duration demora;
  bool falla;
  final trozos = <double>[]; // duración en segundos de cada trozo recibido
  final archivosVistos = <String>[];
  bool liberado = false;
  Completer<void>? compuerta;

  @override
  Future<List<SegmentoEnVivo>> transcribir(File wav, {required String idioma}) async {
    archivosVistos.add(wav.path);
    expect(wav.existsSync(), isTrue);
    final largo = wav.lengthSync() - 44;
    trozos.add(largo / Pcm.bytesPorSegundo);
    if (compuerta != null) await compuerta!.future;
    if (demora > Duration.zero) await Future<void>.delayed(demora);
    if (falla) throw StateError('motor roto');
    return [
      SegmentoEnVivo(desdeSeg: 0, hastaSeg: 2, texto: 'trozo ${trozos.length}'),
      const SegmentoEnVivo(desdeSeg: 2, hastaSeg: 3, texto: '[BLANK_AUDIO]'),
    ];
  }

  @override
  Future<void> liberar() async => liberado = true;
}

/// Audio con "voz": un tono fuerte, para que no lo tome por silencio.
Uint8List _voz(double segundos) {
  final n = (segundos * Pcm.tasa).round();
  final b = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    b.setInt16(i * 2, i.isEven ? 8000 : -8000, Endian.little);
  }
  return b.buffer.asUint8List();
}

Future<void> _soltar() => Future<void>.delayed(const Duration(milliseconds: 30));

/// Espera (hasta 3 s) a que se cumpla algo; los tests no deben depender de qué tan
/// cargado esté el equipo.
Future<void> _hasta(bool Function() cond) async {
  final limite = DateTime.now().add(const Duration(seconds: 3));
  while (!cond() && DateTime.now().isBefore(limite)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory tmp;
  late StreamController<Uint8List> audio;
  late ArchivoEnVivo archivo;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('envivo-servicio-');
    audio = StreamController<Uint8List>();
    archivo = ArchivoEnVivo(carpeta: tmp);
  });
  tearDown(() async {
    if (!audio.isClosed) await audio.close();
    tmp.deleteSync(recursive: true);
  });

  ServicioEnVivo crear(MotorFalso m, {int trozo = 10}) => ServicioEnVivo(
        motor: m,
        archivo: archivo,
        modelo: 'base',
        trozoSeg: trozo,
        carpetaTemporal: tmp,
        latido: const Duration(hours: 1),
      );

  test('corta un trozo por cada trozoSeg y acumula segmentos con su hora relativa', () async {
    final m = MotorFalso();
    final s = crear(m);
    await s.iniciar(idGrabacion: 'g1', pcm: audio.stream);
    expect((await archivo.leer())!.activa, isTrue);

    audio.add(_voz(10));
    await _hasta(() => m.trozos.length == 1 && s.estado!.segmentos.length == 1);
    audio.add(_voz(10));
    await _hasta(() => s.estado!.segmentos.length == 2);
    // El estado en memoria se actualiza un instante antes de que el archivo se escriba.
    final limite = DateTime.now().add(const Duration(seconds: 3));
    while ((await archivo.leer())?.segmentos.length != 2 && DateTime.now().isBefore(limite)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    final e = s.estado!;
    expect(m.trozos, [10.0, 10.0]);
    expect(e.segmentos.map((x) => x.texto), ['trozo 1', 'trozo 2']);
    expect(e.segmentos[1].desdeSeg, 10); // el segundo trozo arranca en el segundo 10
    expect(e.segmentos[1].hastaSeg, 12);
    expect(e.texto, 'trozo 1 trozo 2');
    expect(e.rezagoSeg, 0);
    expect((await archivo.leer())!.segmentos, hasLength(2));
    await s.detener();
  });

  test('paquetes chicos con un byte suelto no corrompen el audio', () async {
    final m = MotorFalso();
    final s = crear(m, trozo: 5);
    await s.iniciar(idGrabacion: 'g', pcm: audio.stream);
    final todo = _voz(5);
    var pos = 0;
    while (pos < todo.length) {
      final fin = (pos + 1601).clamp(0, todo.length); // largo impar a propósito
      audio.add(Uint8List.sublistView(todo, pos, fin));
      pos = fin;
    }
    await _soltar();
    expect(m.trozos, [5.0]);
    await s.detener(vaciar: false);
  });

  test('el silencio no gasta motor', () async {
    final m = MotorFalso();
    final s = crear(m);
    await s.iniciar(idGrabacion: 'g', pcm: audio.stream);
    audio.add(Pcm.silencio(10));
    await _soltar();
    expect(m.trozos, isEmpty);
    expect(s.estado!.segmentos, isEmpty);
    expect(s.estado!.rezagoSeg, 0); // el silencio igual cuenta como "atendido"
    await s.detener();
  });

  test('un solo trozo a la vez; lo que llega mientras tanto se junta en uno', () async {
    final m = MotorFalso()..compuerta = Completer<void>();
    final s = crear(m);
    await s.iniciar(idGrabacion: 'g', pcm: audio.stream);
    audio.add(_voz(10)); // arranca y queda trabado en la compuerta
    await _soltar();
    audio.add(_voz(10));
    audio.add(_voz(10));
    await _soltar();
    expect(m.trozos, [10.0], reason: 'el motor sigue ocupado: no se lanza otro en paralelo');
    expect(s.estado!.rezagoSeg, 0, reason: 'el estado aún no se publicó');

    final primera = m.compuerta!;
    m.compuerta = null;
    primera.complete();
    await _hasta(() => m.trozos.length == 2 && s.estado!.segmentos.length == 2);
    expect(m.trozos, [10.0, 20.0], reason: 'lo acumulado salió junto, en un solo trozo');
    await s.detener();
  });

  test('si el motor no da abasto se descarta lo más viejo y se anota', () async {
    final m = MotorFalso()..compuerta = Completer<void>();
    final s = crear(m); // tope = 3 trozos = 30 s
    await s.iniciar(idGrabacion: 'g', pcm: audio.stream);
    audio.add(_voz(10));
    await _soltar();
    for (var i = 0; i < 5; i++) {
      audio.add(_voz(10)); // 50 s acumulados detrás
    }
    await _soltar();
    final primera = m.compuerta!;
    m.compuerta = null;
    primera.complete();
    await _hasta(() => m.trozos.length == 2 && s.estado!.segmentos.length == 2);
    expect(m.trozos.last, 30.0);
    final e = s.estado!;
    expect(e.descartadoSeg, 20);
    // lo que se salvó es lo más reciente: empieza en el segundo 10 + 20 descartados
    expect(e.segmentos.last.desdeSeg, 30);
    await s.detener(vaciar: false);
  });

  test('un fallo del motor se anota y el borrador sigue', () async {
    final m = MotorFalso(falla: true);
    final s = crear(m);
    await s.iniciar(idGrabacion: 'g', pcm: audio.stream);
    audio.add(_voz(10));
    await _hasta(() => s.estado!.aviso != null);
    expect(s.estado!.aviso, contains('no se pudo transcribir'));
    expect(s.estado!.activa, isTrue);
    m.falla = false;
    audio.add(_voz(10));
    await _hasta(() => s.estado!.segmentos.isNotEmpty);
    expect(s.estado!.segmentos, isNotEmpty);
    await s.detener();
  });

  test('detener saca el último trozo corto, deja activa:false y libera el motor', () async {
    final m = MotorFalso();
    final s = crear(m);
    await s.iniciar(idGrabacion: 'g', pcm: audio.stream);
    audio.add(_voz(4)); // menos que un trozo
    await _soltar();
    expect(m.trozos, isEmpty);
    await s.detener();
    expect(m.trozos, [4.0]);
    final e = (await archivo.leer())!;
    expect(e.activa, isFalse);
    expect(e.finalizando, isFalse);
    expect(e.segmentos.single.texto, 'trozo 1');
    expect(m.liberado, isTrue);
  });

  test('detener sin vaciar cierra de inmediato', () async {
    final m = MotorFalso();
    final s = crear(m);
    await s.iniciar(idGrabacion: 'g', pcm: audio.stream);
    audio.add(_voz(4));
    await _soltar();
    await s.cancelar();
    expect(m.trozos, isEmpty);
    expect((await archivo.leer())!.activa, isFalse);
  });

  test('si el motor se cuelga, detener se rinde al vencer la espera', () async {
    final m = MotorFalso()..compuerta = Completer<void>();
    final s = crear(m);
    await s.iniciar(idGrabacion: 'g', pcm: audio.stream);
    audio.add(_voz(10));
    await _soltar();
    await s.detener(esperaMax: const Duration(milliseconds: 100));
    final e = (await archivo.leer())!;
    expect(e.activa, isFalse);
    expect(e.aviso, contains('no alcanzó'));
  });

  test('los WAV temporales no quedan tirados', () async {
    final m = MotorFalso();
    final s = crear(m);
    await s.iniciar(idGrabacion: 'g', pcm: audio.stream);
    audio.add(_voz(10));
    await _soltar();
    await s.detener();
    final sobras = tmp.listSync().where((f) => f.path.endsWith('.wav')).toList();
    expect(sobras, isEmpty);
  });

  test('el latido refresca el estado aunque no llegue texto', () async {
    final m = MotorFalso();
    final s = ServicioEnVivo(
      motor: m,
      archivo: archivo,
      modelo: 'base',
      trozoSeg: 10,
      carpetaTemporal: tmp,
      latido: const Duration(milliseconds: 40),
    );
    await s.iniciar(idGrabacion: 'g', pcm: audio.stream);
    final antes = (await archivo.leer())!.ultimaActualizacion;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final despues = (await archivo.leer())!.ultimaActualizacion;
    expect(despues.isAfter(antes), isTrue);
    await s.detener();
  });
}
