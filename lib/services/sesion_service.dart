import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../config/granolazo_config.dart';

class ErrorSesion implements Exception {
  ErrorSesion(this.mensaje);
  final String mensaje;
  @override
  String toString() => mensaje;
}

/// Quién está usando la app.
@immutable
class Usuario {
  const Usuario({required this.id, required this.email});
  final String id;
  final String email;
}

/// Inicio de sesión contra el mismo Supabase Auth que usa el panel web.
///
/// El panel entra con correo y contraseña (`signInWithPassword`), sin enlaces mágicos ni
/// proveedores externos, así que acá se hace lo mismo llamando directo a los endpoints de
/// autenticación. No se suma la librería oficial: la app ya habla PostgREST a mano, esto
/// son tres llamadas, y evita arrastrar realtime, almacenamiento y funciones que no usa.
///
/// **Qué cambia al haber sesión.** Sin sesión la app manda la clave pública en el
/// `Authorization`, que es lo que hacía hasta ahora. Con sesión manda el token del
/// usuario: las escrituras quedan atribuidas a una persona y, el día que se activen
/// políticas por fila en la base, la app ya está del lado correcto sin tocar nada.
///
/// Los tokens viven en el almacén seguro del sistema, nunca en preferencias planas.
class SesionService extends ChangeNotifier {
  SesionService({http.Client? cliente, FlutterSecureStorage? seguro})
      : _cliente = cliente ?? http.Client(),
        _seguro = seguro ?? const FlutterSecureStorage();

  final http.Client _cliente;
  final FlutterSecureStorage _seguro;

  static const _kAcceso = 'sesion_acceso';
  static const _kRefresco = 'sesion_refresco';
  static const _kEmail = 'sesion_email';
  static const _kUsuarioId = 'sesion_usuario_id';
  static const _kVence = 'sesion_vence';

  Usuario? _usuario;
  String? _acceso;
  String? _refresco;
  DateTime? _vence;
  bool _cargada = false;

  Usuario? get usuario => _usuario;
  bool get haySesion => _usuario != null;

  String get _urlAuth => '${GranolazoConfig.supabaseUrl}/auth/v1';

  /// Lee del almacén seguro lo que haya quedado de una sesión anterior.
  Future<void> cargar() async {
    if (_cargada) return;
    _cargada = true;
    try {
      _acceso = await _seguro.read(key: _kAcceso);
      _refresco = await _seguro.read(key: _kRefresco);
      final email = await _seguro.read(key: _kEmail);
      final id = await _seguro.read(key: _kUsuarioId);
      final vence = await _seguro.read(key: _kVence);
      _vence = vence == null ? null : DateTime.tryParse(vence);
      if (_acceso != null && email != null && id != null) {
        _usuario = Usuario(id: id, email: email);
      }
    } catch (_) {
      // Un almacén ilegible no puede dejar la app inservible: se entra sin sesión.
    }
    notifyListeners();
  }

  /// Entra con correo y contraseña.
  Future<Usuario> entrar({required String email, required String clave}) async {
    if (!GranolazoConfig.isConfigured) {
      throw ErrorSesion('falta la clave pública del backend en esta compilación');
    }
    final http.Response r;
    try {
      r = await _cliente
          .post(
            Uri.parse('$_urlAuth/token?grant_type=password'),
            headers: {
              'apikey': GranolazoConfig.anonKey,
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'email': email.trim(), 'password': clave}),
          )
          .timeout(const Duration(seconds: 30));
    } on SocketException {
      throw ErrorSesion('sin conexión con Granolazo');
    }

    if (r.statusCode >= 400) {
      throw ErrorSesion(_mensajeDeError(r));
    }
    return _guardarDesde(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// Cierra sesión y borra los tokens del dispositivo.
  Future<void> salir() async {
    final token = _acceso;
    if (token != null) {
      try {
        await _cliente.post(
          Uri.parse('$_urlAuth/logout'),
          headers: {
            'apikey': GranolazoConfig.anonKey,
            'Authorization': 'Bearer $token',
          },
        ).timeout(const Duration(seconds: 10));
      } catch (_) {
        // Que el servidor no conteste no puede impedir cerrar sesión acá.
      }
    }
    _usuario = null;
    _acceso = null;
    _refresco = null;
    _vence = null;
    for (final k in [_kAcceso, _kRefresco, _kEmail, _kUsuarioId, _kVence]) {
      await _seguro.delete(key: k);
    }
    notifyListeners();
  }

  /// Token para las llamadas a la base, renovado si estaba por vencer.
  ///
  /// Devuelve `null` cuando no hay sesión: ahí el que llama usa la clave pública, que es
  /// como funcionaba la app antes de que existiera el login.
  Future<String?> tokenVigente() async {
    await cargar();
    if (_acceso == null) return null;
    final vence = _vence;
    // Un minuto de margen: renovar justo al filo deja peticiones a medio camino.
    if (vence != null && DateTime.now().isAfter(vence.subtract(const Duration(minutes: 1)))) {
      await _refrescar();
    }
    return _acceso;
  }

  Future<void> _refrescar() async {
    final refresco = _refresco;
    if (refresco == null) return;
    try {
      final r = await _cliente
          .post(
            Uri.parse('$_urlAuth/token?grant_type=refresh_token'),
            headers: {
              'apikey': GranolazoConfig.anonKey,
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'refresh_token': refresco}),
          )
          .timeout(const Duration(seconds: 30));
      if (r.statusCode >= 400) {
        // El refresco caducó: la sesión se terminó de verdad, hay que volver a entrar.
        await salir();
        return;
      }
      await _guardarDesde(jsonDecode(r.body) as Map<String, dynamic>);
    } catch (_) {
      // Sin red se sigue con el token viejo; si ya no sirve, la llamada dará 401.
    }
  }

  Future<Usuario> _guardarDesde(Map<String, dynamic> j) async {
    final acceso = j['access_token'] as String?;
    if (acceso == null) throw ErrorSesion('el servidor no devolvió un token');
    final datosUsuario = j['user'] as Map<String, dynamic>?;
    final usuario = Usuario(
      id: (datosUsuario?['id'] as String?) ?? '',
      email: (datosUsuario?['email'] as String?) ?? '',
    );
    final segundos = (j['expires_in'] as num?)?.toInt() ?? 3600;

    _acceso = acceso;
    _refresco = j['refresh_token'] as String?;
    _vence = DateTime.now().add(Duration(seconds: segundos));
    _usuario = usuario;
    _cargada = true;

    await _seguro.write(key: _kAcceso, value: acceso);
    if (_refresco != null) await _seguro.write(key: _kRefresco, value: _refresco);
    await _seguro.write(key: _kEmail, value: usuario.email);
    await _seguro.write(key: _kUsuarioId, value: usuario.id);
    await _seguro.write(key: _kVence, value: _vence!.toIso8601String());

    notifyListeners();
    return usuario;
  }

  String _mensajeDeError(http.Response r) {
    try {
      final j = jsonDecode(r.body);
      if (j is Map) {
        final m = j['error_description'] ?? j['msg'] ?? j['message'] ?? j['error'];
        if (m is String && m.isNotEmpty) {
          // El mensaje viene en inglés; el más frecuente se traduce para no mostrar
          // "Invalid login credentials" a alguien que escribió mal la contraseña.
          if (m.toLowerCase().contains('invalid login')) {
            return 'correo o contraseña incorrectos';
          }
          return m;
        }
      }
    } catch (_) {
      // Cuerpo no interpretable: se cae al mensaje genérico.
    }
    return 'no pude iniciar sesión (${r.statusCode})';
  }

  @override
  void dispose() {
    _cliente.close();
    super.dispose();
  }
}
