import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../controllers/grabaciones_controller.dart';
import '../en_vivo/comando_en_vivo.dart';
import '../en_vivo/coordinador_en_vivo.dart';
import '../en_vivo/estado_en_vivo.dart';
import '../en_vivo/fuentes_pcm.dart';
import '../en_vivo/motor_en_vivo.dart';
import '../models/archivo_respaldo.dart';
import '../models/grabacion.dart';
import '../services/ajustes_service.dart';
import '../services/arranque_service.dart';
import '../services/detector_reuniones.dart';
import '../models/item_granolazo.dart';
import '../services/grabador_service.dart';
import '../services/granolazo_api.dart';
import '../services/respaldo_service.dart';
import '../services/sesion_service.dart';
import '../services/transcriptor_local.dart';
import 'salida_consola.dart';

/// Modo consola de Granolazo.
///
/// Es el mismo ejecutable que la interfaz gráfica, corriendo sin ventana. No duplica
/// lógica: usa el mismo [GrabacionesController] y los mismos servicios, así que lo que
/// se hace desde la terminal y lo que se hace con el mouse terminan en el mismo lugar.
///
/// Existe porque una app que solo se maneja a mano no se puede automatizar: esto permite
/// encolar audios desde un script, transcribir por cron y consultar el estado por SSH.
///
/// Con `--json` cada comando responde una sola línea de JSON, para consumirlo desde otro
/// programa sin parsear texto para humanos.
class GranolazoCli {
  GranolazoCli({
    GrabacionesController? controlador,
    AjustesService? ajustes,
    SalidaConsola? salida,
    SesionService? sesion,
    GranolazoApi? api,
    RespaldoService? respaldo,
  })  : _respaldoInyectado = respaldo,
        _sesion = sesion ?? SesionService(),
        _ajustes = ajustes ?? AjustesService(),
        _salida = salida ?? SalidaConsola.delSistema() {
    _api = api ?? GranolazoApi(sesion: _sesion);
    _controlador = controlador ?? GrabacionesController(api: _api);
  }

  late final GrabacionesController _controlador;
  late final GranolazoApi _api;
  final SesionService _sesion;
  final AjustesService _ajustes;
  final SalidaConsola _salida;
  final RespaldoService? _respaldoInyectado;

  bool _json = false;

  /// Comandos reconocidos. También los usa [esInvocacionDeConsola].
  static const comandos = <String>{
    'ayuda',
    'estado',
    'listar',
    'importar',
    'grabar',
    'procesar',
    'reintentar',
    'eliminar',
    'clave',
    'modelo',
    'config',
    'probar',
    'entrar',
    'salir',
    'quien',
    'reuniones',
    'ver',
    'cola',
    'filtros',
    'reuniones-en-curso',
    'arranque',
    'respaldo',
    'en-vivo',
    'en-vivo-prueba',
  };

  /// ¿Estos argumentos piden la consola en vez de la ventana?
  ///
  /// El motor de Flutter inyecta sus propias banderas (siempre con guiones) al correr en
  /// modo depuración, así que un argumento suelto sin guiones es señal inequívoca de que
  /// lo escribió una persona o un script. La misma regla vive en `windows/runner/main.cpp`,
  /// que es quien decide si abre la ventana.
  static bool esInvocacionDeConsola(List<String> args) {
    for (final a in args) {
      if (a.isEmpty) continue;
      if (!a.startsWith('-')) return true;
      if (a == '--ayuda' || a == '--help' || a == '-h') return true;
    }
    return false;
  }

  /// Parte una linea de comando en argumentos, respetando las comillas.
  ///
  /// Hace falta en Android: `adb` entrega el comando como un solo texto, no como una lista.
  /// Sin respetar las comillas, `entrar --correo "a b"` se rompe en pedazos y el comando
  /// recibe basura. Vive aca y no en el arranque porque es parte de entender un comando,
  /// que es el trabajo de esta clase.
  static List<String> partirLinea(String linea) {
    final partes = <String>[];
    final actual = StringBuffer();
    var abierto = false;
    String? comilla;

    for (final c in linea.trim().split('')) {
      if (comilla != null) {
        if (c == comilla) {
          comilla = null;
        } else {
          actual.write(c);
        }
        continue;
      }
      if (c == '"' || c == "'") {
        // Se marca aparte: `--alias ""` es un argumento vacio a proposito, no la
        // ausencia de un argumento, y sin esto se perderia.
        comilla = c;
        abierto = true;
        continue;
      }
      if (c == ' ' || c == '	') {
        if (actual.isNotEmpty || abierto) {
          partes.add(actual.toString());
          actual.clear();
          abierto = false;
        }
        continue;
      }
      actual.write(c);
    }
    if (actual.isNotEmpty || abierto) partes.add(actual.toString());
    return partes;
  }

  // ── entrada ──────────────────────────────────────────────────────────────────

  /// Ejecuta un comando y devuelve el código de salida del proceso.
  ///
  /// 0 correcto · 1 falló la operación · 2 no se entendió lo que se pidió.
  Future<int> ejecutar(List<String> args) async {
    _json = args.contains('--json');
    final libres = args.where((a) => !a.startsWith('-')).toList();
    final comando = libres.isEmpty ? 'ayuda' : libres.first;
    final resto = libres.skip(1).toList();

    if (args.contains('--ayuda') || args.contains('--help') || args.contains('-h')) {
      _ayuda();
      return 0;
    }
    if (!comandos.contains(comando)) {
      _fallar('no conozco el comando "$comando". Probar: granolazo_app ayuda');
      return 2;
    }

    try {
      return switch (comando) {
        'ayuda' => _conAyuda(),
        'estado' => await _estado(),
        'listar' => await _listar(args),
        'importar' => await _importar(resto, args),
        'grabar' => await _grabar(args),
        'procesar' => await _procesar(),
        'reintentar' => await _reintentar(resto),
        'eliminar' => await _eliminar(resto, args),
        'clave' => await _clave(args),
        'modelo' => await _modelo(args),
        'config' => await _config(args),
        'probar' => await _probar(),
        'entrar' => await _entrar(args),
        'salir' => await _salir(),
        'quien' => await _quien(),
        'reuniones' => await _reuniones(args),
        'ver' => await _ver(resto, args),
        'cola' => await _cola(),
        'filtros' => await _filtros(),
        'reuniones-en-curso' => await _reunionesEnCurso(),
        'arranque' => await _arranque(args),
        'respaldo' => await _respaldo(resto, args),
        'en-vivo' => await _enVivo(args),
        'en-vivo-prueba' => await _enVivoPrueba(resto, args),
        _ => 2,
      };
    } catch (e) {
      _fallar('$e');
      return 1;
    } finally {
      _controlador.dispose();
    }
  }

  int _conAyuda() {
    _ayuda();
    return 0;
  }

  // ── comandos ─────────────────────────────────────────────────────────────────

  Future<int> _estado() async {
    await _controlador.iniciarSinProcesar();
    final hayClave = await _ajustes.hayClaveTranscripcion;
    final conecta = await _controlador.probarBackend();
    final lista = _controlador.grabaciones;
    final motor = await _ajustes.leerMotorTranscripcion();
    final modelo = ModeloLocal.desdeNombre(await _ajustes.leerModeloLocal());
    final listo = await _controlador.listoParaTranscribir;
    final automatica = await _ajustes.leerTranscripcionAutomatica();

    final porEstado = <String, int>{};
    for (final g in lista) {
      porEstado[g.estado.name] = (porEstado[g.estado.name] ?? 0) + 1;
    }

    // El codigo de salida es el mismo en los dos formatos: un script que haga
    // `if granolazo_app estado --json` tiene que enterarse igual de que falta algo.
    // Lo que importa no es que haya clave -el motor local no la necesita- sino que se
    // pueda transcribir de hecho.
    final codigo = (listo && conecta) ? 0 : 1;

    if (_json) {
      return _emitirJson({
        'plataforma': _controlador.plataforma,
        'dispositivo': await _ajustes.leerNombreDispositivo(_controlador.plataforma),
        'clave_de_transcripcion': hayClave,
        'motor_transcripcion': motor,
        'modelo_local': modelo.nombre,
        'listo_para_transcribir': listo,
        'transcripcion_automatica': automatica,
        'backend_responde': conecta,
        'subida_automatica': await _ajustes.leerSubidaAutomatica(),
        'idioma_audio': await _ajustes.leerIdiomaAudio(),
        'total': lista.length,
        'pendientes': _controlador.pendientes,
        'en_espera': _controlador.enEspera,
        'por_estado': porEstado,
      }, codigo: codigo);
    }

    _linea('plataforma           ${_controlador.plataforma}');
    _linea('dispositivo          '
        '${await _ajustes.leerNombreDispositivo(_controlador.plataforma)}');
    _linea('motor                ${motor == "local" ? "este equipo (modelo ${modelo.nombre})" : "servicio en linea"}');
    _linea('listo para transcribir  ${listo ? "si" : "NO"}');
    _linea('clave del servicio   ${hayClave ? "cargada" : "no hay"}');
    _linea('transcribir al grabar   ${automatica ? "si" : "no"}');
    _linea('backend              ${conecta ? "responde" : "NO RESPONDE"}');
    _linea('subida automatica    ${await _ajustes.leerSubidaAutomatica() ? "si" : "no"}');
    _linea('idioma del audio     ${await _ajustes.leerIdiomaAudio()}');
    _linea('grabaciones          ${lista.length} '
        '(${_controlador.pendientes} por procesar, ${_controlador.enEspera} en espera)');
    for (final e in porEstado.entries) {
      _linea('  ${e.key.padRight(16)} ${e.value}');
    }
    return codigo;
  }

  Future<int> _listar(List<String> args) async {
    await _controlador.iniciarSinProcesar();
    final limite = _entero(args, '--limite') ?? 30;
    final lista = _controlador.grabaciones.take(limite).toList();

    if (_json) {
      return _emitirJson({
        'total': _controlador.grabaciones.length,
        'grabaciones': [for (final g in lista) _comoMapa(g)],
      });
    }

    if (lista.isEmpty) {
      _linea('no hay grabaciones');
      return 0;
    }
    for (final g in lista) {
      final marca = g.grabadaEn.toLocal().toIso8601String().substring(0, 16);
      _linea('${g.id.padRight(16)} ${g.estado.name.padRight(15)} '
          '${g.duracionLegible.padLeft(8)}  $marca  ${g.tituloVisible}');
      final error = g.mensajeError;
      if (error != null) _linea('${" " * 17}error: $error');
    }
    return 0;
  }

  Future<int> _importar(List<String> rutas, List<String> args) async {
    if (rutas.isEmpty) {
      _fallar('hay que indicar al menos un archivo de audio');
      return 2;
    }
    await _controlador.iniciarSinProcesar();

    final faltantes = <String>[];
    for (final r in rutas) {
      if (!await File(r).exists()) faltantes.add(r);
    }
    if (faltantes.isNotEmpty) {
      _fallar('no existen estos archivos: ${faltantes.join(", ")}');
      return 1;
    }

    final agregadas = await _controlador.importarRutas(rutas);
    if (!_json) _linea('encolados $agregadas audios');

    if (args.contains('--procesar')) return _procesar();
    return _json ? _emitirJson({'encolados': agregadas}) : 0;
  }

  Future<int> _grabar(List<String> args) async {
    await _controlador.iniciarSinProcesar();
    final segundos = _entero(args, '--segundos');

    await _controlador.comenzarGrabacion();
    if (!_controlador.grabando) {
      _fallar(_controlador.aviso ?? 'no pude empezar a grabar');
      return 1;
    }

    if (segundos != null) {
      if (!_json) _linea('grabando $segundos segundos...');
      await Future<void>.delayed(Duration(seconds: segundos));
    } else {
      if (!_json) _linea('grabando. Enter para cortar.');
      await _esperarEnter();
    }

    await _controlador.detenerGrabacion();
    final nueva = _controlador.grabaciones.isEmpty ? null : _controlador.grabaciones.first;
    if (nueva == null) {
      _fallar(_controlador.aviso ?? 'la grabacion quedo vacia');
      return 1;
    }
    if (!_json) {
      _linea('grabado ${nueva.duracionLegible} en ${nueva.rutaArchivo}');
    }

    if (args.contains('--no-procesar')) {
      return _json ? _emitirJson({'grabacion': _comoMapa(nueva)}) : 0;
    }
    return _procesar();
  }

  Future<int> _procesar() async {
    await _controlador.iniciarSinProcesar();
    if (!await _controlador.listoParaTranscribir) {
      final motor = await _ajustes.leerMotorTranscripcion();
      _fallar(motor == 'api'
          ? 'falta la clave del servicio: granolazo_app clave --desde-env VARIABLE'
          : 'falta bajar el modelo: granolazo_app modelo --bajar');
      return 1;
    }

    final antes = _controlador.pendientes;
    if (antes == 0) {
      if (!_json) _linea('no hay nada pendiente');
      return _json ? _emitirJson({'procesadas': 0, 'con_error': 0}) : 0;
    }
    if (!_json) _linea('procesando $antes grabaciones...');

    // Incluye las que estaban en espera: si alguien pide procesar, quiere procesarlas.
    await _controlador.procesarPendientes(incluirEnEspera: true);

    final conError =
        _controlador.grabaciones.where((g) => g.estado == EstadoGrabacion.error).toList();
    final listas =
        _controlador.grabaciones.where((g) => g.estado == EstadoGrabacion.lista).length;

    if (_json) {
      return _emitirJson({
        'listas': listas,
        'con_error': conError.length,
        'errores': [
          for (final g in conError) {'id': g.id, 'error': g.mensajeError}
        ],
      }, codigo: conError.isEmpty ? 0 : 1);
    }

    _linea('listas: $listas   con error: ${conError.length}');
    for (final g in conError) {
      _linea('  ${g.id}: ${g.mensajeError}');
    }
    return conError.isEmpty ? 0 : 1;
  }

  Future<int> _reintentar(List<String> ids) async {
    await _controlador.iniciarSinProcesar();
    final objetivo = ids.isEmpty
        ? _controlador.grabaciones.where((g) => g.estado == EstadoGrabacion.error).toList()
        : _controlador.grabaciones.where((g) => ids.contains(g.id)).toList();

    if (objetivo.isEmpty) {
      _fallar(ids.isEmpty ? 'no hay grabaciones con error' : 'no encontre esos ids');
      return 1;
    }
    for (final g in objetivo) {
      await _controlador.reintentar(g);
    }
    return _procesar();
  }

  Future<int> _eliminar(List<String> ids, List<String> args) async {
    await _controlador.iniciarSinProcesar();
    final todasLasListas = args.contains('--subidas');

    final objetivo = todasLasListas
        ? _controlador.grabaciones.where((g) => g.estado == EstadoGrabacion.lista).toList()
        : _controlador.grabaciones.where((g) => ids.contains(g.id)).toList();

    if (objetivo.isEmpty) {
      _fallar(todasLasListas ? 'no hay grabaciones ya subidas' : 'no encontre esos ids');
      return 1;
    }
    for (final g in objetivo) {
      await _controlador.eliminar(g);
    }
    return _json
        ? _emitirJson({'eliminadas': [for (final g in objetivo) g.id]})
        : _ok('eliminadas ${objetivo.length} grabaciones');
  }

  Future<int> _clave(List<String> args) async {
    final nueva = _texto(args, '--poner');
    final desdeEnv = _texto(args, '--desde-env');

    if (args.contains('--borrar')) {
      await _ajustes.guardarClaveTranscripcion(null);
      return _json
          ? _emitirJson({'clave_de_transcripcion': false})
          : _ok('clave borrada del almacen seguro');
    }

    if (desdeEnv != null) {
      final valor = Platform.environment[desdeEnv];
      if (valor == null || valor.trim().isEmpty) {
        _fallar('la variable de entorno $desdeEnv esta vacia o no existe');
        return 1;
      }
      await _ajustes.guardarClaveTranscripcion(valor);
      return _json
          ? _emitirJson({'clave_de_transcripcion': true, 'origen': desdeEnv})
          : _ok('clave guardada en el almacen seguro, tomada de $desdeEnv');
    }

    if (nueva != null) {
      await _ajustes.guardarClaveTranscripcion(nueva);
      return _json
          ? _emitirJson({'clave_de_transcripcion': true, 'origen': 'argumento'})
          : _ok('clave guardada en el almacen seguro');
    }

    final hay = await _ajustes.hayClaveTranscripcion;
    return _json
        ? _emitirJson({'clave_de_transcripcion': hay})
        : _ok(hay ? 'hay una clave guardada' : 'no hay clave guardada');
  }

  /// Gestiona el modelo de Whisper que corre en este equipo.
  Future<int> _modelo(List<String> args) async {
    final elegido = _texto(args, '--usar');
    if (elegido != null) {
      if (!ModeloLocal.values.any((m) => m.nombre == elegido)) {
        _fallar('modelos validos: ${ModeloLocal.values.map((m) => m.nombre).join(", ")}');
        return 2;
      }
      await _ajustes.guardarModeloLocal(elegido);
    }

    final modelo = ModeloLocal.desdeNombre(await _ajustes.leerModeloLocal());
    final local = TranscriptorLocal(modelo: modelo);
    var descargado = await local.modeloDescargado();

    if (args.contains('--bajar') && !descargado) {
      if (!_json) {
        _linea('bajando el modelo ${modelo.nombre} (${modelo.megas} MB). '
            'La primera vez tarda.');
      }
      try {
        await local.descargarModelo();
        descargado = true;
      } catch (e) {
        _fallar('no pude bajar el modelo: $e');
        return 1;
      }
    }

    final datos = {
      'modelo': modelo.nombre,
      'descripcion': modelo.descripcion,
      'megas': modelo.megas,
      'descargado': descargado,
      'ruta': await local.rutaDelModelo(),
      'ffmpeg': await TranscriptorLocal.ffmpegDisponible(),
      'disponibles': [
        for (final m in ModeloLocal.values)
          {'nombre': m.nombre, 'megas': m.megas, 'descripcion': m.descripcion}
      ],
    };
    if (_json) return _emitirJson(datos, codigo: descargado ? 0 : 1);

    _linea('modelo elegido   ${modelo.nombre} (${modelo.megas} MB) — ${modelo.descripcion}');
    _linea('descargado       ${descargado ? "si" : "NO (granolazo_app modelo --bajar)"}');
    _linea('archivo          ${datos['ruta']}');
    _linea('ffmpeg           ${datos['ffmpeg'] == true ? "disponible" : "FALTA (solo se podra con audio WAV)"}');
    _linea('');
    _linea('disponibles:');
    for (final m in ModeloLocal.values) {
      final marca = m == modelo ? '*' : ' ';
      _linea('  $marca ${m.nombre.padRight(8)} ${m.megas.toString().padLeft(5)} MB  ${m.descripcion}');
    }
    return descargado ? 0 : 1;
  }

  Future<int> _config(List<String> args) async {
    final dispositivo = _texto(args, '--dispositivo');
    final idioma = _texto(args, '--idioma');
    final subida = _texto(args, '--subida');
    final motor = _texto(args, '--motor');
    final automatica = _texto(args, '--auto');
    final ganMic = _texto(args, '--volumen-microfono');
    final ganSis = _texto(args, '--volumen-equipo');
    final enVivo = _texto(args, '--en-vivo');
    final enVivoModelo = _texto(args, '--en-vivo-modelo');
    final enVivoTrozo = _texto(args, '--en-vivo-trozo');
    final enVivoHilos = _texto(args, '--en-vivo-hilos');
    final enVivoPuerto = _texto(args, '--en-vivo-puerto');

    if (dispositivo != null) await _ajustes.guardarNombreDispositivo(dispositivo);
    if (idioma != null) await _ajustes.guardarIdiomaAudio(idioma);
    if (motor != null) {
      if (motor != 'local' && motor != 'api') {
        _fallar('--motor acepta "local" (este equipo) o "api" (servicio en linea)');
        return 2;
      }
      await _ajustes.guardarMotorTranscripcion(motor);
    }
    if (automatica != null) {
      if (automatica != 'si' && automatica != 'no') {
        _fallar('--auto acepta "si" o "no"');
        return 2;
      }
      await _ajustes.guardarTranscripcionAutomatica(automatica == 'si');
    }
    for (final (bandera, valor, guardar) in [
      ('--volumen-microfono', ganMic, _ajustes.guardarGananciaMicrofono),
      ('--volumen-equipo', ganSis, _ajustes.guardarGananciaSistema),
    ]) {
      if (valor == null) continue;
      final n = double.tryParse(valor);
      if (n == null || n < 0 || n > 3) {
        _fallar('$bandera acepta un numero entre 0 y 3 (1 = dejar como esta)');
        return 2;
      }
      await guardar(n);
    }
    if (enVivo != null) {
      if (enVivo != 'si' && enVivo != 'no') {
        _fallar('--en-vivo acepta "si" o "no"');
        return 2;
      }
      await _ajustes.guardarEnVivo(enVivo == 'si');
    }
    if (enVivoModelo != null) {
      if (ModeloEnVivo.desdeNombre(enVivoModelo) == null) {
        _fallar('--en-vivo-modelo acepta tiny, base o small');
        return 2;
      }
      await _ajustes.guardarEnVivoModelo(enVivoModelo);
    }
    final rangos = [
      ('--en-vivo-trozo', enVivoTrozo, ConfigEnVivo.trozoMin, ConfigEnVivo.trozoMax,
          _ajustes.guardarEnVivoTrozoSeg),
      ('--en-vivo-hilos', enVivoHilos, ConfigEnVivo.hilosMin, ConfigEnVivo.hilosMax,
          _ajustes.guardarEnVivoHilos),
      ('--en-vivo-puerto', enVivoPuerto, 0, 65535, _ajustes.guardarEnVivoPuerto),
    ];
    for (final (bandera, valor, min, max, guardar) in rangos) {
      if (valor == null) continue;
      final n = int.tryParse(valor);
      if (n == null || n < min || n > max) {
        _fallar('$bandera acepta un entero entre $min y $max');
        return 2;
      }
      await guardar(n);
    }
    if (subida != null) {
      if (subida != 'si' && subida != 'no') {
        _fallar('--subida acepta "si" o "no"');
        return 2;
      }
      await _ajustes.guardarSubidaAutomatica(subida == 'si');
    }

    final actual = {
      'dispositivo': await _ajustes.leerNombreDispositivo(_controlador.plataforma),
      'idioma_audio': await _ajustes.leerIdiomaAudio(),
      'motor_transcripcion': await _ajustes.leerMotorTranscripcion(),
      'modelo_local': await _ajustes.leerModeloLocal(),
      'transcripcion_automatica': await _ajustes.leerTranscripcionAutomatica(),
      'volumen_microfono': await _ajustes.leerGananciaMicrofono(),
      'volumen_equipo': await _ajustes.leerGananciaSistema(),
      'subida_automatica': await _ajustes.leerSubidaAutomatica(),
      'transcripcion_en_vivo': await _ajustes.leerEnVivo(),
      'en_vivo_modelo': await _ajustes.leerEnVivoModelo(),
      'en_vivo_trozo_seg': await _ajustes.leerEnVivoTrozoSeg(),
      'en_vivo_hilos': await _ajustes.leerEnVivoHilos(),
      'en_vivo_puerto': await _ajustes.leerEnVivoPuerto(),
      'carpeta_grabaciones': (await GrabadorService.carpetaGrabaciones()).path,
    };
    if (_json) return _emitirJson(actual);
    for (final e in actual.entries) {
      _linea('${e.key.padRight(22)} ${e.value}');
    }
    return 0;
  }

  /// Lee el borrador de la grabación en curso (ver [ComandoEnVivo]).
  Future<int> _enVivo(List<String> args) => ComandoEnVivo(
        archivo: ArchivoEnVivo(),
        escribir: _linea,
        json: _json,
      ).ejecutar(seguir: args.contains('--seguir'), ultima: args.contains('--ultima'));

  /// Ensaya el borrador en vivo con un WAV (16 kHz, mono, 16 bits) en lugar del micrófono,
  /// a velocidad real. Es el modo de prueba: no graba nada ni toca la cola.
  Future<int> _enVivoPrueba(List<String> rutas, List<String> args) async {
    if (rutas.isEmpty) {
      _fallar('hay que indicar un WAV de prueba (16 kHz, mono, 16 bits)');
      return 2;
    }
    final wav = File(rutas.first);
    if (!await wav.exists()) {
      _fallar('no existe ${rutas.first}');
      return 1;
    }
    final velocidad = double.tryParse(_texto(args, '--velocidad') ?? '1') ?? 1.0;
    final segundosAudio = (await wav.length()) / 32000;
    final coordinador = CoordinadorEnVivo(
      ajustes: _ajustes,
      crearFuente: (_) async => FuenteWavPrueba(wav, velocidad: velocidad),
    );
    final id = 'prueba-${DateTime.now().toUtc().millisecondsSinceEpoch}';
    var visto = 0;
    coordinador.addListener(() {
      final e = coordinador.estado;
      if (e == null) return;
      for (var i = visto; i < e.segmentos.length; i++) {
        final s = e.segmentos[i];
        if (!_json) _linea('[${s.desdeSeg.toStringAsFixed(1)}s] ${s.texto}');
      }
      visto = e.segmentos.length;
    });
    await coordinador.arrancar(idGrabacion: id, rutaSistema: () => null, forzar: true);
    if (!coordinador.activo) {
      _fallar(coordinador.aviso ?? 'no pude arrancar el borrador');
      return 1;
    }
    if (!_json) _linea('ensayando $id: ${segundosAudio.toStringAsFixed(0)} s de audio a ${velocidad}x');
    await Future<void>.delayed(Duration(milliseconds: (segundosAudio / velocidad * 1000).round() + 1500));
    await coordinador.parar();
    final e = coordinador.estado;
    final resumen = {
      'id_grabacion': id,
      'segmentos': e?.segmentos.length ?? 0,
      'rezago_seg': e?.rezagoSeg ?? 0,
      'descartado_seg': e?.descartadoSeg ?? 0,
      'aviso': e?.aviso,
      'texto': e?.texto ?? '',
    };
    if (_json) return _emitirJson(resumen);
    _linea('listo: ${resumen['segmentos']} segmentos, rezago final ${resumen['rezago_seg']} s');
    return 0;
  }

  Future<int> _probar() async {
    final ok = await _controlador.probarBackend();
    if (_json) {
      return _emitirJson({'backend_responde': ok}, codigo: ok ? 0 : 1);
    }
    _linea(ok ? 'conecta bien con Granolazo' : 'no pude conectar con Granolazo');
    return ok ? 0 : 1;
  }


  // -- sesion -------------------------------------------------------------------

  Future<int> _entrar(List<String> args) async {
    final email = _texto(args, '--email');
    if (email == null) {
      _fallar('falta --email');
      return 2;
    }
    final desdeEnv = _texto(args, '--desde-env');
    final directa = _texto(args, '--clave');
    final clave = desdeEnv != null ? Platform.environment[desdeEnv] : directa;
    if (clave == null || clave.isEmpty) {
      _fallar(desdeEnv != null
          ? 'la variable de entorno $desdeEnv esta vacia o no existe'
          : 'falta la contrasena: --desde-env VARIABLE (preferido) o --clave VALOR');
      return 2;
    }

    try {
      final u = await _sesion.entrar(email: email, clave: clave);
      return _json
          ? _emitirJson({'sesion': true, 'email': u.email, 'usuario_id': u.id})
          : _ok('sesion iniciada como ${u.email}');
    } on ErrorSesion catch (e) {
      _fallar(e.mensaje);
      return 1;
    }
  }

  Future<int> _salir() async {
    await _sesion.salir();
    return _json ? _emitirJson({'sesion': false}) : _ok('sesion cerrada');
  }

  Future<int> _quien() async {
    await _sesion.cargar();
    final u = _sesion.usuario;
    if (_json) {
      return _emitirJson(
        {'sesion': u != null, 'email': u?.email, 'usuario_id': u?.id},
        codigo: u == null ? 1 : 0,
      );
    }
    if (u == null) {
      _linea('sin sesion iniciada (se usa la clave publica)');
      return 1;
    }
    return _ok('sesion de ${u.email}');
  }

  // -- reuniones del backend ----------------------------------------------------

  FiltroItems _filtroDesde(List<String> args) => FiltroItems(
        texto: _texto(args, '--texto'),
        grupo: _texto(args, '--grupo'),
        tag: _texto(args, '--tag'),
        fuente: _texto(args, '--fuente'),
        estado: _texto(args, '--estado'),
        participante: _texto(args, '--persona'),
        desde: _fecha(args, '--desde'),
        hasta: _fecha(args, '--hasta'),
        limite: _entero(args, '--limite') ?? 30,
      );

  Future<int> _reuniones(List<String> args) async {
    final filtro = _filtroDesde(args);
    final List<ItemGranolazo> items;
    try {
      items = await _api.buscarItems(filtro);
    } on ErrorGranolazo catch (e) {
      _fallar(e.mensaje);
      return 1;
    }

    if (_json) {
      return _emitirJson({
        'total': items.length,
        'reuniones': [for (final i in items) i.aMapa()],
      });
    }
    if (items.isEmpty) {
      _linea(filtro.hayAlguno
          ? 'ninguna reunion coincide con ese filtro'
          : 'no hay reuniones en Granolazo');
      return 0;
    }
    for (final i in items) {
      final marca = i.fecha?.toIso8601String().substring(0, 16) ?? '               -';
      final estado = i.transcrita ? 'ok ' : (i.conError ? 'ERR' : '...');
      _linea('$estado $marca ${i.duracionLegible.padLeft(8)}  '
          '${(i.fuente ?? "-").padRight(12)} ${i.tituloVisible}');
      _linea('    ${i.id}');
    }
    _linea('');
    _linea('${items.length} reuniones');
    return 0;
  }

  Future<int> _ver(List<String> ids, List<String> args) async {
    if (ids.isEmpty) {
      _fallar('hay que indicar el id de la reunion (se ve con: granolazo_app reuniones)');
      return 2;
    }
    final id = ids.first;
    final soloResumen = args.contains('--resumen');
    final TextoDeReunion? t;
    try {
      t = await _api.textoDe(id);
    } on ErrorGranolazo catch (e) {
      _fallar(e.mensaje);
      return 1;
    }
    if (t == null) {
      _fallar('no encontre ninguna reunion con ese id');
      return 1;
    }
    if (!t.hayAlgo) {
      _fallar('esa reunion todavia no tiene ni transcripcion ni resumen');
      return 1;
    }

    if (_json) {
      return _emitirJson({
        'id': id,
        'titulo': t.titulo,
        'transcripcion': t.transcripcion,
        'resumen': t.resumen,
      });
    }

    if (soloResumen || !t.hayTranscripcion) {
      if (!t.hayResumen) {
        _fallar('esa reunion no tiene resumen');
        return 1;
      }
      // Decirlo importa: un resumen no es la transcripcion, y confundirlos lleva a
      // citar como dicho algo que nadie dijo.
      if (!soloResumen) {
        _linea('[sin transcripcion literal; esto es el RESUMEN]');
        _linea('');
      }
      _linea(t.resumen!);
      return 0;
    }
    _linea(t.transcripcion!);
    return 0;
  }

  // -- cola del pipeline ---------------------------------------------------------

  Future<int> _cola() async {
    final EstadoCola cola;
    try {
      cola = await _api.estadoDeLaCola();
    } on ErrorGranolazo catch (e) {
      _fallar(e.mensaje);
      return 1;
    }

    if (_json) {
      return _emitirJson({
        'procesando': [for (final i in cola.procesando) i.aMapa()],
        'esperando': [for (final i in cola.esperando) i.aMapa()],
        'con_error': [for (final i in cola.conError) i.aMapa()],
        'total': cola.total,
        'espera_estimada_minutos': cola.esperaEstimada.inMinutes,
      });
    }

    if (cola.total == 0) {
      _linea('la cola esta vacia: no hay nada pendiente ni fallado');
      return 0;
    }
    if (cola.procesando.isNotEmpty) {
      _linea('transcribiendo ahora (${cola.procesando.length}):');
      for (final i in cola.procesando) {
        _linea('  ${i.progreso.toString().padLeft(3)}%  '
            '${i.duracionLegible.padLeft(8)}  ${i.tituloVisible}');
      }
    }
    if (cola.esperando.isNotEmpty) {
      _linea('esperando turno (${cola.esperando.length}), '
          'aprox ${cola.esperaEstimada.inMinutes} minutos:');
      for (final i in cola.esperando.take(15)) {
        _linea('  ${i.duracionLegible.padLeft(8)}  '
            '${(i.fuente ?? "-").padRight(12)} ${i.tituloVisible}');
      }
      if (cola.esperando.length > 15) {
        _linea('  ... y ${cola.esperando.length - 15} mas');
      }
    }
    if (cola.conError.isNotEmpty) {
      _linea('con error (${cola.conError.length}):');
      for (final i in cola.conError) {
        _linea('  ${i.tituloVisible}: ${i.mensajeError ?? "sin detalle"}');
      }
    }
    return cola.conError.isEmpty ? 0 : 1;
  }

  Future<int> _filtros() async {
    final OpcionesDeFiltro o;
    try {
      o = await _api.opcionesDeFiltro();
    } on ErrorGranolazo catch (e) {
      _fallar(e.mensaje);
      return 1;
    }
    if (_json) {
      return _emitirJson({'grupos': o.grupos, 'tags': o.tags, 'fuentes': o.fuentes});
    }
    _linea('grupos:  ${o.grupos.join(", ")}');
    _linea('tags:    ${o.tags.join(", ")}');
    _linea('fuentes: ${o.fuentes.join(", ")}');
    return 0;
  }

  /// Que aplicaciones estan usando el microfono ahora mismo.
  Future<int> _reunionesEnCurso() async {
    final d = DetectorReuniones();
    if (!d.soportado) {
      _fallar('la deteccion todavia solo anda en Windows');
      return 1;
    }
    final apps = await d.revisar();
    if (_json) {
      return _emitirJson({
        'hay_reunion': apps.isNotEmpty,
        'aplicaciones': [
          for (final a in apps)
            {'nombre': a.nombre, 'ejecutable': a.ejecutable, 'desde': a.desde.toIso8601String()}
        ],
      }, codigo: apps.isEmpty ? 1 : 0);
    }
    if (apps.isEmpty) {
      _linea('ninguna aplicacion esta usando el microfono');
      return 1;
    }
    for (final a in apps) {
      _linea('${a.nombre}  (desde ${a.desde.toLocal().toIso8601String().substring(11, 19)})');
      _linea('  ${a.ejecutable}');
    }
    return 0;
  }

  /// Arrancar con el sistema.
  Future<int> _arranque(List<String> args) async {
    final s = ArranqueService();
    if (args.contains('--activar')) {
      final error = await s.activar();
      if (error != null) {
        _fallar(error);
        return 1;
      }
    } else if (args.contains('--desactivar')) {
      final error = await s.desactivar();
      if (error != null) {
        _fallar(error);
        return 1;
      }
    }
    final activo = await s.activo;
    if (_json) {
      return _emitirJson(
        {'arranca_con_el_sistema': activo, 'comando': await s.rutaRegistrada()},
        codigo: 0,
      );
    }
    _linea('arranca con el sistema: ${activo ? "si" : "no"}');
    final ruta = await s.rutaRegistrada();
    if (ruta != null) _linea('comando: $ruta');
    return 0;
  }

  DateTime? _fecha(List<String> args, String bandera) {
    final v = _texto(args, bandera);
    return v == null ? null : DateTime.tryParse(v);
  }

  // ── auxiliares ───────────────────────────────────────────────────────────────

  Map<String, dynamic> _comoMapa(Grabacion g) => {
        'id': g.id,
        'titulo': g.tituloVisible,
        'estado': g.estado.name,
        'grabada_en': g.grabadaEn.toUtc().toIso8601String(),
        'duracion_segundos': g.duracionSegundos,
        'tamano_bytes': g.tamanoBytes,
        'importada': g.importada,
        'con_marcas_de_tiempo': g.hayTiempos,
        'segmentos': [for (final s in g.segmentos) s.toJson()],
        'item_granolazo': g.itemIdRemoto,
        'error': g.mensajeError,
        'ruta': g.rutaArchivo,
      };

  Future<void> _esperarEnter() async {
    try {
      await stdin.first;
    } catch (_) {
      // Sin entrada estandar disponible no hay forma de esperar a nadie: se corta ya.
    }
  }

  String? _texto(List<String> args, String bandera) {
    final i = args.indexOf(bandera);
    if (i < 0 || i + 1 >= args.length) return null;
    return args[i + 1];
  }

  int? _entero(List<String> args, String bandera) {
    final v = _texto(args, bandera);
    return v == null ? null : int.tryParse(v);
  }

  int _emitirJson(Map<String, dynamic> datos, {int codigo = 0}) {
    _salida.escribir(jsonEncode(datos));
    return codigo;
  }

  void _linea(String s) => _salida.escribir(s);

  int _ok(String s) {
    _linea(s);
    return 0;
  }

  void _fallar(String s) {
    if (_json) {
      _salida.escribir(jsonEncode({'error': s}));
    } else {
      _salida.escribirError('granolazo: $s');
    }
  }

  /// El respaldo de la carpeta de videos a Drive: ver, configurar, correr y liberar.
  Future<int> _respaldo(List<String> resto, List<String> args) async {
    final r = _respaldoInyectado ??
        RespaldoService(
          ajustes: _ajustes,
          consultarTranscripciones: _api.itemsPorArchivoDrive,
        );
    await r.cargar();
    final sub = resto.where((a) => a == 'ahora' || a == 'liberar').firstOrNull;

    final activar = _texto(args, '--activar');
    if (activar != null) {
      if (activar != 'si' && activar != 'no') {
        _fallar('--activar acepta "si" o "no"');
        return 2;
      }
      await r.activar(activar == 'si', revisar: false);
    }
    final transcribir = _texto(args, '--transcribir');
    if (transcribir != null) {
      if (transcribir != 'si' && transcribir != 'no') {
        _fallar('--transcribir acepta "si" o "no"');
        return 2;
      }
      await r.activarTranscripcion(transcribir == 'si', revisar: false);
    }
    final carpeta = _texto(args, '--carpeta');
    if (carpeta != null) await r.cambiarCarpetaLocal(carpeta);
    final perfil = _texto(args, '--perfil-gws');
    if (perfil != null) await r.cambiarPerfilGws(perfil);
    final drive = _texto(args, '--drive');
    if (drive != null) await r.cambiarCarpetaDrive(drive);

    if (sub == 'ahora') {
      var ultimo = '';
      void mostrar() {
        final a = r.enCurso;
        if (_json || a == null) return;
        final linea = '${a.nombre}  ${(a.progreso * 100).floor()} %';
        if (linea != ultimo) _linea(ultimo = linea);
      }

      r.addListener(mostrar);
      await r.revisarAhora();
      r.removeListener(mostrar);
    }

    if (sub == 'liberar') {
      if (!args.contains('--si')) {
        return _ok('se liberarian ${tamanoLegible(r.bytesLiberables)} '
            '(${r.respaldados.length} videos ya en Drive). Confirmar con --si');
      }
      final res = await r.liberarEspacio();
      final datos = {
        'liberados': res.liberados,
        'bytes': res.bytes,
        'fallidos': res.fallidos,
      };
      if (_json) return _emitirJson(datos, codigo: res.fallidos.isEmpty ? 0 : 1);
      _linea('liberados ${tamanoLegible(res.bytes)} (${res.liberados} videos)');
      for (final e in res.fallidos.entries) {
        _linea('  no se borro ${e.key}: ${e.value}');
      }
      return res.fallidos.isEmpty ? 0 : 1;
    }

    await r.actualizarTranscripciones();
    final enGranolazo = [
      for (final a in [...r.respaldados, ...r.liberados])
        if (r.vaATranscribirse(a)) a,
    ];
    final transcritos =
        enGranolazo.where((a) => r.transcripcionDe(a)?.estado == 'transcribed').length;
    final estado = {
      'activo': r.activo,
      'transcribir': r.transcribir,
      'en_granolazo': enGranolazo.length,
      'transcritos': transcritos,
      'carpeta_local': r.carpetaLocal,
      'carpeta_drive': r.carpetaDrive,
      'perfil_gws': r.perfilGws,
      'por_subir': r.pendientes.length + r.conError.length,
      'bytes_por_subir': r.bytesPendientes,
      'con_error': r.conError.length,
      'respaldados_en_equipo': r.respaldados.length,
      'bytes_liberables': r.bytesLiberables,
      'liberados': r.liberados.length,
      'error': r.errorGeneral,
      'errores': {for (final a in r.conError) a.nombre: a.error},
    };
    final codigo = r.errorGeneral == null ? 0 : 1;
    if (_json) return _emitirJson(estado, codigo: codigo);
    _linea('respaldo automatico   ${r.activo ? "encendido" : "apagado"}');
    _linea('transcribir           ${r.transcribir ? "si" : "no"} '
        '($transcritos de ${enGranolazo.length} ya transcritos)');
    _linea('carpeta del equipo    ${r.carpetaLocal}');
    _linea('carpeta de drive      ${r.carpetaDrive}');
    _linea('perfil de gws         ${r.perfilGws.isEmpty ? "(por defecto)" : r.perfilGws}');
    _linea('por subir             ${estado['por_subir']} '
        '(${tamanoLegible(r.bytesPendientes)})');
    _linea('en drive y en equipo  ${r.respaldados.length} '
        '(${tamanoLegible(r.bytesLiberables)} liberables)');
    _linea('ya liberados          ${r.liberados.length}');
    for (final a in r.conError) {
      _linea('  error ${a.nombre}: ${a.error}');
    }
    if (r.errorGeneral != null) _fallar(r.errorGeneral!);
    return codigo;
  }

  void _ayuda() {
    _linea('''
Granolazo — graba, transcribe y deja la reunion en el backend.

  granolazo_app                          abre la ventana
  granolazo_app <comando> [opciones]      corre sin ventana y responde por consola

Comandos de este dispositivo
  estado                     motor, backend y cuantas grabaciones hay en cola
  listar [--limite N]        las grabaciones del dispositivo
  importar <archivo...>      encola audios que ya estan en el disco
                             [--procesar] transcribe y sube en el acto
  grabar                     graba hasta que se aprieta Enter
                             [--segundos N] graba un rato fijo
                             [--no-procesar] deja la grabacion en la cola
  procesar                   transcribe y sube todo lo pendiente
  reintentar [id...]         reintenta lo que quedo con error
  eliminar <id...>           saca grabaciones de la cola y borra su audio
                             [--subidas] todas las que ya llegaron a Granolazo
  modelo                     el modelo de Whisper que corre en este equipo
                             [--usar base|small|medium] [--bajar]
  clave                      dice si hay clave del servicio en linea guardada
                             [--desde-env VARIABLE] la toma del entorno
                             [--poner VALOR] la escribe directo
                             [--borrar] la saca del almacen seguro
  config                     muestra o cambia los ajustes
                             [--motor local|api]  local = este equipo, gratis
                             [--auto si|no]       transcribir apenas termina de grabar
                             [--volumen-microfono N] [--volumen-equipo N]
                                                  0 a 3; 1 = dejar como esta
                             [--dispositivo NOMBRE] [--idioma es] [--subida si|no]
                             [--en-vivo si|no]    borrador de texto mientras se graba
                             [--en-vivo-modelo tiny|base|small] [--en-vivo-trozo SEG]
                             [--en-vivo-hilos N] [--en-vivo-puerto N]  (0 = sin endpoint)
  en-vivo                    el texto de la grabacion en curso (borrador)
                             [--seguir] lo va mostrando hasta que termina
                             [--ultima] la ultima, aunque ya haya terminado
                             sale 3 si no hay ninguna grabacion en vivo en curso
  en-vivo-prueba <wav>       ensaya el borrador con un WAV 16 kHz mono (sin microfono)
                             [--velocidad N] 1 = tiempo real
  probar                     comprueba que el backend responde
  reuniones-en-curso         que aplicacion esta usando el microfono ahora
  arranque                   arrancar al prender el computador
                             [--activar] [--desactivar]
  respaldo                   respaldo de la carpeta de videos en Drive
                             [ahora] revisa y sube lo que falta, con avance
                             [liberar --si] borra del equipo lo ya respaldado,
                                  comprobando cada archivo en Drive antes
                             [--activar si|no] respaldo automatico
                             [--transcribir si|no] mandarlos a Granolazo
                             [--carpeta RUTA] [--drive ENLACE|ID]
                             [--perfil-gws RUTA] sesion de gws a usar

Comandos de Granolazo (lo que hay en el backend, de cualquier fuente)
  entrar --email X           inicia sesion
                             [--desde-env VARIABLE] la contrasena, sin exponerla
                             [--clave VALOR] directo (queda en el historial)
  salir                      cierra la sesion
  quien                      con que cuenta se esta trabajando
  reuniones                  lista reuniones del backend
                             [--texto Q] [--grupo G] [--tag T] [--fuente F]
                             [--estado pending|transcribed|error] [--persona P]
                             [--desde AAAA-MM-DD] [--hasta AAAA-MM-DD] [--limite N]
  ver <id>                   la transcripcion completa de una reunion
                             [--resumen] el resumen en vez de la transcripcion
  cola                       que se esta transcribiendo, que espera y que fallo
  filtros                    grupos, tags y fuentes que existen hoy

Opciones generales
  --json                     responde una linea de JSON, para scripts
  --ayuda                    esto

Por defecto se transcribe con el procesador de este equipo -gratis y sin
conexion- y grabar NO dispara la transcripcion: la grabacion queda en espera
hasta que se corra `procesar`. Se cambia con `config --motor` y `config --auto`.

La clave del servicio en linea se guarda en el almacen seguro del sistema.
Preferir --desde-env antes que --poner: lo que va en la linea de comandos queda
en el historial del shell y a la vista de otros procesos.''');
  }
}
