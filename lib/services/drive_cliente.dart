import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

/// Algo que sabe entregar un token de acceso de Google con permiso sobre Drive.
abstract class ProveedorTokenDrive {
  Future<String> token();

  /// Descarta el token en memoria: Drive lo rechazó y hay que pedir otro.
  void invalidar();
}

/// Falla que se le puede mostrar tal cual a quien usa la app.
class ErrorDrive implements Exception {
  ErrorDrive(this.mensaje);
  final String mensaje;
  @override
  String toString() => mensaje;
}

/// No hay forma de hablar con Drive: falta `gws`, la sesión venció o la cuenta no tiene
/// permiso. A diferencia de un corte de red, no se arregla reintentando archivo por
/// archivo, así que detiene la pasada completa.
class ErrorSesionDrive extends ErrorDrive {
  ErrorSesionDrive(super.mensaje);
}

/// Corre un programa y devuelve lo que imprimió. Existe para poder probar sin `gws`.
typedef CorrerProceso = Future<ProcessResult> Function(
    String programa, List<String> args, Map<String, String> entorno);

Future<ProcessResult> _correrDeVerdad(
        String programa, List<String> args, Map<String, String> entorno) =>
    Process.run(programa, args, environment: entorno, runInShell: true);

/// El token sale de la sesión de `gws` que ya existe en el equipo.
///
/// Así la app no necesita su propio cliente OAuth ni una ventana de inicio de sesión de
/// Google: reusa la cuenta con la que ya se trabaja Drive desde la consola, igual que
/// usa el `ffmpeg` del sistema. `gws auth export --unmasked` entrega el refresh token y
/// con él se pide un token de acceso de una hora.
///
/// Nada de esto se escribe a disco ni a un log: vive en memoria mientras dura el token.
class TokenDesdeGws implements ProveedorTokenDrive {
  TokenDesdeGws({
    this.perfil,
    http.Client? cliente,
    CorrerProceso? correr,
    DateTime Function()? ahora,
  })  : _cliente = cliente ?? http.Client(),
        _correr = correr ?? _correrDeVerdad,
        _ahora = ahora ?? DateTime.now;

  /// Carpeta de configuración de `gws` (`GOOGLE_WORKSPACE_CLI_CONFIG_DIR`). Vacía o nula
  /// usa la que `gws` tenga por defecto.
  final String? perfil;
  final http.Client _cliente;
  final CorrerProceso _correr;
  final DateTime Function() _ahora;

  String? _token;
  DateTime _vence = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void invalidar() => _token = null;

  @override
  Future<String> token() async {
    final vigente = _token;
    if (vigente != null && _ahora().isBefore(_vence)) return vigente;

    final credenciales = await _exportar();
    final r = await _cliente.post(
      Uri.parse('https://oauth2.googleapis.com/token'),
      body: {
        'client_id': credenciales['client_id'],
        'client_secret': credenciales['client_secret'],
        'refresh_token': credenciales['refresh_token'],
        'grant_type': 'refresh_token',
      },
    );
    if (r.statusCode != 200) {
      throw ErrorSesionDrive('Google rechazó la sesión de gws (${r.statusCode}). '
          'Vuelve a entrar con `gws auth login`.');
    }
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final nuevo = j['access_token'] as String;
    final segundos = (j['expires_in'] as num?)?.toInt() ?? 3600;
    // Se renueva un par de minutos antes de que venza: una subida larga no debe tropezar
    // con un token que expiró justo en la mitad de un bloque.
    _vence = _ahora().add(Duration(seconds: max(60, segundos - 120)));
    return _token = nuevo;
  }

  Future<Map<String, dynamic>> _exportar() async {
    final entorno = <String, String>{
      if (perfil != null && perfil!.trim().isNotEmpty)
        'GOOGLE_WORKSPACE_CLI_CONFIG_DIR': perfil!.trim(),
    };
    final ProcessResult r;
    try {
      r = await _correr('gws', ['auth', 'export', '--unmasked'], entorno);
    } on ProcessException {
      throw ErrorSesionDrive('No encontré el programa gws en este equipo. '
          'Hace falta para hablar con Google Drive.');
    }
    if (r.exitCode != 0) {
      throw ErrorSesionDrive('gws no tiene una sesión iniciada en este perfil. '
          'Corre `gws auth login` o elige otro perfil.');
    }
    try {
      final j = jsonDecode('${r.stdout}'.trim()) as Map<String, dynamic>;
      for (final campo in ['client_id', 'client_secret', 'refresh_token']) {
        if ((j[campo] as String?)?.isNotEmpty != true) throw const FormatException();
      }
      return j;
    } on FormatException {
      throw ErrorSesionDrive('gws respondió algo que no entiendo al pedir la sesión. '
          'Revisa que el perfil elegido sea el correcto.');
    }
  }
}

/// Lo que importa de un archivo en Drive para decidir si ya está respaldado.
class ArchivoDrive {
  const ArchivoDrive({
    required this.id,
    required this.nombre,
    required this.tamano,
    this.md5,
    this.enPapelera = false,
  });

  final String id;
  final String nombre;
  final int tamano;

  /// El MD5 que calcula Drive del contenido. Es lo que prueba que la copia es idéntica.
  final String? md5;
  final bool enPapelera;

  factory ArchivoDrive.deJson(Map<String, dynamic> j) => ArchivoDrive(
        id: j['id'] as String,
        nombre: (j['name'] as String?) ?? '',
        tamano: int.tryParse('${j['size'] ?? ''}') ?? -1,
        md5: (j['md5Checksum'] as String?)?.toLowerCase(),
        enPapelera: j['trashed'] == true,
      );
}

/// Las pocas llamadas a Drive que necesita el respaldo, a mano sobre `http`.
///
/// No se suma la librería de Google: son cuatro llamadas, y la subida reanudable hecha a
/// mano es justamente lo que permite mostrar el avance byte a byte y retomar un video de
/// cientos de megas después de un corte.
class DriveCliente {
  DriveCliente({
    required this.tokens,
    http.Client? cliente,
    this.tamanoBloque = 16 * 1024 * 1024,
    this.esperaEntreReintentos = const Duration(seconds: 2),
  })  : assert(tamanoBloque % (256 * 1024) == 0,
            'Drive exige bloques múltiplos de 256 KiB'),
        _cliente = cliente ?? http.Client();

  final ProveedorTokenDrive tokens;
  final http.Client _cliente;
  final int tamanoBloque;
  final Duration esperaEntreReintentos;

  static const _api = 'https://www.googleapis.com/drive/v3';
  static const _subida = 'https://www.googleapis.com/upload/drive/v3';
  static const _campos = 'id,name,size,md5Checksum,trashed';
  static const _reintentos = 5;

  Future<Map<String, String>> _cabeceras([Map<String, String>? extra]) async => {
        'Authorization': 'Bearer ${await tokens.token()}',
        ...?extra,
      };

  /// Hace la llamada y, si el token venció en el camino, la repite una vez con otro.
  Future<http.Response> _pedir(
      Future<http.Response> Function(Map<String, String> cabeceras) llamada,
      [Map<String, String>? extra]) async {
    var r = await llamada(await _cabeceras(extra));
    if (r.statusCode == 401) {
      tokens.invalidar();
      r = await llamada(await _cabeceras(extra));
    }
    return r;
  }

  /// El nombre de una carpeta, o error si no existe o no se puede ver.
  Future<String> nombreCarpeta(String id) async {
    final r = await _pedir((c) => _cliente.get(
        Uri.parse('$_api/files/$id?fields=id,name,mimeType,trashed&supportsAllDrives=true'),
        headers: c));
    if (r.statusCode == 404) throw ErrorDrive('No encuentro esa carpeta en Drive.');
    _exigirOk(r, 'leer la carpeta de Drive');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    if (j['mimeType'] != 'application/vnd.google-apps.folder') {
      throw ErrorDrive('Eso es un archivo, no una carpeta de Drive.');
    }
    return j['name'] as String;
  }

  /// Un archivo con ese nombre dentro de la carpeta, si hay.
  Future<List<ArchivoDrive>> buscar(String carpetaId, String nombre) async {
    final nombreEscapado = nombre.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
    final uri = Uri.parse('$_api/files').replace(queryParameters: {
      'q': "name = '$nombreEscapado' and '$carpetaId' in parents and trashed = false",
      'fields': 'files($_campos)',
      'supportsAllDrives': 'true',
      'includeItemsFromAllDrives': 'true',
    });
    final r = await _pedir((c) => _cliente.get(uri, headers: c));
    _exigirOk(r, 'buscar en Drive');
    final lista = (jsonDecode(r.body) as Map<String, dynamic>)['files'] as List;
    return [for (final f in lista) ArchivoDrive.deJson(f as Map<String, dynamic>)];
  }

  /// Mueve un archivo de carpeta dentro de Drive, sin volver a subirlo.
  Future<void> mover(String id, {required String desde, required String hacia}) async {
    final uri = Uri.parse('$_api/files/$id').replace(queryParameters: {
      'addParents': hacia,
      'removeParents': desde,
      'supportsAllDrives': 'true',
      'fields': 'id',
    });
    final r = await _pedir((c) => _cliente.patch(uri, headers: c, body: '{}'),
        {'Content-Type': 'application/json; charset=UTF-8'});
    _exigirOk(r, 'mover el archivo en Drive');
  }

  /// El id de una carpeta con ese nombre en la raíz de Drive; si no existe, la crea.
  Future<String> carpetaEnRaiz(String nombre) async {
    final nombreEscapado = nombre.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
    final uri = Uri.parse('$_api/files').replace(queryParameters: {
      'q': "name = '$nombreEscapado' and 'root' in parents and trashed = false "
          "and mimeType = 'application/vnd.google-apps.folder'",
      'fields': 'files(id)',
    });
    final r = await _pedir((c) => _cliente.get(uri, headers: c));
    _exigirOk(r, 'buscar la carpeta de respaldo en Drive');
    final lista = (jsonDecode(r.body) as Map<String, dynamic>)['files'] as List;
    if (lista.isNotEmpty) return (lista.first as Map<String, dynamic>)['id'] as String;

    final creada = await _pedir(
      (c) => _cliente.post(Uri.parse('$_api/files?fields=id'),
          headers: c,
          body: jsonEncode({
            'name': nombre,
            'mimeType': 'application/vnd.google-apps.folder',
          })),
      {'Content-Type': 'application/json; charset=UTF-8'},
    );
    _exigirOk(creada, 'crear la carpeta de respaldo en Drive');
    return (jsonDecode(creada.body) as Map<String, dynamic>)['id'] as String;
  }

  /// El archivo tal como está hoy en Drive, o `null` si ya no existe.
  Future<ArchivoDrive?> obtener(String id) async {
    final r = await _pedir((c) => _cliente.get(
        Uri.parse('$_api/files/$id?fields=$_campos&supportsAllDrives=true'),
        headers: c));
    if (r.statusCode == 404) return null;
    _exigirOk(r, 'consultar el archivo en Drive');
    return ArchivoDrive.deJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// Sube [archivo] a la carpeta con subida reanudable, bloque a bloque.
  ///
  /// [sesionPrevia] retoma una subida que quedó a medias. [alAbrirSesion] entrega la
  /// dirección de la sesión apenas existe, para guardarla. [alAvanzar] recibe los bytes
  /// que Drive ya confirmó. Si [cancelar] devuelve `true` se detiene entre bloques y la
  /// sesión queda viva para retomarla.
  Future<ArchivoDrive> subir(
    File archivo,
    String carpetaId, {
    String? sesionPrevia,
    void Function(String sesion)? alAbrirSesion,
    void Function(int enviados, int total)? alAvanzar,
    bool Function()? cancelar,
  }) async {
    final total = await archivo.length();
    var sesion = sesionPrevia;
    var desde = 0;

    if (sesion != null) {
      final estado = await _consultarSesion(sesion, total);
      if (estado.terminado != null) return estado.terminado!;
      if (estado.vencida) {
        sesion = null;
      } else {
        desde = estado.recibidos;
      }
    }
    if (sesion == null) {
      sesion = await _abrirSesion(archivo, carpetaId, total);
      alAbrirSesion?.call(sesion);
    }
    alAvanzar?.call(desde, total);

    final lector = await archivo.open();
    try {
      var fallas = 0;
      while (true) {
        if (cancelar?.call() == true) throw SubidaCancelada();
        final hasta = min(desde + tamanoBloque, total);
        await lector.setPosition(desde);
        final bloque = await lector.read(hasta - desde);

        http.Response r;
        try {
          r = await _cliente.put(Uri.parse(sesion), body: bloque, headers: {
            'Content-Range': total == 0
                ? 'bytes */0'
                : 'bytes $desde-${desde + bloque.length - 1}/$total',
          });
        } on IOException {
          r = http.Response('', 503);
        } on http.ClientException {
          r = http.Response('', 503);
        }

        if (r.statusCode == 200 || r.statusCode == 201) {
          alAvanzar?.call(total, total);
          return ArchivoDrive.deJson(jsonDecode(r.body) as Map<String, dynamic>);
        }
        if (r.statusCode == 308) {
          fallas = 0;
          desde = _recibidos(r);
          alAvanzar?.call(desde, total);
          continue;
        }
        if (r.statusCode == 404 || r.statusCode == 410) {
          throw ErrorDrive('Drive cerró la subida a medias; se reintenta desde cero.');
        }
        // Un corte de red o un 5xx: se pregunta a Drive cuánto alcanzó a recibir y se
        // sigue desde ahí, con esperas cada vez más largas.
        if (++fallas > _reintentos) {
          throw ErrorDrive('La subida falló varias veces seguidas '
              '(último código ${r.statusCode}). Se reintenta en la próxima pasada.');
        }
        await Future<void>.delayed(esperaEntreReintentos * fallas);
        final estado = await _consultarSesion(sesion, total);
        if (estado.terminado != null) return estado.terminado!;
        if (estado.vencida) {
          throw ErrorDrive('Drive cerró la subida a medias; se reintenta desde cero.');
        }
        desde = estado.recibidos;
      }
    } finally {
      await lector.close();
    }
  }

  Future<String> _abrirSesion(File archivo, String carpetaId, int total) async {
    final nombre = archivo.uri.pathSegments.last;
    final r = await _pedir(
      (c) => _cliente.post(
        Uri.parse('$_subida/files?uploadType=resumable&supportsAllDrives=true'
            '&fields=$_campos'),
        headers: c,
        body: jsonEncode({
          'name': nombre,
          'parents': [carpetaId],
        }),
      ),
      {
        'Content-Type': 'application/json; charset=UTF-8',
        'X-Upload-Content-Length': '$total',
        'X-Upload-Content-Type': _tipo(nombre),
      },
    );
    _exigirOk(r, 'empezar la subida a Drive');
    final sesion = r.headers['location'];
    if (sesion == null) throw ErrorDrive('Drive no entregó dónde subir el archivo.');
    return sesion;
  }

  Future<_EstadoSesion> _consultarSesion(String sesion, int total) async {
    try {
      final r = await _cliente.put(Uri.parse(sesion),
          headers: {'Content-Range': 'bytes */$total'});
      if (r.statusCode == 200 || r.statusCode == 201) {
        return _EstadoSesion(
            terminado: ArchivoDrive.deJson(jsonDecode(r.body) as Map<String, dynamic>));
      }
      if (r.statusCode == 308) return _EstadoSesion(recibidos: _recibidos(r));
      if (r.statusCode == 404 || r.statusCode == 410) {
        return const _EstadoSesion(vencida: true);
      }
      throw ErrorDrive('Drive no dijo en qué va la subida (${r.statusCode}).');
    } on IOException {
      throw ErrorDrive('Sin conexión con Drive. Se reintenta en la próxima pasada.');
    } on http.ClientException {
      throw ErrorDrive('Sin conexión con Drive. Se reintenta en la próxima pasada.');
    }
  }

  /// `Range: bytes=0-N` dice que Drive tiene hasta el byte N. Sin cabecera, nada.
  static int _recibidos(http.Response r) {
    final rango = r.headers['range'];
    if (rango == null) return 0;
    final fin = int.tryParse(rango.split('-').last);
    return fin == null ? 0 : fin + 1;
  }

  static String _tipo(String nombre) {
    final ext = nombre.split('.').last.toLowerCase();
    return switch (ext) {
      'mp4' || 'm4v' => 'video/mp4',
      'mkv' => 'video/x-matroska',
      'mov' => 'video/quicktime',
      'webm' => 'video/webm',
      'avi' => 'video/x-msvideo',
      'wmv' => 'video/x-ms-wmv',
      'flv' => 'video/x-flv',
      _ => 'application/octet-stream',
    };
  }

  static void _exigirOk(http.Response r, String que) {
    if (r.statusCode >= 200 && r.statusCode < 300) return;
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw ErrorSesionDrive('Drive no me dejó $que (${r.statusCode}). '
          'Revisa que el perfil de gws sea de la cuenta dueña de la carpeta.');
    }
    throw ErrorDrive('No pude $que: Drive respondió ${r.statusCode}.');
  }
}

/// La subida se detuvo a pedido; la sesión sigue viva para retomarla.
class SubidaCancelada implements Exception {}

class _EstadoSesion {
  const _EstadoSesion({this.recibidos = 0, this.terminado, this.vencida = false});
  final int recibidos;
  final ArchivoDrive? terminado;
  final bool vencida;
}
