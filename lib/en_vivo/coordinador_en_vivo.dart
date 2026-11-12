import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../services/ajustes_service.dart';
import 'estado_en_vivo.dart';
import 'fuentes_pcm.dart';
import 'motor_en_vivo.dart';
import 'servicio_en_vivo.dart';
import 'servidor_en_vivo.dart';

/// Los ajustes del borrador en vivo, ya leídos.
class ConfigEnVivo {
  const ConfigEnVivo({
    required this.activo,
    required this.modelo,
    required this.trozoSeg,
    required this.hilos,
    required this.puerto,
    required this.idioma,
  });

  final bool activo;
  final ModeloEnVivo modelo;
  final int trozoSeg;
  final int hilos;
  final int puerto;
  final String idioma;

  /// Rangos que el código acepta; fuera de ellos se ajusta al más cercano. Un trozo de
  /// menos de 5 s no rinde (el modelo necesita contexto) y uno de más de 60 s deja de ser
  /// "en vivo".
  static const trozoMin = 5, trozoMax = 60, hilosMin = 1, hilosMax = 4;

  static int acotarTrozo(int v) => v.clamp(trozoMin, trozoMax);
  static int acotarHilos(int v) => v.clamp(hilosMin, hilosMax);

  static Future<ConfigEnVivo> leer(AjustesService a) async => ConfigEnVivo(
        activo: await a.leerEnVivo(),
        modelo: ModeloEnVivo.desdeNombreOBase(await a.leerEnVivoModelo()),
        trozoSeg: acotarTrozo(await a.leerEnVivoTrozoSeg()),
        hilos: acotarHilos(await a.leerEnVivoHilos()),
        puerto: await a.leerEnVivoPuerto(),
        idioma: await a.leerIdiomaAudio(),
      );
}

/// Une los pedazos del modo en vivo para que el controlador de grabaciones no sepa nada
/// de ellos: ajustes, fuente de audio, servicio de troceo, endpoint local y estado para la
/// interfaz.
///
/// Todo lo que pasa acá es opcional y se traga sus propios errores: si algo falla, la
/// grabación sigue como si el modo estuviera apagado.
class CoordinadorEnVivo extends ChangeNotifier {
  CoordinadorEnVivo({
    AjustesService? ajustes,
    Future<FuentePcm> Function(String? Function() rutaSistema)? crearFuente,
    MotorEnVivo Function(ConfigEnVivo)? crearMotor,
    this.carpetaEstado,
  })  : _ajustes = ajustes ?? AjustesService(),
        _crearFuente = crearFuente ?? _fuenteReal,
        _crearMotor = crearMotor ?? _motorReal;

  final AjustesService _ajustes;
  final Future<FuentePcm> Function(String? Function() rutaSistema) _crearFuente;
  final MotorEnVivo Function(ConfigEnVivo) _crearMotor;

  /// Para tests: dónde se escribe `en-vivo.json`. Sin esto, la carpeta de datos de la app.
  final Directory? carpetaEstado;

  /// Si está puesta, el audio sale de ese WAV en vez del micrófono (modo de prueba).
  static const variableWavDePrueba = 'GRANOLAZO_EN_VIVO_WAV';

  static MotorEnVivo _motorReal(ConfigEnVivo c) =>
      MotorEnVivoWhisper(modelo: c.modelo, hilos: c.hilos);

  static Future<FuentePcm> _fuenteReal(String? Function() rutaSistema) async {
    final wav = Platform.environment[variableWavDePrueba]?.trim();
    if (wav != null && wav.isNotEmpty) return FuenteWavPrueba(File(wav));
    return FuenteMicrofonoYSistema(rutaSistema: rutaSistema);
  }

  ServicioEnVivo? _servicio;
  ServidorEnVivo? _servidor;
  FuentePcm? _fuente;
  StreamSubscription<EstadoEnVivo>? _sub;
  EstadoEnVivo? _estado;
  String? _aviso;
  bool _encendido = false;
  bool _cerrado = false;

  /// El último estado conocido (también después de terminar, hasta la próxima grabación).
  EstadoEnVivo? get estado => _estado;

  /// ¿Hay un borrador corriendo (o terminando de sacar el último trozo)?
  bool get activo => _servicio != null;

  /// Por qué el modo está encendido pero no arrancó, o cualquier otro aviso para mostrar.
  String? get aviso => _aviso ?? _estado?.aviso;

  /// El interruptor, tal como quedó la última vez que se leyó o cambió.
  bool get encendido => _encendido;

  Future<void> cargar() async {
    _encendido = await _ajustes.leerEnVivo();
    notifyListeners();
  }

  Future<void> cambiarEncendido(bool valor) async {
    _encendido = valor;
    notifyListeners();
    await _ajustes.guardarEnVivo(valor);
  }

  /// Arranca el borrador para la grabación [idGrabacion], si el modo está encendido.
  /// Nunca lanza.
  Future<void> arrancar({
    required String idGrabacion,
    required String? Function() rutaSistema,
    bool forzar = false,
  }) async {
    if (_servicio != null) return;
    _aviso = null;
    try {
      final config = await ConfigEnVivo.leer(_ajustes);
      _encendido = config.activo;
      if (!config.activo && !forzar) {
        notifyListeners();
        return;
      }
      final motor = _crearMotor(config);
      if (motor is MotorEnVivoWhisper && !await motor.modeloDescargado()) {
        _aviso = 'Falta bajar el modelo ${config.modelo.nombre} para la transcripción en '
            'vivo (Ajustes). La grabación sigue normal.';
        notifyListeners();
        return;
      }

      final fuente = await _crearFuente(rutaSistema);
      await fuente.abrir();
      final servicio = ServicioEnVivo(
        motor: motor,
        archivo: ArchivoEnVivo(carpeta: carpetaEstado),
        modelo: config.modelo.nombre,
        trozoSeg: config.trozoSeg,
        idioma: config.idioma,
      );
      _fuente = fuente;
      _servicio = servicio;
      _sub = servicio.cambios.listen((e) {
        _estado = e;
        notifyListeners();
      });
      await servicio.iniciar(idGrabacion: idGrabacion, pcm: fuente.pcm);

      if (config.puerto > 0) {
        final servidor = ServidorEnVivo(estado: () => servicio.estado, puerto: config.puerto);
        final fallo = await servidor.iniciar();
        if (fallo == null) {
          _servidor = servidor;
        } else {
          _aviso = fallo;
        }
      }
      final avisoFuente = fuente.aviso;
      if (avisoFuente != null) _aviso = avisoFuente;
      notifyListeners();
    } catch (e) {
      _aviso = 'No pude iniciar la transcripción en vivo: $e. La grabación sigue normal.';
      await _soltar();
      notifyListeners();
    }
  }

  /// Detiene el borrador. Con [vaciar] saca el texto del último trozo (puede tardar un
  /// poco); sin él, corta de inmediato. Nunca lanza.
  Future<void> parar({bool vaciar = true}) async {
    final servicio = _servicio;
    if (servicio == null) return;
    try {
      await _fuente?.cerrar();
      await _servidor?.detener();
      _servidor = null;
      await (vaciar ? servicio.detener() : servicio.cancelar());
      _estado = servicio.estado;
    } catch (_) {
      // El borrador no puede romper el cierre de la grabación.
    } finally {
      await _soltar();
      notifyListeners();
    }
  }

  Future<void> _soltar() async {
    await _sub?.cancel();
    _sub = null;
    _servicio = null;
    _fuente = null;
    await _servidor?.detener();
    _servidor = null;
  }

  @override
  void notifyListeners() {
    // `parar` termina después de que el controlador ya se descartó (modo consola).
    if (!_cerrado) super.notifyListeners();
  }

  @override
  void dispose() {
    _cerrado = true;
    unawaited(parar(vaciar: false));
    super.dispose();
  }
}
