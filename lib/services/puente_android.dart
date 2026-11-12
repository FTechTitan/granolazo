import 'dart:io';

import 'package:flutter/services.dart';

/// Lo que el teléfono sabe y la app no puede averiguar sola.
///
/// Del otro lado hay servicios que **viven más que la pantalla**: el que sostiene la
/// grabación cuando el usuario cambia de aplicación, y el que queda esperando a que empiece
/// una reunión aunque la app esté cerrada. Por eso algunas cosas se preguntan acá en vez de
/// resolverse en Dart: cuando el teléfono se enciende y arranca el vigilante, todavía no
/// existe ningún motor de Flutter al que consultarle.
///
/// Todo devuelve un valor por omisión en vez de lanzar. Una app de grabar no se puede caer
/// porque el sistema no contestó si hay una llamada en curso.
class PuenteAndroid {
  PuenteAndroid({MethodChannel? canal})
      : _canal = canal ?? const MethodChannel('granolazo/android');

  final MethodChannel _canal;

  static bool get soportado => Platform.isAndroid;

  /// Órdenes que llegan desde los botones de una notificación: `grabar` o `detener`.
  void escuchar(void Function(String orden) alRecibir, {void Function(String?)? alCapturar}) {
    if (!soportado) return;
    _canal.setMethodCallHandler((llamada) async {
      switch (llamada.method) {
        case 'orden':
          final o = llamada.arguments as String?;
          if (o != null) alRecibir(o);
        case 'captura':
          alCapturar?.call(llamada.arguments as String?);
      }
      return null;
    });
  }

  /// La orden con la que se abrió la app, si se abrió desde una notificación.
  ///
  /// Hace falta además del canal: si la app estaba cerrada, cuando el botón se aprieta no
  /// hay motor escuchando, así que la orden queda esperando a que termine de arrancar.
  Future<String?> ordenPendiente() async => _invocar<String>('ordenPendiente');

  /// Avisa que empezó o terminó una grabación, para prender o apagar el servicio que la
  /// sostiene en segundo plano.
  Future<void> marcarGrabando(bool si) => _invocar<bool>('grabando', si);

  /// ¿Hay una llamada en curso, y de qué aplicación?
  Future<({bool activa, String? app, bool vigilando})> enLlamada() async {
    final m = await _invocar<Map<Object?, Object?>>('enLlamada');
    if (m == null) return (activa: false, app: null, vigilando: false);
    return (
      activa: m['activa'] == true,
      app: m['app'] as String?,
      vigilando: m['vigilando'] == true,
    );
  }

  Future<bool> vigilante(bool encender) async =>
      await _invocar<bool>('vigilante', encender) ?? false;

  Future<bool> detectarActivo() async => await _invocar<bool>('detectarActivo') ?? true;

  Future<bool> arranque(bool encender) async =>
      await _invocar<bool>('arranque', encender) ?? false;

  Future<bool> arranqueActivo() async => await _invocar<bool>('arranqueActivo') ?? false;

  /// Pide el permiso de notificaciones. Sin él, en Android 13 y posteriores, el aviso de
  /// reunión no se ve —y el aviso es la mitad de la función.
  Future<void> pedirNotificaciones() => _invocar<bool>('pedirNotificaciones');

  /// Abre los ajustes de "acceso al uso" del sistema. Opcional: sirve solo para poder
  /// nombrar la aplicación que está en llamada en vez de decir "una llamada".
  Future<bool> abrirUsoDeApps() async => await _invocar<bool>('abrirUsoDeApps') ?? false;

  /// La llave del modo consola por `adb`.
  Future<String?> cliToken() async => _invocar<String>('cliToken');

  Future<T?> _invocar<T>(String metodo, [Object? argumentos]) async {
    if (!soportado) return null;
    try {
      return await _canal.invokeMethod<T>(metodo, argumentos);
    } catch (_) {
      // El canal no está en los tests ni en escritorio.
      return null;
    }
  }
}
