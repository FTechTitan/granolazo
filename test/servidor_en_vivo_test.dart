import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:granolazo_app/en_vivo/estado_en_vivo.dart';
import 'package:granolazo_app/en_vivo/servidor_en_vivo.dart';

void main() {
  EstadoEnVivo? actual = EstadoEnVivo(
    idGrabacion: '7',
    inicio: DateTime.utc(2026, 10, 24),
    activa: true,
    ultimaActualizacion: DateTime.utc(2026, 10, 24),
    modelo: 'base',
    trozoSeg: 20,
    segmentos: const [SegmentoEnVivo(desdeSeg: 0, hastaSeg: 1, texto: 'hola')],
  );
  late ServidorEnVivo servidor;
  late HttpClient http;

  setUp(() async {
    servidor = ServidorEnVivo(estado: () => actual, puerto: 0);
    expect(await servidor.iniciar(), isNull);
    http = HttpClient();
  });
  tearDown(() async {
    http.close(force: true);
    await servidor.detener();
  });

  Future<(int, String)> pedir(String metodo, String ruta, {String? host}) async {
    final req = await http.openUrl(metodo, Uri.parse('http://127.0.0.1:${servidor.puertoReal}$ruta'));
    if (host != null) req.headers.set(HttpHeaders.hostHeader, host);
    final res = await req.close();
    return (res.statusCode, await res.transform(utf8.decoder).join());
  }

  test('GET /en-vivo devuelve el mismo JSON que el archivo', () async {
    final (codigo, cuerpo) = await pedir('GET', '/en-vivo');
    expect(codigo, 200);
    final j = jsonDecode(cuerpo) as Map;
    expect(j['id_grabacion'], '7');
    expect(j['texto'], 'hola');
  });

  test('escucha solo en loopback', () {
    expect(servidor.escuchando, isTrue);
  });

  test('rechaza un Host que no sea de la máquina (reasignación de DNS)', () async {
    final (codigo, _) = await pedir('GET', '/en-vivo', host: 'mi-sitio-malo.example');
    expect(codigo, 403);
  });

  test('solo GET', () async {
    final (codigo, _) = await pedir('POST', '/en-vivo');
    expect(codigo, 405);
  });

  test('otras rutas, 404; sin grabación, 404 con JSON', () async {
    expect((await pedir('GET', '/otra')).$1, 404);
    actual = null;
    final (codigo, cuerpo) = await pedir('GET', '/en-vivo');
    expect(codigo, 404);
    expect((jsonDecode(cuerpo) as Map)['activa'], false);
  });

  test('un puerto ocupado devuelve el motivo en vez de lanzar', () async {
    final otro = ServidorEnVivo(estado: () => actual, puerto: servidor.puertoReal!);
    expect(await otro.iniciar(), contains('no pude abrir el puerto'));
    expect(otro.escuchando, isFalse);
  });
}
