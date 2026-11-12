/// Un tramo de la transcripción con su momento dentro de la grabación.
///
/// Sirve para dos cosas distintas y las dos importan: saber **cuándo** se dijo algo, y
/// poder tocar una frase y saltar a ese punto del audio para escucharla.
class Segmento {
  const Segmento({required this.desde, required this.hasta, required this.texto});

  /// Desde el comienzo de la grabación.
  final Duration desde;
  final Duration hasta;
  final String texto;

  /// `MM:SS`, o `H:MM:SS` cuando pasa de la hora.
  String get marca => _reloj(desde);

  /// La hora del día en que se dijo, sabiendo cuándo empezó la grabación.
  ///
  /// Es lo que se busca cuando uno pregunta "a qué hora dijo eso": en una reunión, la
  /// hora del reloj se cruza con el calendario y con lo que uno recuerda; el minuto
  /// dentro del archivo, no.
  DateTime horaDelDia(DateTime comienzo) => comienzo.add(desde);

  String horaDelDiaLegible(DateTime comienzo) {
    final h = horaDelDia(comienzo).toLocal();
    return '${h.hour.toString().padLeft(2, '0')}:'
        '${h.minute.toString().padLeft(2, '0')}:'
        '${h.second.toString().padLeft(2, '0')}';
  }

  static String _reloj(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  Map<String, dynamic> toJson() => {
        'desde': desde.inMilliseconds,
        'hasta': hasta.inMilliseconds,
        'texto': texto,
      };

  factory Segmento.fromJson(Map<String, dynamic> j) => Segmento(
        desde: Duration(milliseconds: (j['desde'] as num?)?.toInt() ?? 0),
        hasta: Duration(milliseconds: (j['hasta'] as num?)?.toInt() ?? 0),
        texto: (j['texto'] ?? '').toString(),
      );

  /// El texto corrido, sin marcas: lo que se usaba antes de que hubiera segmentos.
  static String textoPlano(List<Segmento> segmentos) =>
      segmentos.map((s) => s.texto.trim()).where((t) => t.isNotEmpty).join(' ');

  /// El texto con la marca de tiempo delante de cada tramo.
  ///
  /// Es lo que se sube a Granolazo: el panel web y los consumidores leen `raw_transcript`
  /// como texto plano, así que las marcas viajan dentro del propio texto en vez de en una
  /// columna nueva que habría que agregar al esquema y enseñarle a todo lo que ya existe.
  ///
  /// Con [comienzo] las marcas son la hora del día; sin él, el tiempo desde el principio.
  static String textoConMarcas(List<Segmento> segmentos, {DateTime? comienzo}) {
    final lineas = <String>[];
    for (final s in segmentos) {
      final t = s.texto.trim();
      if (t.isEmpty) continue;
      final marca = comienzo == null ? s.marca : s.horaDelDiaLegible(comienzo);
      lineas.add('[$marca] $t');
    }
    return lineas.join('\n');
  }
}

/// Lo que devuelve un transcriptor: el texto y, si el motor los da, sus tiempos.
class Transcripcion {
  const Transcripcion({required this.texto, this.segmentos = const []});

  final String texto;
  final List<Segmento> segmentos;

  bool get hayTiempos => segmentos.isNotEmpty;

  /// Construye a partir de los segmentos, para no repetir el texto en dos lados.
  factory Transcripcion.deSegmentos(List<Segmento> segmentos) =>
      Transcripcion(texto: Segmento.textoPlano(segmentos), segmentos: segmentos);
}
