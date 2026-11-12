/// Una reunión tal como vive en Granolazo, venga de donde venga.
///
/// Es distinto de `Grabacion`: aquella es lo que este dispositivo capturó y todavía está
/// manejando; esta es lo que ya está en el backend, ingestado por cualquier fuente —OBS,
/// el celular, las notas de Gemini de Meet, la propia app—. La app muestra las dos cosas
/// y por eso son dos tipos: confundirlas llevaría a creer que se puede reintentar algo
/// que este equipo nunca tuvo.
class ItemGranolazo {
  const ItemGranolazo({
    required this.id,
    required this.estado,
    this.titulo,
    this.alias,
    this.grupo,
    this.grabadaEn,
    this.descubiertaEn,
    this.transcritaEn,
    this.resumen,
    this.tags = const [],
    this.participantes = const [],
    this.duracionSegundos = 0,
    this.fuente,
    this.carpetaFuente,
    this.mensajeError,
    this.proveedorTranscripcion,
    this.progreso = 0,
    this.pausada = false,
    this.prioridad = 0,
    this.procesandoDesde,
    this.estadoOpenai,
    this.trozosHechos,
    this.trozosTotales,
    this.enlaceDrive,
  });

  final String id;

  /// `pending`, `transcribed` o `error`, tal como los escriben los workers.
  final String estado;

  final String? titulo;
  final String? alias;
  final String? grupo;
  final DateTime? grabadaEn;
  final DateTime? descubiertaEn;
  final DateTime? transcritaEn;
  final String? resumen;
  final List<String> tags;
  final List<Map<String, dynamic>> participantes;
  final int duracionSegundos;
  final String? fuente;
  final String? carpetaFuente;
  final String? mensajeError;
  final String? proveedorTranscripcion;

  /// 0 a 100 mientras un worker la está transcribiendo.
  final int progreso;
  final bool pausada;
  final int prioridad;

  /// Cuándo un worker la tomó. Si está, es que se está procesando ahora mismo.
  final DateTime? procesandoDesde;

  final String? estadoOpenai;
  final int? trozosHechos;
  final int? trozosTotales;
  final String? enlaceDrive;

  String get tituloVisible {
    final a = alias?.trim();
    if (a != null && a.isNotEmpty) return a;
    final t = titulo?.trim();
    if (t != null && t.isNotEmpty) return t;
    return id;
  }

  /// La fecha con la que se ordena y se muestra: la de grabación si se conoce, y si no
  /// la de descubrimiento. Es el mismo criterio que usa el panel web, para que las dos
  /// vistas no discrepen sobre cuándo fue una reunión.
  DateTime? get fecha => grabadaEn ?? descubiertaEn;

  bool get transcrita => estado == 'transcribed';
  bool get conError => estado == 'error';
  bool get enProceso => estado == 'pending' && procesandoDesde != null;
  bool get enCola => estado == 'pending' && procesandoDesde == null;

  String get duracionLegible {
    if (duracionSegundos <= 0) return '--:--';
    final h = duracionSegundos ~/ 3600;
    final m = (duracionSegundos % 3600) ~/ 60;
    final s = duracionSegundos % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  /// Nombres o correos de los participantes, para mostrar y para filtrar.
  List<String> get nombresParticipantes => [
        for (final p in participantes)
          (p['email'] ?? p['name'] ?? p['phone'] ?? '').toString().trim()
      ].where((s) => s.isNotEmpty).toList();

  static DateTime? _fecha(Object? v) =>
      v is String && v.isNotEmpty ? DateTime.tryParse(v)?.toLocal() : null;

  factory ItemGranolazo.fromJson(Map<String, dynamic> j) => ItemGranolazo(
        id: (j['id'] ?? '').toString(),
        estado: (j['status'] ?? 'pending').toString(),
        titulo: j['title'] as String?,
        alias: j['alias'] as String?,
        grupo: j['topic'] as String?,
        grabadaEn: _fecha(j['recorded_at']),
        descubiertaEn: _fecha(j['discovered_at']),
        transcritaEn: _fecha(j['transcribed_at']),
        resumen: j['summary'] as String?,
        tags: [
          for (final k in (j['keywords'] as List?) ?? const []) k.toString(),
        ],
        participantes: [
          for (final p in (j['participants'] as List?) ?? const [])
            if (p is Map<String, dynamic>) p,
        ],
        duracionSegundos: (j['duration_seconds'] as num?)?.toInt() ?? 0,
        fuente: j['source'] as String?,
        carpetaFuente: j['source_folder'] as String?,
        mensajeError: j['error_msg'] as String?,
        proveedorTranscripcion: j['transcription_provider'] as String?,
        progreso: (j['progress'] as num?)?.toInt() ?? 0,
        pausada: j['paused'] as bool? ?? false,
        prioridad: (j['queue_priority'] as num?)?.toInt() ?? 0,
        procesandoDesde: _fecha(j['proc_started_at']),
        estadoOpenai: j['openai_status'] as String?,
        trozosHechos: (j['openai_chunks_done'] as num?)?.toInt(),
        trozosTotales: (j['openai_chunks_total'] as num?)?.toInt(),
        enlaceDrive: j['drive_url'] as String?,
      );

  Map<String, dynamic> aMapa() => {
        'id': id,
        'titulo': tituloVisible,
        'estado': estado,
        'grupo': grupo,
        'fecha': fecha?.toUtc().toIso8601String(),
        'duracion_segundos': duracionSegundos,
        'fuente': fuente,
        'tags': tags,
        'participantes': nombresParticipantes,
        'transcrita': transcrita,
        'progreso': progreso,
        'proveedor': proveedorTranscripcion,
        'error': mensajeError,
      };
}
