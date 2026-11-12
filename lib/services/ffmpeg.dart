import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';

/// Corre ffmpeg, venga de donde venga.
///
/// En escritorio es el `ffmpeg` del sistema, que en Windows ya hacía falta para transcribir
/// en el propio equipo. En Android **no hay** un `ffmpeg` en el PATH ni forma de poner uno:
/// no existe el concepto de binario suelto ejecutable por otra app. Ahí se usa el que viene
/// compilado dentro del APK.
///
/// Esa biblioteca ya estaba en la aplicación —la arrastra el transcriptor local para
/// convertir el audio antes de pasárselo al modelo—, así que mezclar en el teléfono no
/// agrega ni un byte al instalador. Se declara igual como dependencia directa: usar algo
/// que llegó de rebote es quedar a merced de que otro paquete lo saque.
///
/// La otra opción en Android era mezclar a mano con `MediaCodec`: decodificar los dos
/// audios a PCM, sumarlos y volver a codificar. Son varios cientos de líneas de Kotlin para
/// reproducir mal lo que `amix` ya hace bien, y dejaría a las dos plataformas mezclando con
/// código distinto —o sea, sonando distinto.
abstract final class Ffmpeg {
  /// ¿Se puede mezclar en esta plataforma?
  static bool get disponible =>
      Platform.isAndroid || Platform.isIOS || Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// Corre ffmpeg con [args]. Devuelve `true` si terminó bien.
  ///
  /// **No lanza.** Sin ffmpeg queda el micrófono solo, que es media grabación, y media
  /// grabación es mejor que ninguna.
  static Future<bool> correr(List<String> args) async {
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        final sesion = await FFmpegKit.executeWithArguments(args);
        return ReturnCode.isSuccess(await sesion.getReturnCode());
      } catch (_) {
        return false;
      }
    }
    try {
      final r = await Process.run('ffmpeg', args);
      return r.exitCode == 0;
    } catch (_) {
      // No está en el PATH.
      return false;
    }
  }
}
