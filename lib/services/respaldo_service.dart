import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/archivo_respaldo.dart';
import '../models/item_granolazo.dart';
import 'ajustes_service.dart';
import 'drive_cliente.dart';

/// Lo que pasó al liberar espacio.
class ResultadoLiberar {
  const ResultadoLiberar({
    required this.liberados,
    required this.bytes,
    required this.fallidos,
  });

  final int liberados;
  final int bytes;

  /// Nombre del archivo → por qué no se borró.
  final Map<String, String> fallidos;
}

/// Respalda en Drive una carpeta del equipo y, cuando se pide, libera el espacio.
///
/// Recorre la carpeta cada [intervalo], encola los videos nuevos y los sube de a uno, del
/// más viejo al más nuevo. Recuerda lo que ya subió en un JSON propio, así que un reinicio
/// no vuelve a subir nada. Antes de subir pregunta a Drive si ya hay un archivo con el
/// mismo nombre y tamaño en la carpeta: lo que se subió a mano antes no se duplica.
///
/// Con [transcribir] encendido los videos van a la carpeta que vigila el worker de
/// Granolazo, que los transcribe; lo que ya estaba respaldado en otra carpeta se mueve ahí
/// dentro de Drive, sin volver a subirlo. Apagado, van a una carpeta de solo respaldo.
///
/// Borrar del disco nunca es automático. Es un botón, y antes de borrar cada archivo se
/// vuelve a comprobar en Drive que sigue ahí, fuera de la papelera y con el mismo MD5.
class RespaldoService extends ChangeNotifier {
  RespaldoService({
    AjustesService? ajustes,
    DriveCliente Function(String perfilGws)? crearDrive,
    Future<File> Function()? archivoEstado,
    DateTime Function()? ahora,
    Future<Map<String, ItemGranolazo>> Function(List<String> idsDrive)?
        consultarTranscripciones,
    this.intervalo = const Duration(minutes: 10),
    this.reposo = const Duration(minutes: 2),
  })  : _ajustes = ajustes ?? AjustesService(),
        _crearDrive = crearDrive ??
            ((perfil) => DriveCliente(tokens: TokenDesdeGws(perfil: perfil))),
        _archivoEstado = archivoEstado ?? _archivoEstadoPorDefecto,
        _ahora = ahora ?? DateTime.now,
        // Dart no admite parámetros con nombre que empiecen con guion bajo.
        // ignore: prefer_initializing_formals
        _consultarTranscripciones = consultarTranscripciones;

  final AjustesService _ajustes;
  final Future<Map<String, ItemGranolazo>> Function(List<String> idsDrive)?
      _consultarTranscripciones;
  final DriveCliente Function(String perfilGws) _crearDrive;
  final Future<File> Function() _archivoEstado;
  final DateTime Function() _ahora;

  /// Cada cuánto se revisa la carpeta con el respaldo encendido.
  final Duration intervalo;

  /// Cuánto tiene que llevar un archivo sin cambiar para subirlo. OBS escribe el video
  /// mientras graba: subirlo antes de que termine dejaría en Drive un video cortado.
  final Duration reposo;

  /// Las extensiones que se respaldan.
  static const extensiones = {
    'mp4', 'mkv', 'mov', 'avi', 'webm', 'm4v', 'wmv', 'flv', //
  };

  bool _activo = false;
  String _carpetaLocal = '';
  bool _transcribir = false;

  /// La carpeta de solo respaldo. Vacía = la de por defecto, que se crea al primer video.
  String _carpetaRespaldo = '';
  String? _nombreCarpetaDrive;
  String _perfilGws = '';

  List<ArchivoRespaldo> _archivos = const [];
  bool _cargado = false;
  bool _revisando = false;
  bool _liberando = false;
  bool _inventariando = false;
  bool _cerrado = false;
  bool _detener = false;
  String? _errorGeneral;
  DateTime? _ultimaRevision;
  String? _subiendo;
  Timer? _reloj;
  DriveCliente? _drive;
  DateTime _ultimoAviso = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _escritura = Future.value();
  Map<String, ItemGranolazo> _transcripciones = const {};

  bool get activo => _activo;
  String get carpetaLocal => _carpetaLocal;
  bool get transcribir => _transcribir;

  /// La carpeta a la que van los videos ahora. Vacía si todavía no se creó la de respaldo.
  String get carpetaDrive =>
      _transcribir ? AjustesService.carpetaDriveObs : _carpetaRespaldo;

  /// En qué va la transcripción de un video, si Granolazo ya lo tomó.
  ItemGranolazo? transcripcionDe(ArchivoRespaldo a) =>
      a.driveId == null ? null : _transcripciones[a.driveId];

  /// ¿Este video está en la carpeta que transcribe Granolazo?
  bool vaATranscribirse(ArchivoRespaldo a) =>
      a.carpetaDrive == AjustesService.carpetaDriveObs;
  String? get nombreCarpetaDrive => _nombreCarpetaDrive;
  String get perfilGws => _perfilGws;
  bool get cargado => _cargado;
  bool get revisando => _revisando;
  bool get liberando => _liberando;
  String? get errorGeneral => _errorGeneral;
  DateTime? get ultimaRevision => _ultimaRevision;

  /// Todos los archivos conocidos, lo más nuevo primero.
  List<ArchivoRespaldo> get archivos => _archivos;

  ArchivoRespaldo? get enCurso {
    final ruta = _subiendo;
    if (ruta == null) return null;
    for (final a in _archivos) {
      if (a.ruta == ruta) return a;
    }
    return null;
  }

  Iterable<ArchivoRespaldo> _con(EstadoRespaldo e) => _archivos.where((a) => a.estado == e);
  List<ArchivoRespaldo> get pendientes => _con(EstadoRespaldo.pendiente).toList();
  List<ArchivoRespaldo> get conError => _con(EstadoRespaldo.error).toList();
  List<ArchivoRespaldo> get respaldados => _con(EstadoRespaldo.respaldado).toList();
  List<ArchivoRespaldo> get liberados => _con(EstadoRespaldo.liberado).toList();

  /// Lo que ya está a salvo en Drive y todavía ocupa lugar en el disco.
  int get bytesLiberables => respaldados.fold(0, (s, a) => s + a.tamano);
  int get bytesPendientes => [...pendientes, ...conError, ?enCurso]
      .fold(0, (s, a) => s + a.tamano - a.enviados);
  int get bytesLiberadosTotal => liberados.fold(0, (s, a) => s + a.tamano);

  DriveCliente get _cliente => _drive ??= _crearDrive(_perfilGws);

  // ── ciclo de vida ────────────────────────────────────────────────────────────

  /// Lee ajustes y lo que ya se sabía. No toca la red ni el disco vigilado.
  Future<void> cargar() async {
    _activo = await _ajustes.leerRespaldoActivo();
    _carpetaLocal = await _ajustes.leerRespaldoCarpetaLocal();
    _carpetaRespaldo = await _ajustes.leerRespaldoCarpetaDrive();
    _transcribir = await _ajustes.leerRespaldoTranscribir();
    _perfilGws = await _ajustes.leerRespaldoPerfilGws();
    _archivos = await _leerEstado();
    _cargado = true;
    notifyListeners();
  }

  /// Carga y, si el respaldo está encendido, arranca el reloj y hace una primera pasada.
  Future<void> iniciar() async {
    await cargar();
    _programar();
    if (_activo) unawaited(revisarAhora());
  }

  void _programar() {
    _reloj?.cancel();
    _reloj = _activo ? Timer.periodic(intervalo, (_) => revisarAhora()) : null;
  }

  @override
  void dispose() {
    _cerrado = true;
    _reloj?.cancel();
    _detener = true;
    super.dispose();
  }

  /// Una subida en vuelo puede terminar después de cerrar la app: ahí ya no hay a quién
  /// avisar.
  @override
  void notifyListeners() {
    if (!_cerrado) super.notifyListeners();
  }

  // ── ajustes ──────────────────────────────────────────────────────────────────

  /// Enciende o apaga el respaldo. Con [revisar] en falso solo guarda el ajuste: es lo
  /// que usa la consola, que termina antes de que una subida alcance a avanzar.
  Future<void> activar(bool valor, {bool revisar = true}) async {
    _activo = valor;
    await _ajustes.guardarRespaldoActivo(valor);
    if (revisar) _programar();
    if (!valor) _detener = true;
    notifyListeners();
    if (valor && revisar) unawaited(revisarAhora());
  }

  Future<void> cambiarCarpetaLocal(String ruta) async {
    if (!await Directory(ruta).exists()) {
      throw ErrorDrive('La carpeta $ruta no existe en este equipo.');
    }
    _carpetaLocal = ruta;
    await _ajustes.guardarRespaldoCarpetaLocal(ruta);
    notifyListeners();
  }

  /// Cambia la carpeta de solo respaldo. Acepta el id o el enlace, y comprueba que se ve
  /// desde la cuenta.
  Future<void> cambiarCarpetaDrive(String idOEnlace) async {
    final id = idDeCarpeta(idOEnlace);
    if (id == null) throw ErrorDrive('Eso no parece un enlace ni un id de carpeta.');
    if (id == AjustesService.carpetaDriveObs) {
      throw ErrorDrive('Esa es la carpeta que transcribe Granolazo. Para mandar los '
          'videos ahí, enciende "Transcribir en Granolazo".');
    }
    final nombre = await _cliente.nombreCarpeta(id);
    _carpetaRespaldo = id;
    if (!_transcribir) _nombreCarpetaDrive = nombre;
    await _ajustes.guardarRespaldoCarpetaDrive(id);
    notifyListeners();
  }

  /// Enciende o apaga la transcripción. Al encenderla, la próxima pasada mueve a la
  /// carpeta de Granolazo lo que ya estaba respaldado en la otra.
  Future<void> activarTranscripcion(bool valor, {bool revisar = true}) async {
    _transcribir = valor;
    _nombreCarpetaDrive = null;
    await _ajustes.guardarRespaldoTranscribir(valor);
    notifyListeners();
    if (!revisar) return;
    await comprobarDrive();
    if (valor) unawaited(revisarAhora());
  }

  Future<void> cambiarPerfilGws(String ruta) async {
    _perfilGws = ruta.trim();
    _drive = null;
    _nombreCarpetaDrive = null;
    _errorGeneral = null;
    await _ajustes.guardarRespaldoPerfilGws(_perfilGws);
    notifyListeners();
  }

  /// Comprueba la conexión con Drive leyendo el nombre de la carpeta de destino.
  Future<void> comprobarDrive() async {
    try {
      final destino = carpetaDrive;
      _nombreCarpetaDrive = destino.isEmpty
          ? '${AjustesService.nombreCarpetaRespaldo} (se crea con el primer video)'
          : await _cliente.nombreCarpeta(destino);
      _errorGeneral = null;
    } on ErrorDrive catch (e) {
      _errorGeneral = e.mensaje;
    }
    notifyListeners();
  }

  /// `https://drive.google.com/drive/folders/<id>?...` o el id suelto.
  static String? idDeCarpeta(String texto) {
    final t = texto.trim();
    final enlace = RegExp(r'folders/([A-Za-z0-9_-]{10,})').firstMatch(t);
    if (enlace != null) return enlace.group(1);
    final id = RegExp(r'[?&]id=([A-Za-z0-9_-]{10,})').firstMatch(t);
    if (id != null) return id.group(1);
    return RegExp(r'^[A-Za-z0-9_-]{10,}$').hasMatch(t) ? t : null;
  }

  // ── la pasada ────────────────────────────────────────────────────────────────

  /// Detiene la subida en curso al terminar el bloque que va; se retoma desde ahí.
  void detenerSubida() {
    _detener = true;
  }

  /// Recorre la carpeta y sube lo que falta. Si ya hay una pasada corriendo, no hace nada.
  Future<void> revisarAhora() async {
    // Nunca a la vez que se libera espacio: las dos cambian el estado de los mismos
    // archivos y una pisaría lo que escribió la otra.
    if (_revisando || _liberando || _cerrado) return;
    _revisando = true;
    _detener = false;
    _errorGeneral = null;
    notifyListeners();
    try {
      _inventariando = true;
      try {
        await _inventariar();
      } finally {
        _inventariando = false;
      }
      await _subirPendientes();
      await _mandarATranscribir();
      await actualizarTranscripciones(avisar: false);
    } on ErrorSesionDrive catch (e) {
      _errorGeneral = e.mensaje;
    } on FileSystemException catch (e) {
      _errorGeneral = 'No pude leer la carpeta $_carpetaLocal: ${e.message}';
    } finally {
      _subiendo = null;
      _revisando = false;
      _ultimaRevision = _ahora();
      await _guardarEstado();
      notifyListeners();
    }
  }

  /// Cruza lo que hay en el disco con lo que ya se sabía.
  Future<void> _inventariar() async {
    final dir = Directory(_carpetaLocal);
    if (_carpetaLocal.isEmpty || !await dir.exists()) {
      throw FileSystemException('la carpeta no existe', _carpetaLocal);
    }
    final enDisco = <String, FileStat>{};
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final nombre = e.uri.pathSegments.last;
      if (nombre.startsWith('.')) continue;
      final ext = nombre.contains('.') ? nombre.split('.').last.toLowerCase() : '';
      if (!extensiones.contains(ext)) continue;
      final st = await e.stat();
      if (st.size == 0) continue; // un archivo vacío no es un video que valga respaldar
      enDisco[e.path] = st;
    }

    final previos = {for (final a in _archivos) a.ruta: a};
    final nuevos = <ArchivoRespaldo>[];
    for (final MapEntry(key: ruta, value: st) in enDisco.entries) {
      final antes = previos.remove(ruta);
      nuevos.add(_conciliar(antes, ruta, st));
    }
    // Lo que ya no está en el disco: si estaba en Drive, el espacio ya está libre; si no
    // alcanzó a subirse, se olvida.
    for (final a in previos.values) {
      if (a.estado == EstadoRespaldo.liberado) {
        nuevos.add(a);
      } else if (a.estado == EstadoRespaldo.respaldado) {
        nuevos.add(a.copiar(estado: EstadoRespaldo.liberado, liberadoEn: _ahora()));
      }
    }
    nuevos.sort((a, b) => b.modificado.compareTo(a.modificado));
    _archivos = List.unmodifiable(nuevos);
  }

  ArchivoRespaldo _conciliar(ArchivoRespaldo? antes, String ruta, FileStat st) {
    final nuevo = ArchivoRespaldo(
      ruta: ruta,
      nombre: File(ruta).uri.pathSegments.last,
      tamano: st.size,
      modificado: st.modified,
    );
    if (antes == null) return nuevo;
    final igual = antes.tamano == st.size && antes.modificado == st.modified;
    switch (antes.estado) {
      case EstadoRespaldo.respaldado:
      case EstadoRespaldo.liberado:
        // Solo sigue respaldado si es exactamente el mismo archivo. Si reapareció o se
        // reescribió, vuelve a la cola: la pasada lo compara por MD5 con lo que hay en
        // Drive y no lo sube de nuevo si ya está idéntico.
        if (igual) return antes.copiar(estado: EstadoRespaldo.respaldado);
        return nuevo;
      case EstadoRespaldo.pendiente:
      case EstadoRespaldo.subiendo:
      case EstadoRespaldo.error:
        // Si cambió mientras esperaba, la subida a medias ya no sirve.
        return igual ? antes : nuevo;
    }
  }

  /// La carpeta a la que van los videos ahora; crea la de respaldo si todavía no existe.
  Future<String> _destino() async {
    if (_transcribir) return AjustesService.carpetaDriveObs;
    if (_carpetaRespaldo.isEmpty) {
      _carpetaRespaldo = await _cliente.carpetaEnRaiz(AjustesService.nombreCarpetaRespaldo);
      _nombreCarpetaDrive = AjustesService.nombreCarpetaRespaldo;
      await _ajustes.guardarRespaldoCarpetaDrive(_carpetaRespaldo);
    }
    return _carpetaRespaldo;
  }

  Future<void> _subirPendientes() async {
    final ahora = _ahora();
    final cola = _archivos
        .where((a) =>
            a.estado == EstadoRespaldo.pendiente || a.estado == EstadoRespaldo.error)
        .where((a) => ahora.difference(a.modificado) >= reposo)
        .toList()
      ..sort((a, b) => a.modificado.compareTo(b.modificado));

    if (cola.isEmpty) return;
    final destino = await _destino();
    for (final a in cola) {
      if (_detener) break;
      await _respaldar(a, destino);
      await _guardarEstado();
    }
  }

  /// Con la transcripción encendida, mueve a la carpeta de Granolazo lo que ya estaba
  /// respaldado en otra. Incluye lo que ya se liberó del equipo: sigue en Drive.
  Future<void> _mandarATranscribir() async {
    if (!_transcribir) return;
    const obs = AjustesService.carpetaDriveObs;
    final porMover = _archivos
        .where((a) =>
            (a.estado == EstadoRespaldo.respaldado ||
                a.estado == EstadoRespaldo.liberado) &&
            a.driveId != null &&
            a.carpetaDrive != null &&
            a.carpetaDrive != obs)
        .toList();
    for (final a in porMover) {
      if (_detener) break;
      try {
        await _cliente.mover(a.driveId!, desde: a.carpetaDrive!, hacia: obs);
        _reemplazar(_actual(a).copiar(carpetaDrive: obs, limpiarError: true));
      } on ErrorSesionDrive {
        rethrow;
      } on ErrorDrive catch (e) {
        _reemplazar(
            _actual(a).copiar(error: 'No pude mandarlo a transcribir: ${e.mensaje}'));
      }
    }
  }

  /// Pregunta a Granolazo en qué va la transcripción de lo que está en su carpeta.
  Future<void> actualizarTranscripciones({bool avisar = true}) async {
    final consultar = _consultarTranscripciones;
    if (consultar == null) return;
    final ids = [
      for (final a in _archivos)
        if (a.driveId != null && vaATranscribirse(a)) a.driveId!,
    ];
    if (ids.isEmpty) return;
    try {
      _transcripciones = Map.unmodifiable(await consultar(ids));
    } catch (e) {
      // Sin backend de Granolazo el respaldo sigue funcionando; solo falta el dato.
      debugPrint('respaldo: no pude leer las transcripciones: $e');
    }
    if (avisar) notifyListeners();
  }

  Future<void> _respaldar(ArchivoRespaldo a, String destino) async {
    _subiendo = a.ruta;
    _reemplazar(a.copiar(estado: EstadoRespaldo.subiendo, limpiarError: true));
    try {
      if (a.sesionSubida == null) {
        // Se busca también en la carpeta de Granolazo: lo que ya se subió ahí a mano no
        // hace falta tenerlo dos veces, y además ya está transcrito.
        for (final carpeta in {destino, AjustesService.carpetaDriveObs}) {
          final yaEsta = await _cliente.buscar(carpeta, a.nombre);
          final candidatos = yaEsta.where((f) => f.tamano == a.tamano).toList();
          if (candidatos.isEmpty) continue;
          final local = await md5DeArchivo(File(a.ruta));
          final igual = candidatos.where((f) => f.md5 == local).firstOrNull;
          if (igual != null) {
            _marcarRespaldado(a, igual.id, carpeta);
            return;
          }
        }
      }
      // Una subida retomada termina en la carpeta con la que se abrió la sesión.
      final carpeta = a.sesionSubida != null && a.carpetaDrive != null
          ? a.carpetaDrive!
          : destino;
      final subido = await _cliente.subir(
        File(a.ruta),
        carpeta,
        sesionPrevia: a.sesionSubida,
        alAbrirSesion: (s) {
          _reemplazar(_actual(a).copiar(sesionSubida: s, carpetaDrive: carpeta));
          unawaited(_guardarEstado());
        },
        alAvanzar: (enviados, _) {
          _reemplazar(_actual(a).copiar(enviados: enviados), avisar: false);
          _avisarCadaTanto();
        },
        cancelar: () => _detener,
      );
      if (subido.tamano != a.tamano ||
          subido.md5 != await md5DeArchivo(File(a.ruta))) {
        _reemplazar(_actual(a).copiar(
          estado: EstadoRespaldo.error,
          error: 'La copia en Drive no quedó idéntica al archivo '
              '(${tamanoLegible(subido.tamano)} de ${tamanoLegible(a.tamano)}). '
              'Se vuelve a subir.',
          limpiarSesion: true,
        ));
        return;
      }
      _marcarRespaldado(a, subido.id, carpeta);
    } on SubidaCancelada {
      _reemplazar(_actual(a).copiar(estado: EstadoRespaldo.pendiente));
    } on ErrorSesionDrive {
      _reemplazar(_actual(a).copiar(estado: EstadoRespaldo.pendiente));
      rethrow;
    } on ErrorDrive catch (e) {
      final cerrada = e.mensaje.contains('desde cero');
      _reemplazar(_actual(a).copiar(
        estado: EstadoRespaldo.error,
        error: e.mensaje,
        limpiarSesion: cerrada,
      ));
    } on FileSystemException catch (e) {
      _reemplazar(_actual(a).copiar(
        estado: EstadoRespaldo.error,
        error: 'No pude leer el archivo: ${e.message}',
      ));
    } finally {
      _subiendo = null;
    }
  }

  void _marcarRespaldado(ArchivoRespaldo a, String driveId, String carpeta) {
    _reemplazar(_actual(a).copiar(
      estado: EstadoRespaldo.respaldado,
      driveId: driveId,
      carpetaDrive: carpeta,
      enviados: a.tamano,
      respaldadoEn: _ahora(),
      limpiarError: true,
      limpiarSesion: true,
    ));
  }

  // ── liberar espacio ──────────────────────────────────────────────────────────

  /// Borra del disco lo que ya está respaldado, comprobando cada archivo en Drive antes.
  ///
  /// Se borra de verdad, no a la papelera: mandarlo a la papelera no libera nada hasta
  /// vaciarla, y el objetivo es justamente el espacio. La copia es la de Drive.
  Future<ResultadoLiberar> liberarEspacio({Set<String>? soloRutas}) async {
    // Se puede liberar mientras sube otro video: solo toca lo ya respaldado, cada cambio
    // va sobre el estado vigente de su archivo y antes de borrar se consulta a Drive. Lo
    // único que no puede pasar a la vez es el inventario, que reemplaza la lista entera;
    // dura un instante, así que se espera.
    if (_liberando) {
      throw ErrorDrive('Ya se está liberando espacio.');
    }
    _liberando = true;
    while (_inventariando) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    notifyListeners();
    try {
      return await _liberar(soloRutas);
    } finally {
      _liberando = false;
      await _guardarEstado();
      notifyListeners();
    }
  }

  Future<ResultadoLiberar> _liberar(Set<String>? soloRutas) async {
    var liberados = 0;
    var bytes = 0;
    final fallidos = <String, String>{};
    final candidatos = respaldados
        .where((a) => soloRutas == null || soloRutas.contains(a.ruta))
        .toList();

    for (final a in candidatos) {
      final id = a.driveId;
      try {
        final archivo = File(a.ruta);
        if (!await archivo.exists()) {
          _reemplazar(_actual(a).copiar(estado: EstadoRespaldo.liberado, liberadoEn: _ahora()));
          continue;
        }
        final local = await archivo.length();
        final remoto = id == null ? null : await _cliente.obtener(id);
        if (remoto == null || remoto.enPapelera) {
          _reemplazar(_actual(a).copiar(
            estado: EstadoRespaldo.pendiente,
            error: 'Ya no está en Drive; se vuelve a subir.',
          ));
          fallidos[a.nombre] = 'ya no está en Drive, se vuelve a subir';
          continue;
        }
        if (remoto.tamano != local || remoto.md5 != await md5DeArchivo(archivo)) {
          fallidos[a.nombre] = 'la copia de Drive no es idéntica a la del disco';
          continue;
        }
        await archivo.delete();
        liberados++;
        bytes += local;
        _reemplazar(_actual(a).copiar(estado: EstadoRespaldo.liberado, liberadoEn: _ahora()));
      } on ErrorDrive catch (e) {
        fallidos[a.nombre] = e.mensaje;
        if (e is ErrorSesionDrive) break;
      } on FileSystemException catch (e) {
        // Lo más común: el video está abierto en un reproductor.
        fallidos[a.nombre] = 'no se pudo borrar (${e.osError?.message ?? e.message})';
      }
    }
    return ResultadoLiberar(liberados: liberados, bytes: bytes, fallidos: fallidos);
  }

  /// El MD5 de un archivo, leyéndolo por partes: un video de gigas no pasa por memoria.
  static Future<String> md5DeArchivo(File f) async =>
      (await md5.bind(f.openRead()).first).toString();

  // ── estado ───────────────────────────────────────────────────────────────────

  ArchivoRespaldo _actual(ArchivoRespaldo a) =>
      _archivos.firstWhere((x) => x.ruta == a.ruta, orElse: () => a);

  void _reemplazar(ArchivoRespaldo nuevo, {bool avisar = true}) {
    _archivos = List.unmodifiable(
        [for (final a in _archivos) a.ruta == nuevo.ruta ? nuevo : a]);
    if (avisar) notifyListeners();
  }

  /// La barra de avance no necesita redibujarse por cada bloque de red.
  void _avisarCadaTanto() {
    final ahora = DateTime.now();
    if (ahora.difference(_ultimoAviso) < const Duration(milliseconds: 500)) return;
    _ultimoAviso = ahora;
    notifyListeners();
  }

  static Future<File> _archivoEstadoPorDefecto() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}respaldo_drive.json');
  }

  Future<List<ArchivoRespaldo>> _leerEstado() async {
    try {
      final f = await _archivoEstado();
      if (!await f.exists()) return const [];
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return List.unmodifiable([
        for (final a in (j['archivos'] as List? ?? const []))
          ArchivoRespaldo.deJson(a as Map<String, dynamic>),
      ]);
    } on FormatException {
      // Un JSON roto no puede dejar la app sin respaldo: se reconstruye preguntando a
      // Drive, que no duplica lo que ya tiene.
      return const [];
    }
  }

  /// Las escrituras van en fila: dos a la vez se pisarían el archivo temporal.
  Future<void> _guardarEstado() =>
      _escritura = _escritura.then((_) => _escribirEstado()).catchError((Object e) {
        debugPrint('respaldo: no pude guardar el estado: $e');
      });

  Future<void> _escribirEstado() async {
    final f = await _archivoEstado();
    await f.parent.create(recursive: true);
    final temporal = File('${f.path}.tmp');
    await temporal.writeAsString(jsonEncode({
      'archivos': [for (final a in _archivos) a.aJson()],
    }));
    await temporal.rename(f.path);
  }
}
