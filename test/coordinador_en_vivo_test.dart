import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:granolazo_app/en_vivo/coordinador_en_vivo.dart';
import 'package:granolazo_app/en_vivo/estado_en_vivo.dart';
import 'package:granolazo_app/en_vivo/fuentes_pcm.dart';
import 'package:granolazo_app/en_vivo/motor_en_vivo.dart';
import 'package:granolazo_app/en_vivo/pcm.dart';
import 'package:granolazo_app/services/ajustes_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Motor implements MotorEnVivo {
  @override
  Future<List<SegmentoEnVivo>> transcribir(File wav, {required String idioma}) async =>
      const [SegmentoEnVivo(desdeSeg: 0, hastaSeg: 1, texto: 'hola desde el borrador')];
  @override
  Future<void> liberar() async {}
}

class _Fuente implements FuentePcm {
  final c = StreamController<Uint8List>();
  bool abierta = false, cerrada = false;
  @override
  Stream<Uint8List> get pcm => c.stream;
  @override
  String? get aviso => null;
  @override
  Future<void> abrir() async => abierta = true;
  @override
  Future<void> cerrar() async {
    cerrada = true;
    await c.close();
  }
}

Uint8List _voz(double seg) {
  final n = (seg * Pcm.tasa).round();
  final b = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    b.setInt16(i * 2, i.isEven ? 9000 : -9000, Endian.little);
  }
  return b.buffer.asUint8List();
}

void main() {
  late Directory tmp;
  late _Fuente fuente;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('envivo-coord-');
    fuente = _Fuente();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  CoordinadorEnVivo crear() => CoordinadorEnVivo(
        ajustes: AjustesService(),
        crearFuente: (_) async => fuente,
        crearMotor: (_) => _Motor(),
        carpetaEstado: tmp,
      );

  group('ajustes', () {
    test('por defecto está apagado y con los valores acordados', () async {
      SharedPreferences.setMockInitialValues({});
      final c = await ConfigEnVivo.leer(AjustesService());
      expect(c.activo, isFalse);
      expect(c.modelo, ModeloEnVivo.base);
      expect(c.trozoSeg, 20);
      expect(c.hilos, 2);
    });

    test('valores fuera de rango se acotan y un modelo desconocido cae en base', () async {
      SharedPreferences.setMockInitialValues({
        'en_vivo_trozo_seg': 1,
        'en_vivo_hilos': 99,
        'en_vivo_modelo': 'gigante',
      });
      final c = await ConfigEnVivo.leer(AjustesService());
      expect(c.trozoSeg, ConfigEnVivo.trozoMin);
      expect(c.hilos, ConfigEnVivo.hilosMax);
      expect(c.modelo, ModeloEnVivo.base);
    });

    test('guardar y volver a leer', () async {
      SharedPreferences.setMockInitialValues({});
      final a = AjustesService();
      await a.guardarEnVivo(true);
      await a.guardarEnVivoModelo('tiny');
      await a.guardarEnVivoPuerto(0);
      final c = await ConfigEnVivo.leer(a);
      expect(c.activo, isTrue);
      expect(c.modelo, ModeloEnVivo.tiny);
      expect(c.puerto, 0);
    });
  });

  test('apagado: no abre la fuente ni escribe nada', () async {
    SharedPreferences.setMockInitialValues({});
    final c = crear();
    await c.arrancar(idGrabacion: 'g', rutaSistema: () => null);
    expect(c.activo, isFalse);
    expect(fuente.abierta, isFalse);
    expect(tmp.listSync(), isEmpty);
  });

  test('encendido: arranca, escribe en-vivo.json y al parar queda activa:false', () async {
    SharedPreferences.setMockInitialValues({
      'transcripcion_en_vivo': true,
      'en_vivo_trozo_seg': 5,
      'en_vivo_puerto': 0,
    });
    final c = crear();
    await c.arrancar(idGrabacion: 'grab-1', rutaSistema: () => null);
    expect(c.activo, isTrue);
    expect(fuente.abierta, isTrue);

    fuente.c.add(_voz(5));
    final archivo = ArchivoEnVivo(carpeta: tmp);
    final limite = DateTime.now().add(const Duration(seconds: 3));
    while ((c.estado?.segmentos.isEmpty ?? true) && DateTime.now().isBefore(limite)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(c.estado!.texto, 'hola desde el borrador');
    expect((await archivo.leer())!.idGrabacion, 'grab-1');

    await c.parar();
    expect(c.activo, isFalse);
    expect(fuente.cerrada, isTrue);
    final fin = (await archivo.leer())!;
    expect(fin.activa, isFalse);
    expect(fin.texto, 'hola desde el borrador');
  });

  test('si la fuente no abre, no lanza y deja un aviso', () async {
    SharedPreferences.setMockInitialValues({'transcripcion_en_vivo': true, 'en_vivo_puerto': 0});
    final c = CoordinadorEnVivo(
      ajustes: AjustesService(),
      crearFuente: (_) async => throw StateError('sin micrófono'),
      crearMotor: (_) => _Motor(),
      carpetaEstado: tmp,
    );
    await c.arrancar(idGrabacion: 'g', rutaSistema: () => null);
    expect(c.activo, isFalse);
    expect(c.aviso, contains('sin micrófono'));
    expect(c.aviso, contains('La grabación sigue normal'));
  });

  test('parar sin haber arrancado no hace nada', () async {
    SharedPreferences.setMockInitialValues({});
    await crear().parar();
  });
}
