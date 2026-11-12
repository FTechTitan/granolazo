import 'dart:async';
import 'dart:math' as math;
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../en_vivo/coordinador_en_vivo.dart';
import '../models/grabacion.dart';
import '../services/ajustes_service.dart';
import '../services/grabador_service.dart';
import '../services/granolazo_api.dart';
import '../services/repositorio_grabaciones.dart';
import '../services/transcriptor.dart';
import '../services/transcriptor_local.dart';
import '../services/transcriptor_service.dart';

/// Orquesta el ciclo completo: grabar, transcribir, subir a Granolazo.
///
/// Toda la lógica de estado vive acá para que la UI sea solo presentación. La lista de
/// grabaciones se reemplaza entera en cada cambio en vez de mutarse, así no hay estados
/// intermedios raros.
class GrabacionesController extends ChangeNotifier {
  GrabacionesController({
    GrabadorService? grabador,
    Transcriptor? transcriptor,
    GranolazoApi? api,
    RepositorioGrabaciones? repositorio,
    AjustesService? ajustes,
    CoordinadorEnVivo? enVivo,
  })  : _grabador = grabador ?? GrabadorService(),
        _transcriptorForzado = transcriptor,
        _api = api ?? GranolazoApi(),
        _repo = repositorio ?? RepositorioGrabaciones(),
        _ajustes = ajustes ?? AjustesService(),
        enVivo = enVivo ?? CoordinadorEnVivo();

  final GrabadorService _grabador;

  /// El borrador de transcripción mientras se graba (opcional, apagado por defecto).
  /// La interfaz lo escucha para dibujar el texto; la grabación no depende de él.
  final CoordinadorEnVivo enVivo;

  /// Id con el que va a quedar la grabación en curso. Se fija al empezar para que el
  /// borrador en vivo (`en-vivo.json`) lo lleve y se pueda cruzar con la cola.
  String? _idEnCurso;

  /// Solo para los tests: si está, se usa en vez de elegir motor según los ajustes.
  final Transcriptor? _transcriptorForzado;
  final GranolazoApi _api;
  final RepositorioGrabaciones _repo;
  final AjustesService _ajustes;

  List<Grabacion> _grabaciones = const [];
  Duration _duracionActual = Duration.zero;
  double _nivelEntrada = -160;
  double _nivelSistema = -160;
  bool _cargando = true;
  bool _grabando = false;
  String? _aviso;
  StreamSubscription<Duration>? _subDuracion;
  StreamSubscription<double>? _subNivel;
  StreamSubscription<double>? _subNivelSistema;

  List<Grabacion> get grabaciones => _grabaciones;
  Duration get duracionActual => _duracionActual;

  /// Nivel de entrada del microfono en dBFS mientras se graba.
  double get nivelEntrada => _nivelEntrada;

  /// Nivel del audio que sale por los parlantes, en dBFS.
  double get nivelSistema => _nivelSistema;

  /// Cuánto se sube o baja cada fuente al mezclar. 1 es dejarla como está.
  double get gananciaMicrofono => _grabador.gananciaMicrofono;
  double get gananciaSistema => _grabador.gananciaSistema;

  /// El nivel del micrófono como va a quedar en la mezcla, con su ganancia aplicada.
  ///
  /// Es lo que hay que mirar para emparejar las dos: el nivel crudo no dice cómo van a
  /// sonar una al lado de la otra.
  double get nivelMicrofonoConGanancia =>
      _conGanancia(_nivelEntrada, _grabador.gananciaMicrofono);
  double get nivelSistemaConGanancia =>
      _conGanancia(_nivelSistema, _grabador.gananciaSistema);

  static double _conGanancia(double dbfs, double ganancia) {
    if (ganancia <= 0) return -160;
    // Multiplicar la amplitud por g equivale a sumar 20·log10(g) decibeles.
    return dbfs + 20 * (math.log(ganancia) / math.ln10);
  }

  Future<void> cambiarGananciaMicrofono(double v) async {
    _grabador.gananciaMicrofono = v;
    notifyListeners();
    await _ajustes.guardarGananciaMicrofono(v);
  }

  Future<void> cambiarGananciaSistema(double v) async {
    _grabador.gananciaSistema = v;
    notifyListeners();
    await _ajustes.guardarGananciaSistema(v);
  }

  /// ¿El microfono no esta entregando nada? Se mira en vivo, no al final.
  bool get sinSonidoEntrando =>
      _grabando && _nivelEntrada <= GrabadorService.umbralDeSilencio;

  /// ¿Se esta capturando lo que suena en el equipo?
  bool get capturandoSistema => _grabador.capturandoSistema;

  /// ¿Esta plataforma puede capturar la salida de audio?
  bool get puedeCapturarSistema => _grabador.puedeCapturarSistema;

  /// ¿Esa captura incluye la voz del otro en una llamada?
  bool get capturaLlamadas => _grabador.capturaLlamadas;

  /// Por que no se pudo capturar la salida, si no se pudo.
  String? get avisoSistema => _fallaDeCaptura ?? _grabador.avisoSistema;

  String? _fallaDeCaptura;

  /// En Android la captura de la salida se resuelve en dos tiempos: primero el usuario
  /// acepta el dialogo y recien despues el servicio intenta tomarla. Esperar a lo segundo
  /// para contestar retrasaria el microfono, que es lo unico que no se puede perder, asi
  /// que el fallo tardio llega por aca.
  void anotarFallaDeCaptura(String? motivo) {
    _fallaDeCaptura = motivo;
    _grabador.anotarFallaDeCaptura(motivo);
    notifyListeners();
  }
  bool get cargando => _cargando;
  bool get grabando => _grabando;
  String? get aviso => _aviso;

  /// Cuántas grabaciones todavía no llegaron a Granolazo: en espera, encoladas o en error.
  int get pendientes => _grabaciones.where((g) => g.estado.faltaProcesar).length;

  /// Cuántas están guardadas esperando que se decida transcribirlas.
  int get enEspera =>
      _grabaciones.where((g) => g.estado == EstadoGrabacion.enEspera).length;

  String get plataforma {
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'desconocida';
  }

  bool _cargado = false;

  Future<void> iniciar() async {
    await iniciarSinProcesar();
    unawaited(procesarPendientes());
  }

  /// Carga la cola desde disco sin arrancar el procesamiento.
  ///
  /// La interfaz quiere ponerse a trabajar sola al abrir; el modo consola no, porque ahí
  /// cada comando decide qué hace. Es idempotente: varios comandos seguidos la llaman.
  Future<void> iniciarSinProcesar() async {
    if (_cargado) return;
    _grabador.gananciaMicrofono = await _ajustes.leerGananciaMicrofono();
    _grabador.gananciaSistema = await _ajustes.leerGananciaSistema();
    _grabaciones = await _repo.cargar();
    await enVivo.cargar();
    _cargado = true;
    _cargando = false;
    notifyListeners();
  }

  void limpiarAviso() {
    _aviso = null;
    notifyListeners();
  }

  void _mostrar(String mensaje) {
    _aviso = mensaje;
    notifyListeners();
  }

  // ── grabación ────────────────────────────────────────────────────────────────

  Future<void> comenzarGrabacion() async {
    if (_grabando) return;
    try {
      await _grabador.iniciar();
      _idEnCurso = DateTime.now().toUtc().millisecondsSinceEpoch.toString();
      _grabando = true;
      _duracionActual = Duration.zero;
      _subDuracion = _grabador.duracion.listen((d) {
        _duracionActual = d;
        notifyListeners();
      });
      _subNivel = _grabador.nivel.listen((n) {
        _nivelEntrada = n;
        notifyListeners();
      });
      _subNivelSistema = _grabador.nivelSistema.listen((n) {
        _nivelSistema = n;
        notifyListeners();
      });
      notifyListeners();
      // Después de que el micrófono ya está grabando: el borrador es lo último que
      // arranca y no se espera, para no retrasar ni un instante la captura real.
      unawaited(enVivo.arrancar(
        idGrabacion: _idEnCurso!,
        rutaSistema: () => _grabador.rutaSistemaActual,
      ));
    } on StateError catch (e) {
      _mostrar(e.message);
    } catch (e) {
      _mostrar('no pude empezar a grabar: $e');
    }
  }

  Future<void> detenerGrabacion() async {
    if (!_grabando) return;
    final r = await _grabador.detener();
    // El audio real ya está a salvo; recién ahora se cierra el borrador (saca el último
    // trozo en segundo plano).
    unawaited(enVivo.parar());
    await _subDuracion?.cancel();
    _subDuracion = null;
    await _subNivel?.cancel();
    _subNivel = null;
    await _subNivelSistema?.cancel();
    _subNivelSistema = null;
    _nivelEntrada = -160;
    _nivelSistema = -160;
    _grabando = false;
    _duracionActual = Duration.zero;

    if (r == null || r.bytes == 0) {
      _mostrar('la grabación quedó vacía y se descartó');
      notifyListeners();
      return;
    }

    if (r.soloSistema) {
      _mostrar('el micrófono no entregó sonido, pero sí se capturó lo que sonaba en el '
          'equipo: la grabación sirve igual.');
    } else if (r.conSistema) {
      _mostrar('grabado el micrófono y el audio del equipo, mezclados');
    }
    if (r.mudo) {
      // Se conserva el archivo —puede que el medidor se equivoque y el audio sirva— pero
      // NO se transcribe sola: transcribir silencio produce texto inventado, y subirlo
      // ensucia Granolazo con una reunion que nunca existio.
      _mostrar('el micrófono no entregó sonido: revisá que no esté silenciado. '
          'La grabación quedó guardada, pero no se va a transcribir sola.');
    }

    final automatica = await _ajustes.leerTranscripcionAutomatica() && !r.mudo;
    final g = Grabacion(
      id: _idEnCurso ?? DateTime.now().toUtc().millisecondsSinceEpoch.toString(),
      rutaArchivo: r.ruta,
      grabadaEn: DateTime.now().subtract(r.duracion),
      // Sin transcripción automática la grabación queda guardada y nadie la toca: se
      // puede grabar sin clave, sin conexión y sin gastar, y decidir después.
      estado: automatica ? EstadoGrabacion.pendiente : EstadoGrabacion.enEspera,
      duracionSegundos: r.duracion.inSeconds,
      tamanoBytes: r.bytes,
      muda: r.mudo,
    );
    await _agregar(g);
    if (automatica) unawaited(procesarPendientes());
  }

  Future<void> cancelarGrabacion() async {
    if (!_grabando) return;
    await _grabador.cancelar();
    unawaited(enVivo.parar(vaciar: false));
    await _subDuracion?.cancel();
    _subDuracion = null;
    await _subNivel?.cancel();
    _subNivel = null;
    await _subNivelSistema?.cancel();
    _subNivelSistema = null;
    _nivelEntrada = -160;
    _nivelSistema = -160;
    _grabando = false;
    _duracionActual = Duration.zero;
    notifyListeners();
  }

  /// Extensiones de audio que la app sabe importar.
  static const extensionesAudio = ['m4a', 'mp3', 'wav', 'aac', 'ogg', 'opus', 'mp4'];

  /// Importa audios que ya están en el dispositivo, para no tener que regrabar lo que
  /// se capturó con otra app. Abre el selector de archivos del sistema.
  Future<void> importarDelDispositivo() async {
    final seleccion = await FilePicker.pickFiles(
      dialogTitle: 'Elige los audios a importar',
      type: FileType.custom,
      allowedExtensions: extensionesAudio,
    );
    if (seleccion.isEmpty) return;

    final rutas = [
      for (final f in seleccion)
        if (f.path != null) f.path!
    ];
    final agregadas = await importarRutas(rutas);
    if (agregadas > 0) {
      _mostrar('importados $agregadas audios');
      if (await _ajustes.leerTranscripcionAutomatica()) {
        unawaited(procesarPendientes());
      }
    }
  }

  /// Encola audios que ya están en el disco y devuelve cuántos entraron.
  ///
  /// Separado del selector de archivos a propósito: lo usan tanto la interfaz como el
  /// modo consola, que no tiene diálogos. No dispara el procesamiento por su cuenta —
  /// quien llama decide cuándo.
  Future<int> importarRutas(Iterable<String> rutas) async {
    final automatica = await _ajustes.leerTranscripcionAutomatica();
    var agregadas = 0;
    for (final ruta in rutas) {
      final archivo = File(ruta);
      if (!await archivo.exists()) continue;
      final stat = await archivo.stat();
      final g = Grabacion(
        id: '${DateTime.now().toUtc().millisecondsSinceEpoch}-$agregadas',
        rutaArchivo: ruta,
        // Fecha real del archivo, no la de importación: si no, todo lo importado
        // aparecería como de hoy y el orden en Granolazo quedaría mal.
        grabadaEn: stat.modified,
        estado: automatica ? EstadoGrabacion.pendiente : EstadoGrabacion.enEspera,
        titulo: _tituloDesdeNombre(_nombreDeArchivo(ruta)),
        tamanoBytes: stat.size,
        importada: true,
      );
      await _agregar(g);
      agregadas++;
    }
    return agregadas;
  }

  String _nombreDeArchivo(String ruta) {
    final corte = ruta.lastIndexOf(RegExp(r'[\\/]'));
    return corte < 0 ? ruta : ruta.substring(corte + 1);
  }

  String _tituloDesdeNombre(String nombre) {
    final sinExt = nombre.contains('.')
        ? nombre.substring(0, nombre.lastIndexOf('.'))
        : nombre;
    return sinExt.replaceAll('_', ' ').replaceAll('-', ' ').trim();
  }

  // ── procesamiento ────────────────────────────────────────────────────────────

  /// Arma el transcriptor según lo configurado, o explica por qué no se puede.
  ///
  /// Devuelve `null` y deja el motivo en [aviso] cuando falta algo: la clave si el motor
  /// es el servicio en línea, o el modelo bajado si es el procesador de este equipo.
  Future<Transcriptor?> _armarTranscriptor({bool avisar = true}) async {
    if (_transcriptorForzado != null) return _transcriptorForzado;

    final motor = await _ajustes.leerMotorTranscripcion();
    if (motor == 'api') {
      final clave = await _ajustes.leerClaveTranscripcion();
      if (clave == null) {
        if (avisar) _mostrar('falta la clave del servicio de transcripción');
        return null;
      }
      return TranscriptorService(clave: clave);
    }

    final local = TranscriptorLocal(
      modelo: ModeloLocal.desdeNombre(await _ajustes.leerModeloLocal()),
    );
    if (!await local.modeloDescargado()) {
      if (avisar) {
        _mostrar('falta bajar el modelo ${local.modelo.nombre} '
            '(${local.modelo.megas} MB) para transcribir en este equipo');
      }
      return null;
    }
    return local;
  }

  /// ¿Se puede transcribir ahora mismo, sin pedirle nada más al usuario?
  Future<bool> get listoParaTranscribir async =>
      (await _armarTranscriptor(avisar: false)) != null;

  /// Transcribe y sube lo que esté encolado, de a una por vez.
  ///
  /// Con [incluirEnEspera] también toma las que estaban guardadas esperando decisión.
  /// La interfaz y la consola lo usan cuando el usuario pide procesar explícitamente;
  /// el arranque de la app no, para no ponerse a transcribir sola lo que se dejó en
  /// espera a propósito.
  Future<void> procesarPendientes({bool incluirEnEspera = false}) async {
    final transcriptor = await _armarTranscriptor();
    if (transcriptor == null) return;

    final idioma = await _ajustes.leerIdiomaAudio();
    final subir = await _ajustes.leerSubidaAutomatica();
    final dispositivo = await _ajustes.leerNombreDispositivo(plataforma);

    if (incluirEnEspera) {
      for (final g in List<Grabacion>.from(_grabaciones)) {
        if (g.estado == EstadoGrabacion.enEspera) {
          await _actualizar(g.copyWith(estado: EstadoGrabacion.pendiente));
        }
      }
    }

    for (final actual in List<Grabacion>.from(_grabaciones)) {
      if (actual.estado != EstadoGrabacion.pendiente) continue;
      await _procesarUna(actual, transcriptor, idioma, subir, dispositivo);
    }

    if (transcriptor is TranscriptorLocal) await transcriptor.soltarModelo();
  }

  /// Manda a transcribir una grabación puntual que estaba en espera.
  Future<void> transcribirAhora(Grabacion g) async {
    if (g.estado == EstadoGrabacion.enEspera) {
      await _actualizar(g.copyWith(estado: EstadoGrabacion.pendiente));
    }
    await procesarPendientes();
  }

  /// Reintenta una que quedó en error.
  Future<void> reintentar(Grabacion g) async {
    await _actualizar(g.copyWith(estado: EstadoGrabacion.pendiente, limpiarError: true));
    await procesarPendientes();
  }

  Future<void> _procesarUna(
    Grabacion g,
    Transcriptor transcriptor,
    String idioma,
    bool subir,
    String dispositivo,
  ) async {
    var actual = g;
    try {
      if (actual.transcripcion == null || actual.transcripcion!.trim().isEmpty) {
        actual = actual.copyWith(estado: EstadoGrabacion.transcribiendo, progreso: 0);
        await _actualizar(actual);

        final resultado = await transcriptor.transcribir(
          File(actual.rutaArchivo),
          idioma: idioma,
          onProgreso: (p) {
            actual = actual.copyWith(progreso: p);
            _reemplazar(actual);
          },
        );
        actual = actual.copyWith(
          transcripcion: resultado.texto,
          segmentos: resultado.segmentos,
          progreso: 100,
          motor: transcriptor.nombre,
        );
        await _actualizar(actual);
      }

      if (!subir) {
        await _actualizar(actual.copyWith(estado: EstadoGrabacion.lista));
        return;
      }

      actual = actual.copyWith(estado: EstadoGrabacion.subiendo);
      await _actualizar(actual);

      final itemId = await _api.subirGrabacion(
        actual,
        plataforma: plataforma,
        dispositivo: dispositivo,
      );
      await _actualizar(actual.copyWith(
        estado: EstadoGrabacion.lista,
        itemIdRemoto: itemId,
        limpiarError: true,
      ));
    } on ErrorTranscripcion catch (e) {
      await _actualizar(actual.copyWith(
          estado: EstadoGrabacion.error, mensajeError: e.mensaje));
    } on ErrorGranolazo catch (e) {
      // La transcripción ya está hecha y guardada: solo falló la subida, se puede
      // reintentar sin volver a pagar la transcripción.
      await _actualizar(actual.copyWith(
          estado: EstadoGrabacion.error, mensajeError: e.mensaje));
    } catch (e) {
      await _actualizar(actual.copyWith(
          estado: EstadoGrabacion.error, mensajeError: 'falló inesperadamente: $e'));
    }
  }

  // ── manejo de la lista ───────────────────────────────────────────────────────

  Future<void> _agregar(Grabacion g) async {
    _grabaciones = [g, ..._grabaciones];
    await _repo.guardar(_grabaciones);
    notifyListeners();
  }

  void _reemplazar(Grabacion g) {
    _grabaciones = [
      for (final x in _grabaciones)
        if (x.id == g.id) g else x
    ];
    notifyListeners();
  }

  Future<void> _actualizar(Grabacion g) async {
    _reemplazar(g);
    await _repo.guardar(_grabaciones);
  }

  Future<void> eliminar(Grabacion g) async {
    await _repo.borrarAudio(g);
    _grabaciones = _grabaciones.where((x) => x.id != g.id).toList();
    await _repo.guardar(_grabaciones);
    notifyListeners();
  }

  Future<File?> exportar(Grabacion g) => _repo.exportarTexto(g);

  Future<bool> probarBackend() => _api.probarConexion();

  @override
  void dispose() {
    _subDuracion?.cancel();
    _subNivel?.cancel();
    _subNivelSistema?.cancel();
    enVivo.dispose();
    _grabador.dispose();
    _transcriptorForzado?.dispose();
    _api.dispose();
    super.dispose();
  }
}
