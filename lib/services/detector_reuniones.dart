import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'puente_android.dart';

/// Una aplicación que está usando el micrófono ahora mismo.
@immutable
class AppEnLlamada {
  const AppEnLlamada({
    required this.ejecutable,
    required this.nombre,
    required this.desde,
  });

  /// Ruta del ejecutable, tal como la registra Windows.
  final String ejecutable;

  /// Nombre reconocible: "Discord", "el navegador (Meet, WhatsApp Web…)"…
  final String nombre;

  final DateTime desde;

  @override
  bool operator ==(Object other) =>
      other is AppEnLlamada && other.ejecutable == ejecutable;

  @override
  int get hashCode => ejecutable.hashCode;
}

/// Avisa cuándo parece que empezó una reunión.
///
/// **Cómo lo sabe.** Windows anota, por aplicación, cuándo empezó y cuándo terminó de usar
/// el micrófono —es lo mismo que mira para encender el indicador de la barra de tareas—.
/// Una entrada con comienzo y sin fin es una aplicación grabando en este momento.
///
/// Esa señal es la buena porque **no depende de conocer cada programa**: sirve igual para
/// Discord, para Meet o WhatsApp dentro del navegador, para Zoom o para Teams. Mirar
/// procesos abiertos no serviría: tener Discord abierto no es estar en una llamada.
///
/// **El detalle que arruina la versión ingenua**: si una aplicación muere de golpe, Windows
/// nunca anota el final y la entrada queda marcada como "en uso" para siempre. Comprobado
/// el 2026-09-19 con la propia app. Por eso cada candidata se cruza con los procesos vivos
/// antes de creerle.
///
/// Se lee con `reg query` y `tasklist` en vez de con FFI: son dos procesos cortos cada
/// varios segundos, y evita atarse a los enlaces de Win32, que cambian entre versiones.
///
/// **En Android la señal es otra, y es mejor.** Cuando una aplicación entra en una llamada
/// le pide al sistema el modo `MODE_IN_COMMUNICATION`, porque lo necesita para la
/// cancelación de eco y para enrutar el audio al auricular. Ese modo es global, se lee sin
/// permisos, y comparte la propiedad que hace útil a la señal de Windows: **no depende de
/// conocer cada programa**. Una aplicación que salga mañana va a entrar en modo llamada
/// igual, porque si no lo hace no le funciona el audio.
///
/// Ahí no hace falta el cruce con los procesos vivos: el modo lo suelta el sistema cuando
/// la aplicación muere, así que no quedan entradas colgadas como en el registro de Windows.
class DetectorReuniones extends ChangeNotifier {
  DetectorReuniones({
    Duration intervalo = const Duration(seconds: 8),
    Future<String> Function(String, List<String>)? correr,
    PuenteAndroid? puente,
  })  : _puente = puente ?? PuenteAndroid(),
        // El linter pediria `this._intervalo`, pero Dart no admite parametros con nombre
        // que empiecen con guion bajo.
        // ignore: prefer_initializing_formals
        _intervalo = intervalo,
        _correr = correr ?? _correrDeVerdad;

  final Duration _intervalo;
  final Future<String> Function(String, List<String>) _correr;
  final PuenteAndroid _puente;

  Timer? _reloj;
  List<AppEnLlamada> _enLlamada = const [];
  final _ignoradas = <String>{};
  bool _revisando = false;

  static const _clave =
      r'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager'
      r'\ConsentStore\microphone\NonPackaged';

  bool get soportado => Platform.isWindows || Platform.isAndroid;

  /// Las aplicaciones que están usando el micrófono, sin contar esta.
  List<AppEnLlamada> get enLlamada => _enLlamada;

  bool get hayReunion => _enLlamada.isNotEmpty;

  /// La que disparó la sugerencia, si hay alguna.
  AppEnLlamada? get principal => _enLlamada.isEmpty ? null : _enLlamada.first;

  /// Nombres reconocibles. Lo que no esté acá se muestra con el nombre del ejecutable:
  /// es preferible decir "OBS está usando el micrófono" que no decir nada.
  static const nombresConocidos = {
    'discord.exe': 'Discord',
    'teams.exe': 'Microsoft Teams',
    'ms-teams.exe': 'Microsoft Teams',
    'zoom.exe': 'Zoom',
    'slack.exe': 'Slack',
    'whatsapp.exe': 'WhatsApp',
    'telegram.exe': 'Telegram',
    'chrome.exe': 'el navegador (Meet, WhatsApp Web…)',
    'msedge.exe': 'el navegador (Meet, WhatsApp Web…)',
    'msedgewebview2.exe': 'una app con navegador dentro',
    'firefox.exe': 'el navegador (Meet, WhatsApp Web…)',
    'brave.exe': 'el navegador (Meet, WhatsApp Web…)',
    'obs64.exe': 'OBS',
    'skype.exe': 'Skype',
    'webexmta.exe': 'Webex',
  };

  void empezar() {
    if (!soportado || _reloj != null) return;
    unawaited(revisar());
    _reloj = Timer.periodic(_intervalo, (_) => unawaited(revisar()));
  }

  void parar() {
    _reloj?.cancel();
    _reloj = null;
  }

  /// Deja de sugerir por esta aplicación hasta que se reinicie la app.
  void ignorar(AppEnLlamada app) {
    _ignoradas.add(app.ejecutable.toLowerCase());
    _enLlamada =
        _enLlamada.where((a) => !_ignoradas.contains(a.ejecutable.toLowerCase())).toList();
    notifyListeners();
  }

  /// Mira una vez. Devuelve lo encontrado, por si alguien la llama a mano.
  Future<List<AppEnLlamada>> revisar() async {
    if (!soportado || _revisando) return _enLlamada;
    _revisando = true;
    try {
      if (Platform.isAndroid) {
        _publicar(await _deAndroid());
        return _enLlamada;
      }
      final candidatas = await _delRegistro();
      if (candidatas.isEmpty) {
        _publicar(const []);
        return _enLlamada;
      }
      final vivos = await _procesosVivos();
      final propio = Platform.resolvedExecutable.toLowerCase();
      final buenas = <AppEnLlamada>[];
      for (final c in candidatas) {
        final bajo = c.ejecutable.toLowerCase();
        if (bajo == propio) continue;
        final archivo = bajo.split(r'\').last;
        // El cruce que evita el falso positivo eterno.
        if (!vivos.contains(archivo)) continue;
        if (_ignoradas.contains(bajo)) continue;
        buenas.add(c);
      }
      buenas.sort((a, b) => b.desde.compareTo(a.desde));
      _publicar(buenas);
      return _enLlamada;
    } catch (_) {
      // Que falle la consulta no puede tumbar la app: simplemente no se sugiere nada.
      return _enLlamada;
    } finally {
      _revisando = false;
    }
  }

  void _publicar(List<AppEnLlamada> nuevas) {
    final antes = _enLlamada.map((a) => a.ejecutable).toSet();
    final ahora = nuevas.map((a) => a.ejecutable).toSet();
    _enLlamada = nuevas;
    if (antes.length != ahora.length || !antes.containsAll(ahora)) {
      notifyListeners();
    }
  }

  /// Lo que el sistema Android dice del modo de audio.
  ///
  /// Devuelve a lo sumo una: el modo es del teléfono entero, no por aplicación, así que no
  /// hay forma de saber si hay dos llamadas —ni tendría sentido, porque no las puede haber.
  /// El nombre viene solo si el usuario concedió el acceso al uso de aplicaciones; si no,
  /// dice "una llamada", que alcanza para preguntar si se graba.
  Future<List<AppEnLlamada>> _deAndroid() async {
    final r = await _puente.enLlamada();
    if (!r.activa) return const [];
    const clave = 'android:llamada';
    if (_ignoradas.contains(clave)) return const [];
    return [
      AppEnLlamada(
        ejecutable: clave,
        nombre: r.app ?? 'una llamada',
        // Se conserva el comienzo de la llamada que ya estaba: recalcularlo en cada
        // vuelta haría que el aviso dijera siempre "recién empezó".
        desde: _enLlamada.isEmpty ? DateTime.now() : _enLlamada.first.desde,
      ),
    ];
  }

  /// Las entradas del registro con comienzo y sin final.
  Future<List<AppEnLlamada>> _delRegistro() async {
    final salida = await _correr('reg', ['query', _clave, '/s']);
    final encontradas = <AppEnLlamada>[];

    String? ejecutable;
    int? inicio;
    int? fin;

    void cerrar() {
      if (ejecutable != null && inicio != null && inicio! > 0 && fin == 0) {
        final archivo = ejecutable!.toLowerCase().split(r'\').last;
        encontradas.add(AppEnLlamada(
          ejecutable: ejecutable!,
          nombre: nombresConocidos[archivo] ?? _nombreLegible(archivo),
          desde: _desdeFileTime(inicio!),
        ));
      }
      ejecutable = null;
      inicio = null;
      fin = null;
    }

    for (final linea in const LineSplitter().convert(salida)) {
      final t = linea.trim();
      if (t.isEmpty) continue;
      if (t.startsWith('HKEY_')) {
        cerrar();
        final corte = t.lastIndexOf(r'\');
        final ultimo = corte < 0 ? t : t.substring(corte + 1);
        // Solo las subclaves de aplicación: Windows guarda la ruta con '#' donde va la
        // barra, así que una sin '#' es la clave contenedora y no interesa.
        if (ultimo.contains('#')) ejecutable = ultimo.replaceAll('#', r'\');
        continue;
      }
      if (ejecutable == null) continue;
      final partes = t.split(RegExp(r'\s{2,}'));
      if (partes.length < 3) continue;
      final valor = _hex(partes[2]);
      if (partes[0] == 'LastUsedTimeStart') inicio = valor;
      if (partes[0] == 'LastUsedTimeStop') fin = valor;
    }
    cerrar();
    return encontradas;
  }

  Future<Set<String>> _procesosVivos() async {
    final salida = await _correr('tasklist', ['/fo', 'csv', '/nh']);
    final vivos = <String>{};
    for (final linea in const LineSplitter().convert(salida)) {
      final t = linea.trim();
      if (!t.startsWith('"')) continue;
      final fin = t.indexOf('"', 1);
      if (fin <= 1) continue;
      vivos.add(t.substring(1, fin).toLowerCase());
    }
    return vivos;
  }

  static int? _hex(String v) {
    final t = v.trim();
    if (t.startsWith('0x')) return int.tryParse(t.substring(2), radix: 16);
    return int.tryParse(t);
  }

  static String _nombreLegible(String archivo) {
    final sinExt =
        archivo.endsWith('.exe') ? archivo.substring(0, archivo.length - 4) : archivo;
    if (sinExt.isEmpty) return archivo;
    return sinExt[0].toUpperCase() + sinExt.substring(1);
  }

  /// FILETIME de Windows: intervalos de 100 ns desde 1601.
  static DateTime _desdeFileTime(int ft) {
    const diferencia = 11644473600000; // milisegundos entre 1601 y 1970
    return DateTime.fromMillisecondsSinceEpoch((ft ~/ 10000) - diferencia);
  }

  static Future<String> _correrDeVerdad(String programa, List<String> args) async {
    final r = await Process.run(programa, args, stdoutEncoding: systemEncoding);
    return r.stdout.toString();
  }

  @override
  void dispose() {
    parar();
    super.dispose();
  }
}
