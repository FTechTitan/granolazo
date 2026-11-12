import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Escuchar una grabación desde la app.
///
/// Suena obvio que tiene que existir, y sin embargo faltaba: la app grababa, transcribía y
/// subía, pero para oír lo grabado había que ir a buscar el archivo al disco. Lo hizo
/// notar, después de que una grabación saliera muda y no tuviera
/// forma de comprobarlo.
///
/// Reproduce de a una: arrancar otra detiene la anterior. Dos audios sonando encima no le
/// sirven a nadie.
class ReproductorService extends ChangeNotifier {
  ReproductorService({AudioPlayer? reproductor})
      : _reproductor = reproductor ?? AudioPlayer() {
    _subEstado = _reproductor.onPlayerStateChanged.listen((e) {
      _sonando = e == PlayerState.playing;
      if (e == PlayerState.completed) {
        _idActual = null;
        _posicion = Duration.zero;
      }
      notifyListeners();
    });
    _subPosicion = _reproductor.onPositionChanged.listen((p) {
      _posicion = p;
      notifyListeners();
    });
    _subDuracion = _reproductor.onDurationChanged.listen((d) {
      _duracion = d;
      notifyListeners();
    });
  }

  final AudioPlayer _reproductor;
  StreamSubscription<PlayerState>? _subEstado;
  StreamSubscription<Duration>? _subPosicion;
  StreamSubscription<Duration>? _subDuracion;

  String? _idActual;
  bool _sonando = false;
  Duration _posicion = Duration.zero;
  Duration _duracion = Duration.zero;

  /// Qué grabación está cargada, si hay alguna.
  String? get idActual => _idActual;
  bool get sonando => _sonando;
  Duration get posicion => _posicion;
  Duration get duracion => _duracion;

  bool estaSonando(String id) => _idActual == id && _sonando;
  bool estaCargada(String id) => _idActual == id;

  /// Alterna entre reproducir y pausar la grabación [id].
  ///
  /// Devuelve un mensaje de error si no se pudo, o `null` si salió bien.
  Future<String?> alternar(String id, String rutaArchivo) async {
    if (!await File(rutaArchivo).exists()) {
      return 'el archivo de audio ya no está en el dispositivo';
    }
    try {
      if (_idActual == id) {
        if (_sonando) {
          await _reproductor.pause();
        } else {
          await _reproductor.resume();
        }
        return null;
      }
      await _reproductor.stop();
      _idActual = id;
      _posicion = Duration.zero;
      _duracion = Duration.zero;
      notifyListeners();
      await _reproductor.play(DeviceFileSource(rutaArchivo));
      return null;
    } catch (e) {
      _idActual = null;
      notifyListeners();
      return 'no pude reproducir: $e';
    }
  }

  Future<void> detener() async {
    await _reproductor.stop();
    _idActual = null;
    _sonando = false;
    _posicion = Duration.zero;
    notifyListeners();
  }

  Future<void> irA(Duration donde) => _reproductor.seek(donde);

  @override
  void dispose() {
    _subEstado?.cancel();
    _subPosicion?.cancel();
    _subDuracion?.cancel();
    _reproductor.dispose();
    super.dispose();
  }
}
