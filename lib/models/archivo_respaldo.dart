/// En qué va un archivo del respaldo a Drive.
enum EstadoRespaldo {
  /// Está en el disco y todavía no llega a Drive.
  pendiente,

  /// Se está subiendo ahora.
  subiendo,

  /// Ya está en Drive, con el mismo tamaño que en el disco. Se puede liberar.
  respaldado,

  /// Estaba respaldado y se borró del disco para liberar espacio.
  liberado,

  /// La última vez que se intentó, falló. Se reintenta en la próxima pasada.
  error,
}

/// Un archivo de la carpeta vigilada y lo que pasó con él.
///
/// Es inmutable: cada cambio de estado arma una copia con [copiar]. El servicio guarda la
/// lista completa en un JSON, así que un reinicio no olvida qué ya subió ni obliga a
/// preguntarle a Drive por cada archivo de nuevo.
class ArchivoRespaldo {
  const ArchivoRespaldo({
    required this.ruta,
    required this.nombre,
    required this.tamano,
    required this.modificado,
    this.estado = EstadoRespaldo.pendiente,
    this.enviados = 0,
    this.driveId,
    this.carpetaDrive,
    this.respaldadoEn,
    this.liberadoEn,
    this.error,
    this.sesionSubida,
  });

  final String ruta;
  final String nombre;
  final int tamano;
  final DateTime modificado;
  final EstadoRespaldo estado;

  /// Bytes que ya aceptó Drive. Solo tiene sentido mientras se sube.
  final int enviados;
  final String? driveId;

  /// En qué carpeta de Drive quedó. Hace falta para saber qué mover a la carpeta que
  /// transcribe Granolazo cuando se enciende esa opción.
  final String? carpetaDrive;
  final DateTime? respaldadoEn;
  final DateTime? liberadoEn;
  final String? error;

  /// La dirección de la subida reanudable que quedó a medias.
  ///
  /// Drive la mantiene viva una semana: si la app se cerró en la mitad de un video de
  /// 600 MB, al volver sigue desde donde quedó en vez de empezar de cero.
  final String? sesionSubida;

  double get progreso => tamano == 0 ? 0 : enviados / tamano;

  ArchivoRespaldo copiar({
    int? tamano,
    DateTime? modificado,
    EstadoRespaldo? estado,
    int? enviados,
    String? driveId,
    String? carpetaDrive,
    DateTime? respaldadoEn,
    DateTime? liberadoEn,
    String? error,
    bool limpiarError = false,
    String? sesionSubida,
    bool limpiarSesion = false,
  }) =>
      ArchivoRespaldo(
        ruta: ruta,
        nombre: nombre,
        tamano: tamano ?? this.tamano,
        modificado: modificado ?? this.modificado,
        estado: estado ?? this.estado,
        enviados: enviados ?? this.enviados,
        driveId: driveId ?? this.driveId,
        carpetaDrive: carpetaDrive ?? this.carpetaDrive,
        respaldadoEn: respaldadoEn ?? this.respaldadoEn,
        liberadoEn: liberadoEn ?? this.liberadoEn,
        error: limpiarError ? null : (error ?? this.error),
        sesionSubida: limpiarSesion ? null : (sesionSubida ?? this.sesionSubida),
      );

  Map<String, dynamic> aJson() => {
        'ruta': ruta,
        'nombre': nombre,
        'tamano': tamano,
        'modificado': modificado.toIso8601String(),
        // Una subida que se cortó con la app cerrada vuelve como pendiente: nadie la está
        // subiendo, y la sesión guardada basta para retomarla.
        'estado': (estado == EstadoRespaldo.subiendo ? EstadoRespaldo.pendiente : estado)
            .name,
        'drive_id': driveId,
        'carpeta_drive': carpetaDrive,
        'respaldado_en': respaldadoEn?.toIso8601String(),
        'liberado_en': liberadoEn?.toIso8601String(),
        'error': error,
        'sesion_subida': sesionSubida,
      };

  factory ArchivoRespaldo.deJson(Map<String, dynamic> j) => ArchivoRespaldo(
        ruta: j['ruta'] as String,
        nombre: j['nombre'] as String,
        tamano: (j['tamano'] as num).toInt(),
        modificado: DateTime.parse(j['modificado'] as String),
        estado: EstadoRespaldo.values.firstWhere(
          (e) => e.name == j['estado'],
          orElse: () => EstadoRespaldo.pendiente,
        ),
        driveId: j['drive_id'] as String?,
        carpetaDrive: j['carpeta_drive'] as String?,
        respaldadoEn: _fecha(j['respaldado_en']),
        liberadoEn: _fecha(j['liberado_en']),
        error: j['error'] as String?,
        sesionSubida: j['sesion_subida'] as String?,
      );

  static DateTime? _fecha(Object? v) => v is String ? DateTime.tryParse(v) : null;
}

/// Tamaño legible: `633 MB`, `1,2 GB`.
String tamanoLegible(int bytes) {
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1).replaceAll('.', ',')} GB';
  if (bytes >= mb) return '${(bytes / mb).round()} MB';
  if (bytes >= kb) return '${(bytes / kb).round()} KB';
  return '$bytes B';
}
