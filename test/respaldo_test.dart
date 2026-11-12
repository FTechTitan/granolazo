import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granolazo_app/models/archivo_respaldo.dart';
import 'package:granolazo_app/models/item_granolazo.dart';
import 'package:granolazo_app/services/ajustes_service.dart';
import 'package:granolazo_app/services/drive_cliente.dart';
import 'package:granolazo_app/services/respaldo_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _bloque = 256 * 1024;
const _carpeta = 'carpetaDrive123';
const _sesion = 'https://www.googleapis.com/upload/drive/v3/files?upload_id=abc';

List<int> _contenido(int bytes, {int semilla = 0}) =>
    List.generate(bytes, (i) => (i + semilla) % 251);

String _md5(List<int> bytes) => md5.convert(bytes).toString();

class _TokenFijo implements ProveedorTokenDrive {
  _TokenFijo({this.falla});
  final ErrorSesionDrive? falla;
  @override
  Future<String> token() async {
    if (falla != null) throw falla!;
    return 'token-de-prueba';
  }

  @override
  void invalidar() {}
}

/// Un Drive de mentira que guarda lo que recibe, para comprobar la subida por bloques.
class _DriveFalso {
  final existentes = <Map<String, dynamic>>[];
  final remotos = <String, Map<String, dynamic>>{};
  final recibido = BytesBuilder();
  var bloques = 0;
  var sesionesAbiertas = 0;
  var cortarBloque = -1;
  final carpetasDeSubida = <String>[];
  final movidos = <String, String>{};
  var carpetasCreadas = 0;

  http.Client get cliente => MockClient((p) async {
        final url = p.url.toString();
        if (p.method == 'GET' && p.url.path.endsWith('/files')) {
          // La búsqueda de la carpeta de respaldo en la raíz: no existe todavía.
          if ((p.url.queryParameters['q'] ?? '').contains("'root' in parents")) {
            return _json({'files': []});
          }
          return _json({'files': existentes});
        }
        if (p.method == 'POST' && p.url.path == '/drive/v3/files') {
          carpetasCreadas++;
          return _json({'id': 'carpeta-creada'});
        }
        if (p.method == 'PATCH') {
          movidos[p.url.pathSegments.last] = p.url.queryParameters['addParents']!;
          return _json({'id': p.url.pathSegments.last});
        }
        if (p.method == 'GET' && p.url.path.contains('/files/')) {
          final id = p.url.pathSegments.last;
          final f = remotos[id];
          return f == null ? http.Response('', 404) : _json(f);
        }
        if (p.method == 'POST' && url.contains('uploadType=resumable')) {
          sesionesAbiertas++;
          carpetasDeSubida.add(((jsonDecode(p.body) as Map)['parents'] as List).first);
          return http.Response('', 200, headers: {'location': _sesion});
        }
        if (p.method == 'PUT' && url == _sesion) {
          final rango = p.headers['Content-Range']!;
          if (rango.startsWith('bytes */')) {
            return _progreso(int.parse(rango.split('/').last));
          }
          if (bloques++ == cortarBloque) {
            throw http.ClientException('se cayó la red');
          }
          recibido.add(p.bodyBytes);
          return _progreso(int.parse(rango.split('/').last));
        }
        return http.Response('no esperaba $url', 500);
      });

  http.Response _progreso(int total) {
    final n = recibido.length;
    if (n >= total) {
      // Un id por subida, como en Drive: dos videos distintos nunca comparten id.
      final id = 'drive-$sesionesAbiertas';
      final f = {
        'id': id,
        'name': 'x',
        'size': '$n',
        'md5Checksum': _md5(recibido.toBytes()),
        'trashed': false,
      };
      remotos[id] = f;
      return _json(f);
    }
    return http.Response('', 308, headers: n == 0 ? {} : {'range': 'bytes=0-${n - 1}'});
  }

  static http.Response _json(Object o) =>
      http.Response(jsonEncode(o), 200, headers: {'content-type': 'application/json'});
}

void main() {
  late Directory dir;
  late File estado;
  final futuro = DateTime.now().add(const Duration(hours: 1));

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('respaldo_test');
    estado = File('${dir.path}${Platform.pathSeparator}estado.json');
    await Directory('${dir.path}${Platform.pathSeparator}videos').create();
    SharedPreferences.setMockInitialValues({
      'respaldo_carpeta_local': '${dir.path}${Platform.pathSeparator}videos',
      'respaldo_carpeta_drive': _carpeta,
      'respaldo_perfil_gws': '',
    });
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<File> video(String nombre, int bytes) async {
    final f = File('${dir.path}${Platform.pathSeparator}videos${Platform.pathSeparator}$nombre');
    await f.writeAsBytes(_contenido(bytes));
    return f;
  }

  RespaldoService servicio(_DriveFalso drive,
          {DateTime? ahora,
          ProveedorTokenDrive? tokens,
          Future<Map<String, ItemGranolazo>> Function(List<String>)? transcripciones}) =>
      RespaldoService(
        consultarTranscripciones: transcripciones,
        ajustes: AjustesService(),
        archivoEstado: () async => estado,
        ahora: () => ahora ?? futuro,
        crearDrive: (_) => DriveCliente(
          tokens: tokens ?? _TokenFijo(),
          cliente: drive.cliente,
          tamanoBloque: _bloque,
          esperaEntreReintentos: Duration.zero,
        ),
      );

  test('reconoce el id de una carpeta en un enlace o suelto', () {
    expect(
        RespaldoService.idDeCarpeta(
            'https://drive.google.com/drive/folders/REPLACE_WITH_YOUR_DRIVE_FOLDER_ID?usp=sharing'),
        'REPLACE_WITH_YOUR_DRIVE_FOLDER_ID');
    expect(RespaldoService.idDeCarpeta('https://drive.google.com/open?id=abcdefghijkl'),
        'abcdefghijkl');
    expect(RespaldoService.idDeCarpeta('  REPLACE_WITH_YOUR_DRIVE_FOLDER_ID '),
        'REPLACE_WITH_YOUR_DRIVE_FOLDER_ID');
    expect(RespaldoService.idDeCarpeta('no es una carpeta'), isNull);
  });

  test('sube un video en bloques y lo recuerda como respaldado', () async {
    final drive = _DriveFalso();
    final f = await video('2026-08-02 16-44-29.mp4', _bloque * 2 + 1000);
    await video('notas.txt', 50); // no es video: se ignora

    final r = servicio(drive);
    await r.cargar();
    await r.revisarAhora();

    expect(r.archivos.single.error, isNull);
    expect(r.errorGeneral, isNull);
    expect(r.archivos, hasLength(1));
    final a = r.archivos.single;
    expect(a.estado, EstadoRespaldo.respaldado);
    expect(a.driveId, 'drive-1');
    expect(drive.bloques, 3);
    expect(drive.recibido.toBytes(), await f.readAsBytes());
    expect(r.bytesLiberables, _bloque * 2 + 1000);

    // Otro arranque lo sabe sin volver a subirlo.
    final otro = servicio(drive);
    await otro.cargar();
    await otro.revisarAhora();
    expect(otro.archivos.single.estado, EstadoRespaldo.respaldado);
    expect(drive.sesionesAbiertas, 1);
  });

  test('si se corta la red sigue desde lo que Drive alcanzó a recibir', () async {
    final drive = _DriveFalso()..cortarBloque = 1;
    final f = await video('largo.mkv', _bloque * 3);

    final r = servicio(drive);
    await r.cargar();
    await r.revisarAhora();

    expect(r.archivos.single.estado, EstadoRespaldo.respaldado);
    expect(drive.recibido.toBytes(), await f.readAsBytes());
    expect(drive.sesionesAbiertas, 1);
  });

  test('lo que ya está en Drive con el mismo tamaño no se vuelve a subir', () async {
    final drive = _DriveFalso();
    await video('ya-subido.mp4', 1234);
    drive.existentes.add({
      'id': 'viejo',
      'name': 'ya-subido.mp4',
      'size': '1234',
      'md5Checksum': _md5(_contenido(1234)),
    });

    final r = servicio(drive);
    await r.cargar();
    await r.revisarAhora();

    expect(r.archivos.single.estado, EstadoRespaldo.respaldado);
    expect(r.archivos.single.driveId, 'viejo');
    expect(drive.sesionesAbiertas, 0);
  });

  test('mismo nombre y tamaño pero otro contenido: se sube igual', () async {
    final drive = _DriveFalso();
    await video('homonimo.mp4', 1234);
    drive.existentes.add({
      'id': 'otro',
      'name': 'homonimo.mp4',
      'size': '1234',
      'md5Checksum': _md5(_contenido(1234, semilla: 7)),
    });

    final r = servicio(drive);
    await r.cargar();
    await r.revisarAhora();

    expect(r.archivos.single.estado, EstadoRespaldo.respaldado);
    expect(r.archivos.single.driveId, 'drive-1');
    expect(drive.sesionesAbiertas, 1);
  });

  test('si se reescribe con el mismo tamaño deja de contar como respaldado', () async {
    final drive = _DriveFalso();
    final f = await video('reescrito.mp4', 1000);
    final r = servicio(drive);
    await r.cargar();
    await r.revisarAhora();
    expect(r.archivos.single.estado, EstadoRespaldo.respaldado);

    await f.writeAsBytes(_contenido(1000, semilla: 9));
    await f.setLastModified(DateTime.now().subtract(const Duration(days: 1)));
    drive.recibido.clear();
    await r.revisarAhora();

    expect(r.archivos.single.estado, EstadoRespaldo.respaldado);
    expect(drive.sesionesAbiertas, 2);
    expect(drive.recibido.toBytes(), _contenido(1000, semilla: 9));
  });

  test('se puede liberar espacio mientras sube otro video', () async {
    final drive = _DriveFalso();
    final chico = await video('chico.mp4', 1000);
    final r = servicio(drive);
    await r.cargar();
    await r.revisarAhora();
    final idChico = r.archivos.single.driveId!;

    await video('grande.mp4', _bloque * 4);
    drive.recibido.clear();
    final pasada = r.revisarAhora();
    expect(r.revisando, isTrue);
    final res = await r.liberarEspacio();
    await pasada;

    expect(res.fallidos, isEmpty);
    expect(res.liberados, 1);
    expect(await chico.exists(), isFalse);
    final porNombre = {for (final a in r.archivos) a.nombre: a};
    expect(porNombre['chico.mp4']!.estado, EstadoRespaldo.liberado);
    expect(porNombre['chico.mp4']!.driveId, idChico);
    expect(porNombre['grande.mp4']!.estado, EstadoRespaldo.respaldado);
    expect(porNombre['grande.mp4']!.error, isNull);
  });

  test('un video que se sigue grabando espera a que termine', () async {
    final drive = _DriveFalso();
    await video('grabando.mkv', 1000);

    final r = servicio(drive, ahora: DateTime.now());
    await r.cargar();
    await r.revisarAhora();

    expect(r.archivos.single.estado, EstadoRespaldo.pendiente);
    expect(drive.sesionesAbiertas, 0);
  });

  test('sin sesión de Google se detiene y avisa, sin marcar errores por archivo', () async {
    final drive = _DriveFalso();
    await video('a.mp4', 1000);

    final r = servicio(drive,
        tokens: _TokenFijo(falla: ErrorSesionDrive('gws no tiene una sesión')));
    await r.cargar();
    await r.revisarAhora();

    expect(r.errorGeneral, contains('gws'));
    expect(r.archivos.single.estado, EstadoRespaldo.pendiente);
  });

  test('liberar espacio borra solo lo que Drive confirma', () async {
    final drive = _DriveFalso();
    final bueno = await video('bueno.mp4', 1000);
    final distinto = await video('distinto.mp4', 2000);
    drive.existentes.addAll([
      {'id': 'b', 'name': 'bueno.mp4', 'size': '1000', 'md5Checksum': _md5(_contenido(1000))},
    ]);

    final r = servicio(drive);
    await r.cargar();
    await r.revisarAhora();
    // "distinto" se subió; después alguien lo cambió en Drive.
    final idDistinto = r.archivos.firstWhere((a) => a.nombre == 'distinto.mp4').driveId!;
    drive.remotos['b'] = {
      'id': 'b',
      'name': 'bueno.mp4',
      'size': '1000',
      'md5Checksum': _md5(_contenido(1000)),
    };
    // Mismo tamaño, contenido distinto: solo el MD5 lo delata.
    drive.remotos[idDistinto] = {
      'id': idDistinto,
      'name': 'distinto.mp4',
      'size': '2000',
      'md5Checksum': _md5(_contenido(2000, semilla: 3)),
    };

    final res = await r.liberarEspacio();

    expect(res.liberados, 1);
    expect(res.bytes, 1000);
    expect(res.fallidos.keys, ['distinto.mp4']);
    expect(await bueno.exists(), isFalse);
    expect(await distinto.exists(), isTrue);
    expect(r.liberados.single.nombre, 'bueno.mp4');
    expect(r.respaldados.single.nombre, 'distinto.mp4');
  });

  test('si el archivo ya no está en Drive, no se borra y vuelve a la cola', () async {
    final drive = _DriveFalso();
    final f = await video('perdido.mp4', 1000);
    drive.existentes.add({
      'id': 'p',
      'name': 'perdido.mp4',
      'size': '1000',
      'md5Checksum': _md5(_contenido(1000)),
    });

    final r = servicio(drive);
    await r.cargar();
    await r.revisarAhora();
    final res = await r.liberarEspacio();

    expect(res.liberados, 0);
    expect(await f.exists(), isTrue);
    expect(r.pendientes.single.nombre, 'perdido.mp4');
  });

  group('token desde gws', () {
    test('pide el token con el refresh token exportado y lo reutiliza', () async {
      var exportaciones = 0;
      var pedidos = 0;
      Map<String, String>? entornoVisto;
      final t = TokenDesdeGws(
        perfil: r'C:\perfil',
        correr: (programa, args, entorno) async {
          exportaciones++;
          entornoVisto = entorno;
          expect(args, ['auth', 'export', '--unmasked']);
          return ProcessResult(
              0,
              0,
              jsonEncode({
                'client_id': 'id',
                'client_secret': 'secreto',
                'refresh_token': 'refresco',
                'type': 'authorized_user',
              }),
              '');
        },
        cliente: MockClient((p) async {
          pedidos++;
          expect(p.bodyFields['refresh_token'], 'refresco');
          return http.Response(jsonEncode({'access_token': 'at', 'expires_in': 3600}), 200);
        }),
      );

      expect(await t.token(), 'at');
      expect(await t.token(), 'at');
      expect(exportaciones, 1);
      expect(pedidos, 1);
      expect(entornoVisto?['GOOGLE_WORKSPACE_CLI_CONFIG_DIR'], r'C:\perfil');
    });

    test('sin sesión en gws avisa con un mensaje entendible', () async {
      final t = TokenDesdeGws(
        correr: (_, _, _) async => ProcessResult(0, 1, '', 'no credentials'),
        cliente: MockClient((_) async => http.Response('', 500)),
      );
      await expectLater(t.token(), throwsA(isA<ErrorSesionDrive>()));
    });
  });

  test('el estado guardado sobrevive a un JSON roto', () async {
    await estado.writeAsString('{roto');
    final r = servicio(_DriveFalso());
    await r.cargar();
    expect(r.archivos, isEmpty);
  });

  group('transcribir en Granolazo', () {
    test('apagado va a la carpeta de respaldo; encendido, a la de Granolazo', () async {
      final drive = _DriveFalso();
      await video('solo-respaldo.mp4', 1000);
      final r = servicio(drive);
      await r.cargar();
      expect(r.transcribir, isFalse);
      await r.revisarAhora();
      expect(drive.carpetasDeSubida, [_carpeta]);
      expect(r.vaATranscribirse(r.archivos.single), isFalse);

      await r.activarTranscripcion(true, revisar: false);
      await video('para-transcribir.mp4', 2000);
      drive.recibido.clear();
      await r.revisarAhora();

      expect(drive.carpetasDeSubida.last, AjustesService.carpetaDriveObs);
      expect(r.archivos.every(r.vaATranscribirse), isTrue);
    });

    test('al encenderlo, lo ya respaldado (y lo liberado) se mueve sin resubir', () async {
      final drive = _DriveFalso();
      final f = await video('viejo.mp4', 1000);
      final r = servicio(drive);
      await r.cargar();
      await r.revisarAhora();
      final id = r.archivos.single.driveId!;
      drive.remotos[id] = {...drive.remotos[id]!};
      await r.liberarEspacio();
      expect(await f.exists(), isFalse);

      await r.activarTranscripcion(true, revisar: false);
      await r.revisarAhora();

      expect(drive.movidos, {id: AjustesService.carpetaDriveObs});
      expect(drive.sesionesAbiertas, 1);
      expect(r.liberados.single.carpetaDrive, AjustesService.carpetaDriveObs);
    });

    test('sin carpeta de respaldo elegida, la crea en Drive una sola vez', () async {
      SharedPreferences.setMockInitialValues({
        'respaldo_carpeta_local': '${dir.path}${Platform.pathSeparator}videos',
      });
      final drive = _DriveFalso();
      await video('a.mp4', 1000);
      final r = servicio(drive);
      await r.cargar();
      await r.revisarAhora();
      await video('b.mp4', 1500);
      drive.recibido.clear();
      await r.revisarAhora();

      expect(drive.carpetasCreadas, 1);
      expect(drive.carpetasDeSubida, ['carpeta-creada', 'carpeta-creada']);
      expect(await AjustesService().leerRespaldoCarpetaDrive(), 'carpeta-creada');
    });

    test('muestra en qué va la transcripción de cada video', () async {
      SharedPreferences.setMockInitialValues({
        'respaldo_carpeta_local': '${dir.path}${Platform.pathSeparator}videos',
        'respaldo_transcribir': true,
      });
      final drive = _DriveFalso();
      await video('reunion.mp4', 1000);
      List<String>? pedidos;
      final r = servicio(drive, transcripciones: (ids) async {
        pedidos = ids;
        return {
          ids.single: ItemGranolazo.fromJson({
            'id': 'obs-reunion.mp4',
            'status': 'pending',
            'progress': 40,
            'drive_url': 'https://drive.google.com/file/d/${ids.single}/view',
          }),
        };
      });
      await r.cargar();
      await r.revisarAhora();

      expect(pedidos, ['drive-1']);
      final item = r.transcripcionDe(r.archivos.single)!;
      expect(item.estado, 'pending');
      expect(item.progreso, 40);
    });
  });

  test('tamaño legible', () {
    expect(tamanoLegible(633429703), '604 MB');
    expect(tamanoLegible(2 * 1024 * 1024 * 1024 + 300 * 1024 * 1024), '2,3 GB');
    expect(tamanoLegible(500), '500 B');
  });
}
