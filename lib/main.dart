import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'cli/granolazo_cli.dart';
import 'cli/salida_consola.dart';
import 'controllers/grabaciones_controller.dart';
import 'services/ajustes_service.dart';
import 'services/arranque_service.dart';
import 'services/datos_app.dart';
import 'services/detector_reuniones.dart';
import 'services/granolazo_api.dart';
import 'services/presencia_service.dart';
import 'services/puente_android.dart';
import 'services/reproductor_service.dart';
import 'services/respaldo_service.dart';
import 'services/sesion_service.dart';
import 'ui/pantalla_principal.dart';

/// Punto de entrada único: la misma app atiende la ventana y la consola.
///
/// En escritorio, Flutter entrega los argumentos de la línea de comandos a `main`. Si hay
/// alguno, se corre el modo consola y el proceso termina sin dibujar nada; el arranque
/// nativo de Windows aplica la misma regla para no abrir la ventana.
void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  DatosApp.aplicarRedireccion();

  if (GranolazoCli.esInvocacionDeConsola(args)) {
    final salida = SalidaConsola.delSistema();
    final codigo = await GranolazoCli(salida: salida).ejecutar(args);
    await salida.terminar(codigo);
  }

  // Arrancada por el sistema al encender: se va a la bandeja sin abrir ventana. Que se
  // abra sola una ventana en cada encendido seria motivo suficiente para desactivarlo.
  final enBandeja = args.contains(ArranqueService.banderaBandeja);

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        size: const Size(1280, 720),
        center: true,
        title: 'Granolazo',
        skipTaskbar: enBandeja,
      ),
      () async {
        if (!enBandeja) {
          await windowManager.show();
          await windowManager.focus();
        }
      },
    );
  }

  runApp(GranolazoApp(enBandeja: enBandeja));
}

/// El modo consola en Android.
///
/// Un teléfono no tiene terminal, así que la superficie equivalente es `adb`. Este es el
/// punto de entrada que levanta el receptor nativo en un motor de Flutter **sin pantalla**:
/// corre el mismo [GranolazoCli] que usa Windows, con los mismos comandos, el mismo `--json`
/// y los mismos códigos de salida. Duplicar la lógica en Kotlin habría garantizado que las
/// dos versiones se separaran en la primera semana.
///
/// La anotación no es decorativa: sin ella el compilador de Dart en modo release descarta
/// esta función, porque nada dentro del programa la llama.
@pragma('vm:entry-point')
void cliAndroid() async {
  WidgetsFlutterBinding.ensureInitialized();
  DatosApp.aplicarRedireccion();
  const canal = MethodChannel('granolazo/cli');
  canal.setMethodCallHandler((llamada) async {
    if (llamada.method != 'ejecutar') return null;
    final crudo = (llamada.arguments as List).first as String;
    final salida = SalidaEnMemoria();
    var codigo = 2;
    try {
      codigo = await GranolazoCli(salida: salida)
          .ejecutar(GranolazoCli.partirLinea(crudo));
    } catch (e) {
      salida.escribirError('$e');
      codigo = 1;
    }
    return {'salida': salida.texto, 'codigo': codigo};
  });
}

class GranolazoApp extends StatefulWidget {
  const GranolazoApp({super.key, this.enBandeja = false});

  /// Arrancó desde el sistema: no se muestra ventana, solo el icono de la bandeja.
  final bool enBandeja;

  @override
  State<GranolazoApp> createState() => _GranolazoAppState();
}

class _GranolazoAppState extends State<GranolazoApp> {
  late final SesionService _sesion;
  late final GranolazoApi _api;
  late final GrabacionesController _controller;
  late final ReproductorService _reproductor;
  late final DetectorReuniones _detector;
  late final PresenciaService _presencia;
  late final PuenteAndroid _puente;

  /// Solo en Windows: sube la carpeta de videos a Drive usando la sesión de `gws`.
  RespaldoService? _respaldo;

  @override
  void initState() {
    super.initState();
    // Una sola sesión y un solo cliente para toda la app: así el token que se renueva
    // en un lado vale en todos, y no hay dos vistas discrepando sobre quién está dentro.
    _sesion = SesionService();
    _api = GranolazoApi(sesion: _sesion);
    _controller = GrabacionesController(api: _api);
    _reproductor = ReproductorService();
    _detector = DetectorReuniones();
    _puente = PuenteAndroid();
    _presencia = PresenciaService(
      detector: _detector,
      ajustes: AjustesService(),
      puente: _puente,
    );
    _presencia.alAceptarGrabar = _controller.comenzarGrabacion;
    _controller.iniciar();
    _presencia.iniciar(arrancarOculta: widget.enBandeja);
    if (Platform.isWindows) {
      _respaldo = RespaldoService(consultarTranscripciones: _api.itemsPorArchivoDrive)
        ..iniciar();
    }
    _atenderAlTelefono();
  }

  /// Los botones de las notificaciones de Android terminan acá.
  ///
  /// La grabación la maneja Dart, no el servicio nativo: quién sabe dónde va el archivo,
  /// con qué ganancias mezclar y en qué estado queda la ficha es este lado. Así que el
  /// botón trae la app al frente con la orden puesta, en vez de duplicar esa lógica en
  /// Kotlin y que las dos se separen.
  void _atenderAlTelefono() {
    if (!PuenteAndroid.soportado) return;
    _puente.escuchar(
      (orden) {
        switch (orden) {
          case 'grabar':
            if (!_controller.grabando) _controller.comenzarGrabacion();
          case 'detener':
            if (_controller.grabando) _controller.detenerGrabacion();
        }
      },
      // La captura de la salida se resuelve después de contestar: si el servicio no pudo
      // tomarla, el aviso llega por acá y la interfaz lo muestra.
      alCapturar: _controller.anotarFallaDeCaptura,
    );
    // Si la app estaba cerrada cuando se apretó el botón, no había motor escuchando.
    _puente.ordenPendiente().then((orden) {
      if (orden == 'grabar' && !_controller.grabando) _controller.comenzarGrabacion();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _reproductor.dispose();
    _presencia.dispose();
    _detector.dispose();
    _respaldo?.dispose();
    _sesion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Granolazo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3D5AFE),
          brightness: Brightness.dark,
        ),
      ),
      home: PantallaPrincipal(
        controller: _controller,
        api: _api,
        sesion: _sesion,
        reproductor: _reproductor,
        presencia: _presencia,
        respaldo: _respaldo,
      ),
    );
  }
}
