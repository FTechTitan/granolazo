import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Dónde guarda la app sus datos (cola, ajustes, modelos, estado en vivo).
///
/// Por defecto es la carpeta de soporte que da el sistema. La variable de entorno
/// `GRANOLAZO_DATOS_DIR` la redirige: sirve para probar la app o una build nueva sin
/// tocar la cola real de la instalación normal. Nada más cambia si no está puesta.
abstract final class DatosApp {
  static const variableEntorno = 'GRANOLAZO_DATOS_DIR';

  /// La carpeta pedida por la variable de entorno, o `null` si no está puesta.
  static String? get carpetaForzada {
    final v = Platform.environment[variableEntorno]?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  /// Carpeta de datos de la app, creada si no existe.
  static Future<Directory> carpeta() async {
    final forzada = carpetaForzada;
    final dir = forzada != null
        ? Directory(forzada)
        : await getApplicationSupportDirectory();
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Si hay carpeta forzada, hace que TODO lo que pida una ruta de datos a `path_provider`
  /// —ajustes de `shared_preferences`, modelos de Whisper, grabaciones— caiga ahí.
  /// Llamarlo una vez, al arrancar `main`, antes de leer cualquier ajuste.
  static void aplicarRedireccion() {
    final forzada = carpetaForzada;
    if (forzada == null) return;
    PathProviderPlatform.instance =
        _RutasRedirigidas(PathProviderPlatform.instance, forzada);
  }
}

/// Delega todo al `path_provider` real salvo las carpetas de datos de la app.
class _RutasRedirigidas extends PathProviderPlatform {
  _RutasRedirigidas(this._real, this._raiz);

  final PathProviderPlatform _real;
  final String _raiz;

  String _sub(String nombre) => '$_raiz${Platform.pathSeparator}$nombre';

  @override
  Future<String?> getApplicationSupportPath() async => _raiz;

  @override
  Future<String?> getApplicationDocumentsPath() async => _sub('documentos');

  @override
  Future<String?> getApplicationCachePath() async => _sub('cache');

  @override
  Future<String?> getTemporaryPath() => _real.getTemporaryPath();

  @override
  Future<String?> getLibraryPath() => _real.getLibraryPath();

  @override
  Future<String?> getDownloadsPath() => _real.getDownloadsPath();
}
