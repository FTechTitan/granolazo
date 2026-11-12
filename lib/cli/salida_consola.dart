import 'dart:io';

import 'package:flutter/services.dart';

/// Por dónde habla el modo consola y cómo termina el proceso.
///
/// Suena a rodeo tener una abstracción para "escribir una línea", pero en Windows no
/// queda otra: el ejecutable se enlaza como aplicación de ventanas y el `stdout` que ve
/// Dart no está conectado al descriptor que entregó la terminal. Medido el 2026-09-18 —
/// con la salida redirigida a un archivo, el archivo quedaba vacío, y `exit()` ni
/// siquiera terminaba el proceso porque el bucle de mensajes de Win32 sigue corriendo.
///
/// En el resto de las plataformas `stdout` y `exit()` funcionan como corresponde, así que
/// ahí se usan directo.
abstract class SalidaConsola {
  /// La implementación que sirve en esta plataforma.
  factory SalidaConsola.delSistema() =>
      Platform.isWindows ? _SalidaPorCanal() : _SalidaEstandar();

  void escribir(String linea);
  void escribirError(String linea);

  /// Termina el proceso con [codigo]. No retorna.
  Future<Never> terminar(int codigo);
}

/// Junta todo en un texto en vez de escribirlo. Es la salida del modo consola de Android.
///
/// Ahí no hay una terminal esperando: el comando llega por `adb`, se ejecuta dentro de un
/// motor de Flutter sin pantalla, y la respuesta vuelve por el mismo canal para salir por
/// logcat. [terminar] **no mata el proceso** a propósito: matarlo se llevaría puesta la app
/// entera si el usuario la tenía abierta.
class SalidaEnMemoria implements SalidaConsola {
  final _texto = StringBuffer();

  /// Lo escrito hasta ahora, salida normal y errores en el orden en que se produjeron.
  String get texto => _texto.toString();

  int codigo = 0;

  @override
  void escribir(String linea) => _texto.writeln(linea);

  @override
  void escribirError(String linea) => _texto.writeln(linea);

  @override
  Future<Never> terminar(int codigo) {
    this.codigo = codigo;
    // Nunca retorna, igual que las otras, pero sin tumbar el proceso: quien la usa lee
    // el código del retorno de `ejecutar`, no de acá.
    return Future.error(StateError('terminar() no aplica en el modo consola de Android'));
  }
}

class _SalidaEstandar implements SalidaConsola {
  @override
  void escribir(String linea) => stdout.writeln(linea);

  @override
  void escribirError(String linea) => stderr.writeln(linea);

  @override
  Future<Never> terminar(int codigo) async {
    await stdout.flush();
    exit(codigo);
  }
}

class _SalidaPorCanal implements SalidaConsola {
  static const _canal = MethodChannel('granolazo/consola');

  // El canal es asíncrono pero la consola tiene que salir en orden. Se encadenan las
  // escrituras en una sola fila para que no se pisen entre sí.
  Future<void> _fila = Future<void>.value();

  void _encolar(String metodo, String texto) {
    _fila = _fila.then<void>((_) async {
      try {
        await _canal.invokeMethod<int>(metodo, texto);
      } catch (_) {
        // Si el canal no está —por ejemplo en los tests, sin el arranque nativo— al
        // menos que el texto no se pierda.
        stdout.writeln(texto.trimRight());
      }
    });
  }

  @override
  void escribir(String linea) => _encolar('escribir', '$linea\n');

  @override
  void escribirError(String linea) => _encolar('escribirError', '$linea\n');

  @override
  Future<Never> terminar(int codigo) async {
    await _fila;
    try {
      await _canal.invokeMethod<void>('terminar', codigo);
    } catch (_) {
      // Sin canal no queda otra que la salida normal, aunque en Windows no siempre
      // alcance para matar el proceso.
    }
    exit(codigo);
  }
}
