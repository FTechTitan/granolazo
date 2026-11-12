import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:granolazo_app/en_vivo/comando_en_vivo.dart';
import 'package:granolazo_app/en_vivo/estado_en_vivo.dart';

void main() {
  late Directory tmp;
  late ArchivoEnVivo archivo;
  final ahora = DateTime.utc(2026, 10, 24, 12, 1);
  final salida = <String>[];

  EstadoEnVivo estado({bool activa = true, DateTime? act, List<SegmentoEnVivo>? segs}) => EstadoEnVivo(
        idGrabacion: '99',
        inicio: DateTime.utc(2026, 10, 24, 12),
        activa: activa,
        ultimaActualizacion: act ?? ahora.subtract(const Duration(seconds: 5)),
        modelo: 'base',
        trozoSeg: 20,
        segmentos: segs ??
            const [
              SegmentoEnVivo(desdeSeg: 3, hastaSeg: 6, texto: 'Buenos días.'),
              SegmentoEnVivo(desdeSeg: 65, hastaSeg: 70, texto: 'Pasemos al presupuesto.'),
            ],
      );

  ComandoEnVivo cmd({bool json = false}) => ComandoEnVivo(
        archivo: archivo,
        escribir: salida.add,
        json: json,
        ahora: () => ahora,
        sondeo: const Duration(milliseconds: 10),
      );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('envivo-cmd-');
    archivo = ArchivoEnVivo(carpeta: tmp);
    salida.clear();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('sin archivo: mensaje claro y código 3', () async {
    expect(await cmd().ejecutar(), 3);
    expect(salida.single, contains('no hay ninguna grabación'));
  });

  test('sin archivo y con --json: una línea de JSON con activa:false y código 3', () async {
    expect(await cmd(json: true).ejecutar(), 3);
    expect(salida, hasLength(1));
    final j = jsonDecode(salida.single) as Map;
    expect(j['activa'], false);
    expect(j['motivo'], isNotEmpty);
  });

  test('en curso: muestra el borrador con marcas de tiempo, código 0', () async {
    await archivo.escribir(estado());
    expect(await cmd().ejecutar(), 0);
    expect(salida.first, contains('BORRADOR'));
    expect(salida.first, contains('en curso'));
    expect(salida[1], '[00:03] Buenos días.');
    expect(salida[2], '[01:05] Pasemos al presupuesto.');
  });

  test('en curso con --json: una línea con el contrato completo', () async {
    await archivo.escribir(estado());
    expect(await cmd(json: true).ejecutar(), 0);
    expect(salida, hasLength(1));
    final j = jsonDecode(salida.single) as Map<String, dynamic>;
    expect(j['activa'], true);
    expect(j['texto'], 'Buenos días. Pasemos al presupuesto.');
    expect(j['segmentos'], hasLength(2));
  });

  test('terminada: código 3 salvo que se pida --ultima', () async {
    await archivo.escribir(estado(activa: false));
    expect(await cmd().ejecutar(), 3);
    expect(salida.single, contains('--ultima'));
    salida.clear();
    expect(await cmd().ejecutar(ultima: true), 0);
    expect(salida.first, contains('terminada'));
  });

  test('activa pero abandonada (app caída): no se hace pasar por viva', () async {
    await archivo.escribir(estado(act: ahora.subtract(const Duration(minutes: 20))));
    expect(await cmd(json: true).ejecutar(), 3);
    final j = jsonDecode(salida.single) as Map;
    expect(j['motivo'], contains('dejó de actualizarse'));
    expect(j['ultima_grabacion'], '99');
  });

  test('--seguir imprime lo nuevo hasta que la grabación termina', () async {
    await archivo.escribir(estado(segs: const [
      SegmentoEnVivo(desdeSeg: 1, hastaSeg: 2, texto: 'uno'),
    ]));
    final futuro = cmd(json: true).ejecutar(seguir: true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await archivo.escribir(estado(segs: const [
      SegmentoEnVivo(desdeSeg: 1, hastaSeg: 2, texto: 'uno'),
      SegmentoEnVivo(desdeSeg: 21, hastaSeg: 22, texto: 'dos'),
    ]));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await archivo.escribir(estado(activa: false, segs: const [
      SegmentoEnVivo(desdeSeg: 1, hastaSeg: 2, texto: 'uno'),
      SegmentoEnVivo(desdeSeg: 21, hastaSeg: 22, texto: 'dos'),
    ]));
    expect(await futuro.timeout(const Duration(seconds: 5)), 0);
    final lineas = salida.map((l) => jsonDecode(l) as Map).toList();
    expect(lineas.where((l) => l.containsKey('segmento')).map((l) => (l['segmento'] as Map)['texto']),
        ['uno', 'dos']);
    expect(lineas.last['fin'], true);
  });
}
