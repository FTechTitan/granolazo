import 'dart:io';

import 'puente_android.dart';

/// Hacer que la app arranque sola al prender el equipo.
///
/// **En Windows** se escribe una entrada en la clave `Run` del usuario. Es la forma
/// estándar y, sobre todo, **reversible y visible**: aparece en el Administrador de tareas,
/// pestaña Inicio, donde cualquiera puede desactivarla sin pasar por la app. Un servicio o
/// una tarea programada arrancarían antes, pero se esconden y cuesta sacarlos.
///
/// Arranca con `--bandeja`: la app se va a la bandeja del sistema sin abrir ventana. Que
/// se abra sola una ventana en cada encendido sería motivo suficiente para desactivarlo.
///
/// **En Android** el equivalente es un receptor de `BOOT_COMPLETED`, y lo que arranca no es
/// la app sino el vigilante que espera a que empiece una reunión —abrir una pantalla sola
/// cada vez que se enciende el teléfono sería motivo suficiente para desinstalarla—. Se
/// apaga desde los ajustes del sistema igual que en Windows, sin depender de la app.
class ArranqueService {
  ArranqueService({
    Future<ProcessResult> Function(String, List<String>)? correr,
    PuenteAndroid? puente,
  })  : _correr = correr ?? Process.run,
        _puente = puente ?? PuenteAndroid();

  final Future<ProcessResult> Function(String, List<String>) _correr;
  final PuenteAndroid _puente;

  static const _clave = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _nombre = 'Granolazo';

  /// Bandera con la que se arranca desde el sistema.
  static const banderaBandeja = '--bandeja';

  bool get soportado => Platform.isWindows || Platform.isAndroid;

  Future<bool> get activo async {
    if (Platform.isAndroid) return _puente.arranqueActivo();
    if (!soportado) return false;
    try {
      final r = await _correr('reg', ['query', _clave, '/v', _nombre]);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Devuelve `null` si salió bien, o el motivo si no.
  Future<String?> activar() async {
    if (Platform.isAndroid) {
      // Encender el arranque enciende también la detección: lo único que se arranca al
      // encender el teléfono es el vigilante, así que uno sin la otra no haría nada.
      final ok = await _puente.arranque(true);
      return ok ? null : 'no pude activar el arranque automático';
    }
    if (!soportado) return 'todavía solo en Windows y Android';
    final exe = Platform.resolvedExecutable;
    try {
      final r = await _correr('reg', [
        'add', _clave,
        '/v', _nombre,
        '/t', 'REG_SZ',
        // Las comillas importan: la ruta tiene espacios y sin ellas Windows intentaría
        // ejecutar el primer pedazo.
        '/d', '"$exe" $banderaBandeja',
        '/f',
      ]);
      return r.exitCode == 0 ? null : 'no pude escribir el arranque automático';
    } catch (e) {
      return 'no pude escribir el arranque automático: $e';
    }
  }

  Future<String?> desactivar() async {
    if (Platform.isAndroid) {
      await _puente.arranque(false);
      return null;
    }
    if (!soportado) return null;
    try {
      final r = await _correr('reg', ['delete', _clave, '/v', _nombre, '/f']);
      // Borrar algo que no estaba no es un error.
      return r.exitCode == 0 ? null : null;
    } catch (e) {
      return 'no pude quitar el arranque automático: $e';
    }
  }

  /// La ruta con la que quedó registrado, para poder mostrarla.
  Future<String?> rutaRegistrada() async {
    if (Platform.isAndroid) {
      return await _puente.arranqueActivo()
          ? 'el vigilante arranca al encender el teléfono'
          : null;
    }
    if (!soportado) return null;
    try {
      final r = await _correr('reg', ['query', _clave, '/v', _nombre]);
      if (r.exitCode != 0) return null;
      for (final linea in r.stdout.toString().split('\n')) {
        final t = linea.trim();
        if (!t.startsWith(_nombre)) continue;
        final partes = t.split(RegExp(r'\s{2,}'));
        if (partes.length >= 3) return partes[2].trim();
      }
    } catch (_) {
      // Sin dato es mejor que un dato inventado.
    }
    return null;
  }
}
