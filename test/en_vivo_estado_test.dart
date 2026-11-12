import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:granolazo_app/en_vivo/estado_en_vivo.dart';

EstadoEnVivo _estado({bool activa = true, DateTime? act, int trozo = 20}) => EstadoEnVivo(
      idGrabacion: '123',
      inicio: DateTime.utc(2026, 10, 24, 12),
      activa: activa,
      ultimaActualizacion: act ?? DateTime.utc(2026, 10, 24, 12, 0, 30),
      modelo: 'base',
      trozoSeg: trozo,
      rezagoSeg: 4.26,
      segmentos: const [
        SegmentoEnVivo(desdeSeg: 0, hastaSeg: 3.5, texto: 'Hola a todos.'),
        SegmentoEnVivo(desdeSeg: 3.5, hastaSeg: 9.123, texto: 'Empezamos.'),
      ],
    );

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('envivo-estado-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('el JSON respeta el contrato de campos', () {
    final j = _estado().toJson();
    expect(j.keys, containsAll([
      'id_grabacion', 'inicio', 'activa', 'ultima_actualizacion', 'modelo',
      'trozo_seg', 'rezago_seg', 'texto', 'segmentos',
    ]));
    expect(j['texto'], 'Hola a todos. Empezamos.');
    expect(j['borrador'], isTrue);
    expect(j['rezago_seg'], 4.3);
    final seg = (j['segmentos'] as List).last as Map;
    expect(seg.keys, containsAll(['desde_seg', 'hasta_seg', 'texto']));
    expect(seg['hasta_seg'], 9.12);
    expect(j['inicio'], '2026-10-24T12:00:00.000Z');
  });

  test('ida y vuelta por JSON conserva todo', () {
    final e = EstadoEnVivo.fromJson(jsonDecode(jsonEncode(_estado().toJson())) as Map<String, dynamic>);
    expect(e.idGrabacion, '123');
    expect(e.activa, isTrue);
    expect(e.segmentos, hasLength(2));
    expect(e.texto, 'Hola a todos. Empezamos.');
    expect(e.trozoSeg, 20);
  });

  test('escribir y leer por archivo, sin dejar el temporal', () async {
    final a = ArchivoEnVivo(carpeta: tmp);
    expect(await a.leer(), isNull);
    expect(await a.escribir(_estado()), isTrue);
    expect(await a.escribir(_estado(activa: false)), isTrue);
    final e = await a.leer();
    expect(e!.activa, isFalse);
    final nombres = tmp.listSync().map((f) => f.uri.pathSegments.last).toList();
    expect(nombres, ['en-vivo.json']);
  });

  test('un archivo corrupto se lee como "no hay" sin lanzar', () async {
    File('${tmp.path}/en-vivo.json').writeAsStringSync('{"id_grab');
    expect(await ArchivoEnVivo(carpeta: tmp).leer(), isNull);
  });

  group('estaVigente', () {
    final base = DateTime.utc(2026, 10, 24, 12);
    test('activa y reciente: sí', () {
      final e = _estado(act: base);
      expect(estaVigente(e, ahora: base.add(const Duration(seconds: 30))), isTrue);
    });
    test('activa pero vieja (la app se cayó): no', () {
      final e = _estado(act: base);
      expect(estaVigente(e, ahora: base.add(const Duration(minutes: 10))), isFalse);
    });
    test('terminada: no, aunque sea reciente', () {
      final e = _estado(activa: false, act: base);
      expect(estaVigente(e, ahora: base), isFalse);
    });
  });
}
