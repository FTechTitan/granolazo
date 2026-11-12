import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ajustes de la app.
///
/// La clave de transcripción vive en el almacén seguro del sistema (Keystore en Android,
/// DPAPI en Windows), nunca en preferencias planas ni en el código. El resto de las
/// preferencias, que no son secretas, van en `SharedPreferences`.
class AjustesService {
  AjustesService({FlutterSecureStorage? seguro})
      : _seguro = seguro ?? const FlutterSecureStorage();

  final FlutterSecureStorage _seguro;

  static const _kClaveTranscripcion = 'clave_transcripcion';
  static const _kNombreDispositivo = 'nombre_dispositivo';
  static const _kSubidaAutomatica = 'subida_automatica';
  static const _kIdiomaAudio = 'idioma_audio';
  static const _kMotorTranscripcion = 'motor_transcripcion';
  static const _kModeloLocal = 'modelo_local';
  static const _kTranscripcionAutomatica = 'transcripcion_automatica';
  static const _kGananciaMicrofono = 'ganancia_microfono';
  static const _kGananciaSistema = 'ganancia_sistema';
  static const _kDetectarReuniones = 'detectar_reuniones';
  static const _kRespaldoActivo = 'respaldo_activo';
  static const _kRespaldoCarpetaLocal = 'respaldo_carpeta_local';
  static const _kRespaldoCarpetaDrive = 'respaldo_carpeta_drive';
  static const _kRespaldoPerfilGws = 'respaldo_perfil_gws';
  static const _kRespaldoTranscribir = 'respaldo_transcribir';
  static const _kEnVivo = 'transcripcion_en_vivo';
  static const _kEnVivoModelo = 'en_vivo_modelo';
  static const _kEnVivoTrozo = 'en_vivo_trozo_seg';
  static const _kEnVivoHilos = 'en_vivo_hilos';
  static const _kEnVivoPuerto = 'en_vivo_puerto';

  Future<String?> leerClaveTranscripcion() async {
    final v = await _seguro.read(key: _kClaveTranscripcion);
    return (v == null || v.trim().isEmpty) ? null : v.trim();
  }

  Future<void> guardarClaveTranscripcion(String? clave) async {
    if (clave == null || clave.trim().isEmpty) {
      await _seguro.delete(key: _kClaveTranscripcion);
      return;
    }
    await _seguro.write(key: _kClaveTranscripcion, value: clave.trim());
  }

  Future<bool> get hayClaveTranscripcion async =>
      (await leerClaveTranscripcion()) != null;

  Future<String> leerNombreDispositivo(String porDefecto) async {
    final p = await SharedPreferences.getInstance();
    final v = p.getString(_kNombreDispositivo);
    return (v == null || v.trim().isEmpty) ? porDefecto : v.trim();
  }

  Future<void> guardarNombreDispositivo(String nombre) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kNombreDispositivo, nombre.trim());
  }

  Future<bool> leerSubidaAutomatica() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kSubidaAutomatica) ?? true;
  }

  Future<void> guardarSubidaAutomatica(bool valor) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kSubidaAutomatica, valor);
  }

  Future<String> leerIdiomaAudio() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kIdiomaAudio) ?? 'es';
  }

  Future<void> guardarIdiomaAudio(String idioma) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kIdiomaAudio, idioma);
  }

  /// `local` (el procesador de este equipo) o `api` (el servicio en línea).
  ///
  /// El valor por defecto es `local`: sale gratis, funciona sin conexión y no obliga a
  /// tener una clave de un proveedor guardada en el dispositivo.
  Future<String> leerMotorTranscripcion() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kMotorTranscripcion) ?? 'local';
  }

  Future<void> guardarMotorTranscripcion(String motor) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kMotorTranscripcion, motor);
  }

  Future<String> leerModeloLocal() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kModeloLocal) ?? 'small';
  }

  Future<void> guardarModeloLocal(String modelo) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kModeloLocal, modelo);
  }

  /// ¿Transcribir apenas termina de grabar?
  ///
  /// Apagado por defecto, por diseno: grabar tiene que poder hacerse sin
  /// clave, sin conexión y sin gastar, y la decisión de cuándo y con qué transcribir
  /// viene después. Con esto apagado la grabación queda `enEspera` y nadie la toca.
  Future<bool> leerTranscripcionAutomatica() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kTranscripcionAutomatica) ?? false;
  }

  Future<void> guardarTranscripcionAutomatica(bool valor) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kTranscripcionAutomatica, valor);
  }

  /// Cuánto se sube o se baja cada fuente al mezclarlas. 1 es dejarla como está.
  ///
  /// Existe porque las dos rara vez entran parejas: en una llamada, el otro sale por los
  /// parlantes a un volumen y uno habla al micrófono a otro. Si una tapa a la otra, la
  /// transcripción pierde la mitad de la conversación.
  Future<double> leerGananciaMicrofono() async {
    final p = await SharedPreferences.getInstance();
    return p.getDouble(_kGananciaMicrofono) ?? 1.0;
  }

  Future<void> guardarGananciaMicrofono(double v) async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kGananciaMicrofono, v);
  }

  Future<double> leerGananciaSistema() async {
    final p = await SharedPreferences.getInstance();
    return p.getDouble(_kGananciaSistema) ?? 1.0;
  }

  Future<void> guardarGananciaSistema(double v) async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kGananciaSistema, v);
  }

  /// ¿Avisar cuando otra aplicación empieza a usar el micrófono?
  ///
  /// Encendido por defecto: es lo que hace que la app sirva sin acordarse de ella. Quien
  /// lo encuentre molesto lo apaga desde la bandeja, sin entrar a los ajustes.
  Future<bool> leerDetectarReuniones() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kDetectarReuniones) ?? true;
  }

  Future<void> guardarDetectarReuniones(bool valor) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kDetectarReuniones, valor);
  }

  /// ¿Subir sola a Drive la carpeta de videos del equipo?
  ///
  /// Apagado por defecto: sube gigas por la conexión de la casa, y eso lo decide quien
  /// usa el equipo, no la instalación.
  Future<bool> leerRespaldoActivo() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kRespaldoActivo) ?? false;
  }

  Future<void> guardarRespaldoActivo(bool valor) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kRespaldoActivo, valor);
  }

  /// La carpeta del equipo que se respalda. Por defecto, Videos del usuario: ahí deja OBS
  /// sus grabaciones.
  Future<String> leerRespaldoCarpetaLocal() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getString(_kRespaldoCarpetaLocal);
    if (v != null && v.trim().isNotEmpty) return v.trim();
    final casa = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '';
    return casa.isEmpty ? '' : '$casa${Platform.pathSeparator}Videos';
  }

  Future<void> guardarRespaldoCarpetaLocal(String ruta) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kRespaldoCarpetaLocal, ruta.trim());
  }

  /// El id de la carpeta de Drive para los videos que **no** se transcriben.
  ///
  /// Vacío quiere decir la de por defecto, `Videos PC (respaldo)` en la raíz, que el
  /// respaldo crea la primera vez. Los que sí se transcriben van siempre a
  /// [carpetaDriveObs]: es la que vigila el worker de Granolazo.
  Future<String> leerRespaldoCarpetaDrive() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kRespaldoCarpetaDrive)?.trim() ?? '';
  }

  Future<void> guardarRespaldoCarpetaDrive(String id) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kRespaldoCarpetaDrive, id.trim());
  }

  /// ¿Mandar los videos respaldados a transcribir en Granolazo?
  ///
  /// Apagado por defecto: transcribir una grabación de pantalla que no es una reunión
  /// ocupa horas del worker y llena Granolazo de ruido. Se enciende a propósito.
  Future<bool> leerRespaldoTranscribir() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kRespaldoTranscribir) ?? false;
  }

  Future<void> guardarRespaldoTranscribir(bool valor) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kRespaldoTranscribir, valor);
  }

  /// La carpeta de configuración de `gws` con la sesión de Google a usar.
  ///
  /// Hace falta elegirla porque un mismo equipo puede tener varias cuentas en `gws`, y
  /// la que viene por defecto no siempre es la dueña de la carpeta de Drive.
  Future<String> leerRespaldoPerfilGws() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getString(_kRespaldoPerfilGws);
    if (v != null) return v.trim();
    return Platform.environment['GOOGLE_WORKSPACE_CLI_CONFIG_DIR'] ?? '';
  }

  Future<void> guardarRespaldoPerfilGws(String ruta) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kRespaldoPerfilGws, ruta.trim());
  }

  // ── transcripción en vivo (borrador mientras se graba) ─────────────────────────

  /// Una instancia de preferencias con lo último que haya en disco.
  ///
  /// El modo consola (`granolazo config --en-vivo si`) es otro proceso: sin recargar, una
  /// ventana ya abierta no vería el cambio hasta reiniciarse. Se recarga solo para estos
  /// ajustes, que son los que se cambian desde afuera mientras la app está abierta.
  Future<SharedPreferences> _prefsFrescas() async {
    final p = await SharedPreferences.getInstance();
    try {
      await p.reload();
    } catch (_) {
      // Sin archivo todavía: vale lo que haya en memoria.
    }
    return p;
  }

  /// ¿Mostrar el texto mientras se graba? Apagado por defecto: gasta CPU y la
  /// transcripción buena sale igual al terminar.
  Future<bool> leerEnVivo() async => (await _prefsFrescas()).getBool(_kEnVivo) ?? false;

  Future<void> guardarEnVivo(bool valor) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kEnVivo, valor);
  }

  /// Modelo del borrador: `tiny`, `base` o `small`. `base` aguanta tiempo real sin GPU.
  Future<String> leerEnVivoModelo() async =>
      (await _prefsFrescas()).getString(_kEnVivoModelo) ?? 'base';

  Future<void> guardarEnVivoModelo(String modelo) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kEnVivoModelo, modelo);
  }

  /// Segundos de audio por trozo. Más corto = texto más seguido pero más trabajo.
  Future<int> leerEnVivoTrozoSeg() async =>
      (await _prefsFrescas()).getInt(_kEnVivoTrozo) ?? 20;

  Future<void> guardarEnVivoTrozoSeg(int seg) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kEnVivoTrozo, seg);
  }

  /// Hilos de CPU que usa el borrador. Pocos, para no pelear con lo que se esté haciendo.
  Future<int> leerEnVivoHilos() async => (await _prefsFrescas()).getInt(_kEnVivoHilos) ?? 2;

  Future<void> guardarEnVivoHilos(int hilos) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kEnVivoHilos, hilos);
  }

  /// Puerto de `http://127.0.0.1:<puerto>/en-vivo`. 0 = no abrir el endpoint.
  Future<int> leerEnVivoPuerto() async =>
      (await _prefsFrescas()).getInt(_kEnVivoPuerto) ?? 47821;

  Future<void> guardarEnVivoPuerto(int puerto) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kEnVivoPuerto, puerto);
  }

  /// Carpeta de Drive vigilada por tu worker de transcripción: lo que llega ahí, se transcribe.
  /// Reemplaza el id por el de tu propia carpeta (es la parte final de su URL en Drive).
  static const carpetaDriveObs = 'REPLACE_WITH_YOUR_DRIVE_FOLDER_ID';

  static const carpetaDriveObsNombre = 'OBS-RECORDINGS-2026';

  /// La carpeta que se crea en la raíz de Drive para lo que no se transcribe.
  static const nombreCarpetaRespaldo = 'Videos PC (respaldo)';
}
