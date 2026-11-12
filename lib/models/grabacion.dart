import 'dart:convert';

import 'segmento.dart';

/// Estado de una grabación dentro de la app, desde que se captura hasta que queda
/// registrada en Granolazo.
enum EstadoGrabacion {
  grabando,

  /// Grabada y guardada, pero nadie la va a tocar hasta que se pida.
  ///
  /// Es el estado en el que cae una grabación cuando la transcripción automática está
  /// apagada, que es el modo por defecto: permite grabar sin clave, sin conexión y sin
  /// gastar, y decidir después cuándo y con qué motor se transcribe.
  enEspera,

  /// Encolada para transcribir. A diferencia de [enEspera], al abrir la app se retoma sola.
  pendiente,

  transcribiendo,
  subiendo,
  lista,
  error,
}

extension EstadoGrabacionTexto on EstadoGrabacion {
  String get etiqueta => switch (this) {
        EstadoGrabacion.grabando => 'Grabando',
        EstadoGrabacion.enEspera => 'En espera',
        EstadoGrabacion.pendiente => 'Pendiente',
        EstadoGrabacion.transcribiendo => 'Transcribiendo',
        EstadoGrabacion.subiendo => 'Subiendo',
        EstadoGrabacion.lista => 'Lista',
        EstadoGrabacion.error => 'Error',
      };

  bool get enProceso =>
      this == EstadoGrabacion.transcribiendo || this == EstadoGrabacion.subiendo;

  /// Todavía no llegó a Granolazo: hay trabajo por hacer con ella.
  bool get faltaProcesar =>
      this == EstadoGrabacion.enEspera ||
      this == EstadoGrabacion.pendiente ||
      this == EstadoGrabacion.error;
}

/// Una grabación capturada o importada en este dispositivo.
///
/// Inmutable: cada cambio de estado produce una copia nueva con [copyWith]. Se persiste
/// como JSON para que la cola sobreviva a cerrar la app.
class Grabacion {
  const Grabacion({
    required this.id,
    required this.rutaArchivo,
    required this.grabadaEn,
    required this.estado,
    this.titulo,
    this.duracionSegundos = 0,
    this.tamanoBytes = 0,
    this.transcripcion,
    this.mensajeError,
    this.itemIdRemoto,
    this.progreso = 0,
    this.importada = false,
    this.motor,
    this.muda = false,
    this.segmentos = const [],
  });

  final String id;
  final String rutaArchivo;
  final DateTime grabadaEn;
  final EstadoGrabacion estado;
  final String? titulo;
  final int duracionSegundos;
  final int tamanoBytes;
  final String? transcripcion;
  final String? mensajeError;

  /// `items.id` en Granolazo una vez subida.
  final String? itemIdRemoto;

  bool get hayTiempos => segmentos.isNotEmpty;

  /// El texto con la hora delante de cada tramo, o el texto corrido si no hay tiempos.
  String get textoConMarcas => segmentos.isEmpty
      ? (transcripcion ?? '')
      : Segmento.textoConMarcas(segmentos, comienzo: grabadaEn);

  /// 0 a 100, para la barra de transcripción por bloques.
  final int progreso;

  /// true si el audio venía del dispositivo en vez de grabarse en la app.
  final bool importada;

  /// Con qué se transcribió: `local` (el procesador de este equipo) o `api`.
  final String? motor;

  /// La transcripción partida en tramos con su momento dentro de la grabación.
  ///
  /// Puede venir vacía: no todos los caminos dan tiempos, y una grabación transcrita
  /// antes de que esto existiera tampoco los tiene. La app tiene que funcionar igual.
  final List<Segmento> segmentos;

  /// El micrófono no entregó sonido mientras se grababa.
  ///
  /// Se guarda para poder avisarlo después: el archivo existe y pesa, así que a simple
  /// vista no se distingue de una grabación buena.
  final bool muda;

  String get tituloVisible {
    if (titulo != null && titulo!.trim().isNotEmpty) return titulo!.trim();
    final f = grabadaEn.toLocal();
    final dd = f.day.toString().padLeft(2, '0');
    final mm = f.month.toString().padLeft(2, '0');
    final hh = f.hour.toString().padLeft(2, '0');
    final mi = f.minute.toString().padLeft(2, '0');
    return 'Grabación ${f.year}-$mm-$dd $hh:$mi';
  }

  String get duracionLegible {
    if (duracionSegundos <= 0) return '--:--';
    final h = duracionSegundos ~/ 3600;
    final m = (duracionSegundos % 3600) ~/ 60;
    final s = duracionSegundos % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  Grabacion copyWith({
    String? rutaArchivo,
    EstadoGrabacion? estado,
    String? titulo,
    int? duracionSegundos,
    int? tamanoBytes,
    String? transcripcion,
    String? mensajeError,
    String? itemIdRemoto,
    int? progreso,
    String? motor,
    bool? muda,
    List<Segmento>? segmentos,
    bool limpiarError = false,
  }) {
    return Grabacion(
      id: id,
      rutaArchivo: rutaArchivo ?? this.rutaArchivo,
      grabadaEn: grabadaEn,
      estado: estado ?? this.estado,
      titulo: titulo ?? this.titulo,
      duracionSegundos: duracionSegundos ?? this.duracionSegundos,
      tamanoBytes: tamanoBytes ?? this.tamanoBytes,
      transcripcion: transcripcion ?? this.transcripcion,
      mensajeError: limpiarError ? null : (mensajeError ?? this.mensajeError),
      itemIdRemoto: itemIdRemoto ?? this.itemIdRemoto,
      progreso: progreso ?? this.progreso,
      importada: importada,
      motor: motor ?? this.motor,
      muda: muda ?? this.muda,
      segmentos: segmentos ?? this.segmentos,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'rutaArchivo': rutaArchivo,
        'grabadaEn': grabadaEn.toUtc().toIso8601String(),
        'estado': estado.name,
        'titulo': titulo,
        'duracionSegundos': duracionSegundos,
        'tamanoBytes': tamanoBytes,
        'transcripcion': transcripcion,
        'mensajeError': mensajeError,
        'itemIdRemoto': itemIdRemoto,
        'progreso': progreso,
        'importada': importada,
        'motor': motor,
        'muda': muda,
        'segmentos': [for (final s in segmentos) s.toJson()],
      };

  factory Grabacion.fromJson(Map<String, dynamic> j) => Grabacion(
        id: j['id'] as String,
        rutaArchivo: j['rutaArchivo'] as String,
        grabadaEn: DateTime.parse(j['grabadaEn'] as String),
        // Una grabación que quedó a medio procesar cuando se cerró la app vuelve a
        // pendiente: no tiene sentido restaurarla como "transcribiendo". En cambio
        // `enEspera` sí se conserva — es una decisión del usuario, no un estado a medias.
        estado: switch (j['estado'] as String?) {
          'lista' => EstadoGrabacion.lista,
          'error' => EstadoGrabacion.error,
          'enEspera' => EstadoGrabacion.enEspera,
          _ => EstadoGrabacion.pendiente,
        },
        titulo: j['titulo'] as String?,
        duracionSegundos: (j['duracionSegundos'] as num?)?.toInt() ?? 0,
        tamanoBytes: (j['tamanoBytes'] as num?)?.toInt() ?? 0,
        transcripcion: j['transcripcion'] as String?,
        mensajeError: j['mensajeError'] as String?,
        itemIdRemoto: j['itemIdRemoto'] as String?,
        progreso: (j['progreso'] as num?)?.toInt() ?? 0,
        importada: j['importada'] as bool? ?? false,
        motor: j['motor'] as String?,
        muda: j['muda'] as bool? ?? false,
        segmentos: [
          for (final s in (j['segmentos'] as List?) ?? const [])
            if (s is Map<String, dynamic>) Segmento.fromJson(s),
        ],
      );

  static List<Grabacion> listaDesdeJson(String raw) {
    final data = jsonDecode(raw);
    if (data is! List) return const [];
    return data
        .whereType<Map<String, dynamic>>()
        .map(Grabacion.fromJson)
        .toList(growable: false);
  }

  static String listaAJson(List<Grabacion> items) =>
      jsonEncode(items.map((e) => e.toJson()).toList());
}
