import 'dart:io';

import 'package:flutter/services.dart';

/// Captura el audio que sale por los parlantes de este equipo.
///
/// **Por qué existe.** Grabando solo el micrófono, de una llamada queda una sola voz: lo
/// que dice el otro sale por los parlantes. Sin esto la app no sirve para transcribir
/// reuniones, que es para lo que existe. Se notó probando
/// con un video de YouTube que la app no tomaba.
///
/// Del lado nativo es WASAPI en modo loopback, lo mismo que usan OBS y las apps de
/// videollamada. La alternativa de usuario —habilitar "Mezcla estéreo" en el panel de
/// sonido— se descartó: depende del driver, en este equipo está deshabilitada, y obliga a
/// configurar algo a mano antes de que la app funcione.
///
/// **En Android es lo mismo pero con un límite que pone el sistema.** Existe la captura de
/// reproducción desde Android 10, pero solo entrega los usos `MEDIA`, `GAME` y `UNKNOWN`.
/// El audio de una llamada —`USAGE_VOICE_COMMUNICATION`— está excluido a propósito por
/// Android y no hay permiso que lo habilite: un teléfono que deja grabar la voz del otro
/// sin que se entere es exactamente lo que Google decidió impedir.
///
/// O sea, en el teléfono esto sirve para grabar un video, un podcast o una reunión que se
/// está reproduciendo; para una llamada en vivo la voz del otro tiene que entrar por el
/// micrófono, con el altavoz puesto. Es una diferencia real con Windows, y la interfaz la
/// dice en vez de ofrecer algo que el sistema va a negar en silencio.
///
/// Además Android obliga a pedir permiso **en cada grabación**: el consentimiento de
/// captura no se puede guardar. Es molesto y es a propósito.
class AudioSistemaService {
  AudioSistemaService({MethodChannel? canal})
      : _canal = canal ?? const MethodChannel('granolazo/audio_sistema');

  final MethodChannel _canal;

  /// Piso de la escala en dBFS, igual que el del medidor del micrófono.
  static const double silencio = -160.0;

  /// En Android hace falta la versión 10; por debajo no existe la captura de
  /// reproducción. El lado nativo lo confirma con [refrescarSoporte].
  bool get soportado => Platform.isWindows || (Platform.isAndroid && _soporteAndroid);

  bool _soporteAndroid = true;

  /// ¿El audio de una llamada entra por esta vía? En Android no, nunca: lo bloquea el
  /// sistema. Sirve para que la interfaz lo diga en vez de prometer de más.
  bool get tomaLlamadas => Platform.isWindows;

  /// Le pregunta al sistema si puede capturar. Barato y sin efectos.
  Future<bool> refrescarSoporte() async {
    if (!Platform.isAndroid) return soportado;
    try {
      _soporteAndroid = await _canal.invokeMethod<bool>('soportado') ?? false;
    } catch (_) {
      _soporteAndroid = false;
    }
    return _soporteAndroid;
  }

  String? _rutaActual;

  /// ¿Se está capturando ahora?
  String? get rutaActual => _rutaActual;

  /// Arranca la captura hacia [ruta].
  ///
  /// Devuelve `null` si salió bien, o el motivo si no se pudo. **No lanza**: que no se
  /// pueda capturar la salida no debe impedir grabar el micrófono, que es lo mínimo.
  Future<String?> iniciar(String ruta) async {
    if (!soportado) {
      return Platform.isAndroid
          ? 'hace falta Android 10 o superior'
          : 'todavía solo en Windows y Android';
    }
    try {
      await _canal.invokeMethod<bool>('iniciar', ruta);
      _rutaActual = ruta;
      return null;
    } on PlatformException catch (e) {
      _rutaActual = null;
      return e.message ?? 'no pude capturar el audio del equipo';
    } catch (e) {
      _rutaActual = null;
      return 'no pude capturar el audio del equipo: $e';
    }
  }

  /// Detiene la captura y devuelve el archivo, si quedó algo utilizable.
  Future<File?> detener() async {
    final ruta = _rutaActual;
    _rutaActual = null;
    if (!soportado || ruta == null) return null;
    try {
      await _canal.invokeMethod<void>('detener');
    } catch (_) {
      // Si el lado nativo ya se había caído, el archivo puede servir igual.
    }
    final f = File(ruta);
    if (!await f.exists()) return null;
    // 44 bytes es la cabecera WAV sola: no hay audio.
    if (await f.length() <= 44) {
      await f.delete();
      return null;
    }
    return f;
  }

  /// Lo llama el puente cuando la captura falla **después** de haber dicho que sí.
  ///
  /// En Android la respuesta llega en dos tiempos: primero el usuario acepta el diálogo y
  /// recién después el servicio intenta tomar la proyección. Esperar a lo segundo para
  /// contestar retrasaría el micrófono, que es lo único que no se puede perder.
  void anotarFalla(String? motivo) {
    if (motivo == null) return;
    _rutaActual = null;
  }

  /// Nivel de la salida en dBFS, para el medidor.
  Future<double> nivel() async {
    if (!soportado) return silencio;
    try {
      return await _canal.invokeMethod<double>('nivel') ?? silencio;
    } catch (_) {
      return silencio;
    }
  }
}
