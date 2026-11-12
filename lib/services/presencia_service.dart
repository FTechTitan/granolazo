import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'ajustes_service.dart';
import 'detector_reuniones.dart';
import 'puente_android.dart';
import '../ui/aviso_reunion.dart';

/// Cómo se presenta la app: ventana normal, escondida en la bandeja, o asomando el aviso.
enum ModoVentana { normal, oculta, aviso }

/// Maneja la ventana, la bandeja del sistema y cuándo asomar el aviso de reunión.
///
/// Existe para que esa coreografía viva en un solo lado. Son tres cosas que se pisan entre
/// sí —el tamaño de la ventana, si está siempre encima, y si aparece en la barra de
/// tareas— y repartirlas por la interfaz termina en una ventana que queda chica y encima
/// de todo cuando no corresponde.
///
/// **En Android no hay ventanas que mover.** Con la app abierta, el aviso aparece como una
/// banda adentro, igual que en el escritorio; con la app cerrada lo muestra el vigilante
/// nativo como una notificación con botones. No se usa una ventana flotante a propósito:
/// exige el permiso de "mostrar sobre otras apps", de los más invasivos que hay, y taparle
/// la pantalla a alguien que está en una llamada es lo contrario de sutil.
class PresenciaService extends ChangeNotifier with TrayListener, WindowListener {
  PresenciaService({
    required this.detector,
    required AjustesService ajustes,
    PuenteAndroid? puente,
  })  : _puente = puente ?? PuenteAndroid(),
        // El linter pediria `this._ajustes`, pero Dart no admite parametros con nombre
        // que empiecen con guion bajo.
        // ignore: prefer_initializing_formals
        _ajustes = ajustes;

  final DetectorReuniones detector;
  final AjustesService _ajustes;
  final PuenteAndroid _puente;

  ModoVentana _modo = ModoVentana.normal;
  AppEnLlamada? _sugerida;
  Size _tamanoNormal = const Size(1280, 720);
  bool _iniciado = false;

  ModoVentana get modo => _modo;

  /// La reunión por la que se está preguntando, si se está preguntando.
  AppEnLlamada? get sugerida => _sugerida;

  /// Qué hacer cuando el usuario acepta grabar desde el aviso.
  VoidCallback? alAceptarGrabar;

  /// ¿Hay ventana y bandeja que manejar? En el teléfono no.
  bool get conVentana => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  bool get soportado => conVentana || Platform.isAndroid;

  Future<void> iniciar({required bool arrancarOculta}) async {
    if (!soportado || _iniciado) return;
    _iniciado = true;

    if (conVentana) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      await _montarBandeja();

      // Cerrar la ventana esconde en vez de terminar: si la app se cierra, deja de vigilar
      // y la detección no sirve para nada.
      await windowManager.setPreventClose(true);

      if (arrancarOculta) {
        await windowManager.hide();
        await windowManager.setSkipTaskbar(true);
        _modo = ModoVentana.oculta;
        notifyListeners();
      }
    } else if (Platform.isAndroid) {
      // Sin este permiso, en Android 13 y posteriores el aviso de reunión no se ve —y el
      // aviso es la mitad de la función.
      await _puente.pedirNotificaciones();
    }

    detector.addListener(_alDetectar);
    if (await _detectarActiva()) {
      detector.empezar();
      // En Android el que avisa con la app cerrada es el vigilante nativo, no este
      // detector: hay que encenderlo aparte.
      if (Platform.isAndroid) await _puente.vigilante(true);
    }
  }

  /// En Android manda el ajuste nativo: el vigilante tiene que poder leerlo al encender el
  /// teléfono, cuando todavía no existe ningún motor de Flutter al que preguntarle.
  Future<bool> _detectarActiva() async => Platform.isAndroid
      ? _puente.detectarActivo()
      : _ajustes.leerDetectarReuniones();

  Future<void> _montarBandeja() async {
    if (!conVentana) return;
    try {
      // El icono de la app sirve; no hay uno propio de bandeja todavía.
      await trayManager.setIcon(
        Platform.isWindows ? 'windows/runner/resources/app_icon.ico' : 'assets/icon.png',
      );
      await trayManager.setToolTip('Granolazo');
      await _refrescarMenu();
    } catch (_) {
      // Sin bandeja la app sigue siendo usable como ventana normal.
    }
  }

  Future<void> _refrescarMenu() async {
    if (!conVentana) return;
    final detectando = await _detectarActiva();
    try {
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'abrir', label: 'Abrir Granolazo'),
        MenuItem.separator(),
        MenuItem.checkbox(
          key: 'detectar',
          label: 'Avisarme cuando empiece una reunión',
          checked: detectando,
        ),
        MenuItem.separator(),
        MenuItem(key: 'salir', label: 'Salir'),
      ]));
    } catch (_) {
      // Ídem: el menú es comodidad, no es el producto.
    }
  }

  void _alDetectar() {
    final app = detector.principal;
    if (app == null) {
      if (_modo == ModoVentana.aviso) unawaited(ocultarAviso());
      return;
    }
    // Si la ventana está a la vista, el aviso va adentro y no se asoma nada: sacarle la
    // ventana de las manos a alguien que la está usando es lo contrario de sutil.
    if (_modo == ModoVentana.normal) {
      _sugerida = app;
      notifyListeners();
      return;
    }
    unawaited(mostrarAviso(app));
  }

  /// Asoma la ventana chica abajo a la derecha, sin robar el foco.
  Future<void> mostrarAviso(AppEnLlamada app) async {
    if (!soportado) return;
    _sugerida = app;
    if (!conVentana || _modo == ModoVentana.normal) {
      notifyListeners();
      return;
    }
    try {
      if (_modo != ModoVentana.aviso) {
        _tamanoNormal = await windowManager.getSize();
      }
      _modo = ModoVentana.aviso;
      notifyListeners();

      await windowManager.setSkipTaskbar(true);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setSize(AvisoReunion.tamano);
      await windowManager.setAlignment(Alignment.bottomRight);
      // showWithoutFocus: aparece sin interrumpir lo que se esté escribiendo.
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      await windowManager.show(inactive: true);
    } catch (_) {
      _modo = ModoVentana.oculta;
      notifyListeners();
    }
  }

  Future<void> ocultarAviso() async {
    if (_modo != ModoVentana.aviso) return;
    _sugerida = null;
    _modo = ModoVentana.oculta;
    notifyListeners();
    try {
      await windowManager.setAlwaysOnTop(false);
      await windowManager.hide();
    } catch (_) {}
  }

  /// Vuelve a la ventana de siempre y la trae al frente.
  Future<void> abrirNormal() async {
    _sugerida = null;
    _modo = ModoVentana.normal;
    notifyListeners();
    if (!conVentana) return;
    try {
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      await windowManager.setSize(_tamanoNormal);
      await windowManager.center();
      await windowManager.setSkipTaskbar(false);
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
  }

  Future<void> esconder() async {
    if (!conVentana) return;
    _modo = ModoVentana.oculta;
    notifyListeners();
    try {
      await windowManager.setSkipTaskbar(true);
      await windowManager.hide();
    } catch (_) {}
  }

  /// Acepta la sugerencia: abre la ventana normal y arranca a grabar.
  Future<void> aceptarSugerencia() async {
    final accion = alAceptarGrabar;
    await abrirNormal();
    accion?.call();
  }

  void descartarSugerencia() {
    if (_modo == ModoVentana.aviso) {
      unawaited(ocultarAviso());
    } else {
      _sugerida = null;
      notifyListeners();
    }
  }

  void ignorarApp() {
    final app = _sugerida;
    if (app != null) detector.ignorar(app);
    descartarSugerencia();
  }

  Future<void> cambiarDeteccion(bool activa) async {
    await _ajustes.guardarDetectarReuniones(activa);
    if (Platform.isAndroid) await _puente.vigilante(activa);
    if (activa) {
      detector.empezar();
    } else {
      detector.parar();
      _sugerida = null;
      notifyListeners();
    }
    await _refrescarMenu();
  }

  // ── bandeja ──────────────────────────────────────────────────────────────────

  @override
  void onTrayIconMouseDown() => unawaited(abrirNormal());

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'abrir':
        unawaited(abrirNormal());
      case 'detectar':
        unawaited(cambiarDeteccion(!(menuItem.checked ?? false)));
      case 'salir':
        unawaited(_salirDeVerdad());
    }
  }

  Future<void> _salirDeVerdad() async {
    try {
      await windowManager.setPreventClose(false);
      await trayManager.destroy();
      await windowManager.destroy();
    } catch (_) {
      exit(0);
    }
  }

  // ── ventana ──────────────────────────────────────────────────────────────────

  @override
  void onWindowClose() {
    // Cerrar esconde. Salir de verdad es la opción del menú de la bandeja.
    unawaited(esconder());
  }

  @override
  void dispose() {
    detector.removeListener(_alDetectar);
    if (conVentana) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    super.dispose();
  }
}
