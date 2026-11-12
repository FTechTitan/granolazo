import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'estado_en_vivo.dart';

/// `GET http://127.0.0.1:<puerto>/en-vivo` con el mismo JSON que `en-vivo.json`.
///
/// Es la forma barata de que un agente o un script lea la reunión que está ocurriendo sin
/// tocar archivos. **Solo existe mientras se graba con el modo en vivo encendido.**
///
/// Seguridad: escucha únicamente en loopback, rechaza clientes que no lo sean, solo
/// contesta GET, y exige que el encabezado `Host` sea de loopback (así una página web
/// abierta en el navegador no puede leerlo con un ataque de reasignación de DNS). No manda
/// cabeceras CORS: ninguna página puede pedirlo desde el navegador.
class ServidorEnVivo {
  ServidorEnVivo({required this.estado, this.puerto = 47821});

  /// Devuelve el estado actual (el que ve el servicio en memoria).
  final EstadoEnVivo? Function() estado;
  final int puerto;

  HttpServer? _server;

  /// Puerto en el que quedó escuchando (útil cuando se pide el 0 en un test).
  int? get puertoReal => _server?.port;

  bool get escuchando => _server != null;

  /// Arranca. Devuelve `null` si salió bien, o el motivo si no (típico: puerto ocupado).
  Future<String?> iniciar() async {
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, puerto);
    } catch (e) {
      return 'no pude abrir el puerto $puerto para consultar el borrador ($e)';
    }
    _server!.listen(_atender, onError: (_) {});
    return null;
  }

  static final _hostsPermitidos = RegExp(r'^(127\.0\.0\.1|localhost)(:\d+)?$', caseSensitive: false);

  Future<void> _atender(HttpRequest req) async {
    final res = req.response;
    try {
      final remoto = req.connectionInfo?.remoteAddress;
      final host = req.headers.value(HttpHeaders.hostHeader) ?? '';
      if (remoto == null || !remoto.isLoopback || !_hostsPermitidos.hasMatch(host)) {
        res.statusCode = HttpStatus.forbidden;
      } else if (req.method != 'GET') {
        res.statusCode = HttpStatus.methodNotAllowed;
        res.headers.set(HttpHeaders.allowHeader, 'GET');
      } else if (req.uri.path == '/en-vivo') {
        final e = estado();
        if (e == null) {
          res.statusCode = HttpStatus.notFound;
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({'activa': false, 'motivo': 'no hay grabación en vivo'}));
        } else {
          res.statusCode = HttpStatus.ok;
          res.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
          res.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
          res.write(jsonEncode(e.toJson()));
        }
      } else {
        res.statusCode = HttpStatus.notFound;
      }
    } catch (_) {
      res.statusCode = HttpStatus.internalServerError;
    } finally {
      await res.close();
    }
  }

  Future<void> detener() async {
    final s = _server;
    _server = null;
    await s?.close(force: true);
  }
}
