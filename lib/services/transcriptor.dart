import 'dart:io';

import '../models/segmento.dart';

/// Error de transcripción con mensaje legible para la interfaz y para la consola.
class ErrorTranscripcion implements Exception {
  ErrorTranscripcion(this.mensaje, {this.codigo});
  final String mensaje;
  final int? codigo;
  @override
  String toString() => mensaje;
}

/// Convierte audio en texto.
///
/// Hay dos implementaciones y la diferencia importa: una manda el audio a un servicio en
/// línea, que cobra por minuto y exige una clave guardada en el dispositivo; la otra usa
/// el procesador de este mismo equipo, que sale gratis y funciona sin conexión, pero tarda
/// más. Quién decide cuál se usa es el dueño del dispositivo, no la app.
///
/// La interfaz existe para que el controlador no sepa cuál tiene enfrente: lo que cambia
/// entre una y otra son el costo y el tiempo, no el resultado.
abstract class Transcriptor {
  /// `local` o `api`. Queda guardado en la grabación para saber con qué se hizo cada una.
  String get nombre;

  /// Transcribe el archivo completo. [onProgreso] recibe de 0 a 100.
  ///
  /// Devuelve el texto y, cuando el motor los da, los tiempos de cada tramo. No todos
  /// los caminos los traen, así que quien consume tiene que aguantar que falten.
  Future<Transcripcion> transcribir(
    File audio, {
    required String idioma,
    void Function(int porcentaje)? onProgreso,
  });

  void dispose();
}
