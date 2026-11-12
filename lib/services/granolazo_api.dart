import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/granolazo_config.dart';
import '../models/grabacion.dart';
import '../models/item_granolazo.dart';
import 'sesion_service.dart';

class ErrorGranolazo implements Exception {
  ErrorGranolazo(this.mensaje, {this.codigo});
  final String mensaje;
  final int? codigo;
  @override
  String toString() => mensaje;
}

/// Cliente del backend de Granolazo.
///
/// Escribe en la misma tabla `items` que alimentan los workers. No hay endpoint especial
/// para la app: por eso el trigger del outbox emite el evento `meeting.transcribed` sin
/// que la app tenga que saber nada de él.
class GranolazoApi {
  GranolazoApi({http.Client? cliente, SesionService? sesion})
      : _cliente = cliente ?? http.Client(),
        // El linter pediría `this._sesion`, pero Dart no admite parámetros con nombre
        // que empiecen con guion bajo, así que la asignación va a mano.
        // ignore: prefer_initializing_formals
        _sesion = sesion;


  final http.Client _cliente;

  /// Si hay sesión iniciada, las peticiones van con el token del usuario en vez de con
  /// la clave pública. Así las escrituras quedan atribuidas a una persona, y el día que
  /// la base tenga políticas por fila la app ya está del lado correcto.
  final SesionService? _sesion;

  /// Columnas del listado. `raw_transcript` NO va acá: pesa y se pide aparte cuando
  /// alguien abre una reunión. El panel web comete ese error y se trae la tabla entera.
  static const _selectLista = 'id,title,alias,topic,status,error_msg,recorded_at,'
      'discovered_at,transcribed_at,summary,keywords,duration_seconds,source,'
      'source_folder,participants,drive_url,transcription_provider,progress';

  /// Columnas que hacen falta para entender la cola del pipeline.
  static const _selectCola = 'id,title,alias,status,error_msg,recorded_at,'
      'duration_seconds,progress,paused,queue_priority,proc_started_at,proc_heartbeat,'
      'openai_status,openai_chunks_done,openai_chunks_total,source';

  /// `source` con el que quedan las grabaciones de la app, por plataforma.
  static String fuenteDe(String plataforma) => 'app-$plataforma';

  Uri _uri(String recurso, [Map<String, String>? query]) => Uri.parse(
        '${GranolazoConfig.supabaseUrl}${GranolazoConfig.restPath}/$recurso',
      ).replace(queryParameters: query);

  /// Sube una grabación ya transcrita como un item de Granolazo.
  ///
  /// Idempotente: el id se deriva del identificador local, así que reintentar no duplica.
  Future<String> subirGrabacion(
    Grabacion g, {
    required String plataforma,
    required String dispositivo,
  }) async {
    if (!GranolazoConfig.isConfigured) {
      throw ErrorGranolazo(
        'falta la clave pública del backend: compilá con --dart-define-from-file',
      );
    }
    final itemId = '${fuenteDe(plataforma)}-${g.id}';
    final cuerpo = [
      {
        'id': itemId,
        'title': g.tituloVisible,
        'alias': g.tituloVisible,
        'status': 'transcribed',
        'source': fuenteDe(plataforma),
        'source_folder': 'app/$dispositivo',
        'recorded_at': g.grabadaEn.toUtc().toIso8601String(),
        'file_created_at': g.grabadaEn.toUtc().toIso8601String(),
        'discovered_at': DateTime.now().toUtc().toIso8601String(),
        'transcribed_at': DateTime.now().toUtc().toIso8601String(),
        // Con las marcas de tiempo adentro del propio texto: el panel web y los
        // consumidores leen `raw_transcript` como texto plano, así que meterlas ahí
        // evita agregar una columna al esquema y enseñarle a todo lo que ya existe.
        'raw_transcript': g.textoConMarcas,
        'duration_seconds': g.duracionSegundos,
        'size_bytes': g.tamanoBytes,
        'transcription_provider': 'app-openai',
        'keywords': ['app', plataforma, if (g.importada) 'importada' else 'grabada'],
      }
    ];

    final r = await _enviar(
      'POST',
      _uri('items'),
      cuerpo: jsonEncode(cuerpo),
      extra: {'Prefer': 'resolution=merge-duplicates,return=minimal'},
    );
    if (r.statusCode >= 400) {
      throw ErrorGranolazo(
        'Granolazo rechazó la grabación (${r.statusCode}): ${_resumir(r.body)}',
        codigo: r.statusCode,
      );
    }
    return itemId;
  }

  /// Últimas grabaciones hechas desde la app, para ver qué llegó de verdad al backend.
  Future<List<Map<String, dynamic>>> ultimasDeLaApp({int limite = 30}) async {
    final r = await _enviar(
      'GET',
      _uri('items', {
        'select': 'id,title,recorded_at,duration_seconds,status,source',
        'source': 'like.app-*',
        'order': 'recorded_at.desc',
        'limit': '$limite',
      }),
    );
    if (r.statusCode >= 400) {
      throw ErrorGranolazo('no pude leer el historial (${r.statusCode})',
          codigo: r.statusCode);
    }
    final data = jsonDecode(r.body);
    return data is List ? data.whereType<Map<String, dynamic>>().toList() : const [];
  }

  /// Comprueba que el backend responde y que la clave sirve.
  Future<bool> probarConexion() async {
    try {
      final r = await _enviar(
        'GET',
        _uri('items', {'select': 'id', 'limit': '1'}),
      );
      return r.statusCode < 400;
    } catch (_) {
      return false;
    }
  }


  // -- consulta del backend -----------------------------------------------------

  /// Busca reuniones en Granolazo, de cualquier fuente.
  ///
  /// A diferencia del panel web, que se trae la tabla entera y filtra en el navegador,
  /// acá se filtra y se pagina del lado del servidor: la app corre también en un celular
  /// y el listado ya trae resúmenes de todos los items.
  ///
  /// El filtro por participante es la excepción y se aplica sobre lo recibido: viven en
  /// una columna JSON y PostgREST no sabe buscar texto libre adentro.
  Future<List<ItemGranolazo>> buscarItems(FiltroItems filtro) async {
    final q = <String, String>{
      'select': _selectLista,
      'order': 'recorded_at.desc.nullslast',
      'limit': '${filtro.limite}',
      if (filtro.desplazamiento > 0) 'offset': '${filtro.desplazamiento}',
    };

    final texto = filtro.texto?.trim();
    if (texto != null && texto.isNotEmpty) {
      // Los paréntesis y las comas son la sintaxis del `or` de PostgREST: si vinieran en
      // lo que escribió el usuario, romperían la consulta.
      final t = texto.replaceAll(RegExp(r'[(),]'), ' ');
      q['or'] = '(title.ilike.*$t*,alias.ilike.*$t*,topic.ilike.*$t*,summary.ilike.*$t*)';
    }
    if (filtro.grupo != null) q['topic'] = 'eq.${filtro.grupo}';
    if (filtro.fuente != null) q['source'] = 'eq.${filtro.fuente}';
    if (filtro.estado != null) q['status'] = 'eq.${filtro.estado}';
    if (filtro.tag != null) q['keywords'] = 'cs.{${filtro.tag}}';
    if (filtro.desde != null) {
      q['recorded_at'] = 'gte.${filtro.desde!.toUtc().toIso8601String()}';
    }
    if (filtro.hasta != null) {
      // La columna ya puede estar ocupada por el `desde`, así que el tope va por `and`.
      q['and'] = '(recorded_at.lt.${filtro.hasta!.toUtc().toIso8601String()})';
    }

    final r = await _enviar('GET', _uri('items', q));
    if (r.statusCode >= 400) {
      throw ErrorGranolazo(
        'no pude leer las reuniones (${r.statusCode}): ${_resumir(r.body)}',
        codigo: r.statusCode,
      );
    }
    final data = jsonDecode(r.body);
    var items = data is List
        ? data.whereType<Map<String, dynamic>>().map(ItemGranolazo.fromJson).toList()
        : <ItemGranolazo>[];

    final persona = filtro.participante?.trim().toLowerCase();
    if (persona != null && persona.isNotEmpty) {
      items = items
          .where((i) =>
              i.nombresParticipantes.any((n) => n.toLowerCase().contains(persona)))
          .toList();
    }
    return items;
  }

  /// En qué va la transcripción de archivos de Drive, por id de archivo.
  ///
  /// El worker guarda en `drive_url` el enlace del archivo que transcribió, así que el
  /// cruce es exacto: no depende de cómo arma el id del item a partir del nombre. Lo que
  /// todavía no aparece en el mapa, el worker aún no lo descubrió.
  Future<Map<String, ItemGranolazo>> itemsPorArchivoDrive(List<String> ids) async {
    final resultado = <String, ItemGranolazo>{};
    // De a tandas: la lista va en la URL y cien enlaces ya son varios kilobytes.
    for (var i = 0; i < ids.length; i += 50) {
      final tanda = ids.skip(i).take(50);
      final enlaces = tanda.map((id) => '"https://drive.google.com/file/d/$id/view"');
      final r = await _enviar(
        'GET',
        _uri('items', {
          'select': '$_selectCola,drive_url',
          'drive_url': 'in.(${enlaces.join(',')})',
        }),
      );
      if (r.statusCode >= 400) {
        throw ErrorGranolazo(
          'no pude leer las transcripciones (${r.statusCode}): ${_resumir(r.body)}',
          codigo: r.statusCode,
        );
      }
      for (final j in (jsonDecode(r.body) as List).whereType<Map<String, dynamic>>()) {
        final item = ItemGranolazo.fromJson(j);
        final id = RegExp(r'/d/([A-Za-z0-9_-]+)').firstMatch(item.enlaceDrive ?? '');
        if (id != null) resultado[id.group(1)!] = item;
      }
    }
    return resultado;
  }

  /// El texto completo de una reunión. Se pide aparte porque es lo más pesado.
  ///
  /// No todas tienen transcripción literal: las que entran por las notas de Gemini de
  /// Meet a veces traen solo el resumen. Por eso se devuelven las dos cosas y quien
  /// muestra decide — pero avisando cuál está viendo, que no es lo mismo.
  Future<TextoDeReunion?> textoDe(String id) async {
    final r = await _enviar(
      'GET',
      _uri('items', {
        'select': 'id,raw_transcript,summary,title,alias',
        'id': 'eq.$id',
        'limit': '1',
      }),
    );
    if (r.statusCode >= 400) {
      throw ErrorGranolazo('no pude leer la transcripción (${r.statusCode})',
          codigo: r.statusCode);
    }
    final data = jsonDecode(r.body);
    if (data is! List || data.isEmpty) return null;
    final j = data.first as Map<String, dynamic>;
    return TextoDeReunion(
      id: id,
      titulo: (j['alias'] as String?) ?? (j['title'] as String?) ?? id,
      transcripcion: j['raw_transcript'] as String?,
      resumen: j['summary'] as String?,
    );
  }

  /// Lo que está pendiente, corriendo o fallado en todo el pipeline.
  ///
  /// No es la cola local del dispositivo: es la del backend, la que alimentan los
  /// workers. Se calcula igual que en el panel — un `pending` con `proc_started_at` es
  /// lo que se está transcribiendo ahora; sin él, lo que espera turno.
  Future<EstadoCola> estadoDeLaCola({int limite = 200}) async {
    final r = await _enviar(
      'GET',
      _uri('items', {
        'select': _selectCola,
        'status': 'in.(pending,error)',
        'order': 'recorded_at.desc.nullslast',
        'limit': '$limite',
      }),
    );
    if (r.statusCode >= 400) {
      throw ErrorGranolazo('no pude leer la cola (${r.statusCode})',
          codigo: r.statusCode);
    }
    final data = jsonDecode(r.body);
    final items = data is List
        ? data.whereType<Map<String, dynamic>>().map(ItemGranolazo.fromJson).toList()
        : <ItemGranolazo>[];
    return EstadoCola(
      procesando: items.where((i) => i.enProceso).toList(),
      esperando: items.where((i) => i.enCola).toList(),
      conError: items.where((i) => i.conError).toList(),
    );
  }

  /// Los grupos, tags y fuentes que existen, para armar los filtros.
  ///
  /// Se saca de una muestra reciente en vez de recorrer la tabla entera: alcanza para
  /// ofrecer opciones y no castiga a un celular con una consulta enorme.
  Future<OpcionesDeFiltro> opcionesDeFiltro({int muestra = 500}) async {
    final r = await _enviar(
      'GET',
      _uri('items', {
        'select': 'topic,keywords,source',
        'order': 'recorded_at.desc.nullslast',
        'limit': '$muestra',
      }),
    );
    if (r.statusCode >= 400) {
      throw ErrorGranolazo('no pude leer los filtros (${r.statusCode})',
          codigo: r.statusCode);
    }
    final data = jsonDecode(r.body);
    final grupos = <String>{};
    final tags = <String>{};
    final fuentes = <String>{};
    if (data is List) {
      for (final fila in data.whereType<Map<String, dynamic>>()) {
        final t = (fila['topic'] as String?)?.trim();
        if (t != null && t.isNotEmpty) grupos.add(t);
        final f = (fila['source'] as String?)?.trim();
        if (f != null && f.isNotEmpty) fuentes.add(f);
        for (final k in (fila['keywords'] as List?) ?? const []) {
          final s = k.toString().trim();
          if (s.isNotEmpty) tags.add(s);
        }
      }
    }
    return OpcionesDeFiltro(
      grupos: grupos.toList()..sort(),
      tags: tags.toList()..sort(),
      fuentes: fuentes.toList()..sort(),
    );
  }

  Future<http.Response> _enviar(
    String metodo,
    Uri uri, {
    String? cuerpo,
    Map<String, String>? extra,
  }) async {
    final headers = {...GranolazoConfig.restHeaders, ...?extra};
    final token = await _sesion?.tokenVigente();
    if (token != null) headers['Authorization'] = 'Bearer $token';
    http.StreamedResponse streamed;
    try {
      final peticion = http.Request(metodo, uri)..headers.addAll(headers);
      if (cuerpo != null) peticion.body = cuerpo;
      streamed = await _cliente.send(peticion).timeout(const Duration(seconds: 60));
    } on SocketException {
      throw ErrorGranolazo('sin conexión con Granolazo');
    }
    return http.Response.fromStream(streamed);
  }

  String _resumir(String cuerpo) =>
      cuerpo.length > 160 ? '${cuerpo.substring(0, 160)}…' : cuerpo;

  void dispose() => _cliente.close();
}

/// Qué reuniones se quieren ver. Todo opcional: sin nada, son las últimas.
class FiltroItems {
  const FiltroItems({
    this.texto,
    this.grupo,
    this.tag,
    this.fuente,
    this.estado,
    this.participante,
    this.desde,
    this.hasta,
    this.limite = 50,
    this.desplazamiento = 0,
  });

  final String? texto;
  final String? grupo;
  final String? tag;
  final String? fuente;

  /// `pending`, `transcribed` o `error`.
  final String? estado;

  /// Nombre, correo o teléfono. Se filtra sobre lo recibido, no en la base.
  final String? participante;

  final DateTime? desde;
  final DateTime? hasta;
  final int limite;
  final int desplazamiento;

  /// Centinela para distinguir "no lo toques" de "ponelo en nulo".
  static const sinCambio = Object();

  FiltroItems copyWith({
    Object? texto = sinCambio,
    Object? grupo = sinCambio,
    Object? tag = sinCambio,
    Object? fuente = sinCambio,
    Object? estado = sinCambio,
    Object? participante = sinCambio,
    Object? desde = sinCambio,
    Object? hasta = sinCambio,
    int? limite,
    int? desplazamiento,
  }) =>
      FiltroItems(
        texto: identical(texto, sinCambio) ? this.texto : texto as String?,
        grupo: identical(grupo, sinCambio) ? this.grupo : grupo as String?,
        tag: identical(tag, sinCambio) ? this.tag : tag as String?,
        fuente: identical(fuente, sinCambio) ? this.fuente : fuente as String?,
        estado: identical(estado, sinCambio) ? this.estado : estado as String?,
        participante: identical(participante, sinCambio)
            ? this.participante
            : participante as String?,
        desde: identical(desde, sinCambio) ? this.desde : desde as DateTime?,
        hasta: identical(hasta, sinCambio) ? this.hasta : hasta as DateTime?,
        limite: limite ?? this.limite,
        desplazamiento: desplazamiento ?? this.desplazamiento,
      );

  bool get hayAlguno =>
      texto != null ||
      grupo != null ||
      tag != null ||
      fuente != null ||
      estado != null ||
      participante != null ||
      desde != null ||
      hasta != null;
}

/// La cola del pipeline, ya separada en lo que importa mirar.
class EstadoCola {
  const EstadoCola({
    required this.procesando,
    required this.esperando,
    required this.conError,
  });

  /// Las que un worker tomó y está transcribiendo ahora.
  final List<ItemGranolazo> procesando;

  /// Las que esperan turno.
  final List<ItemGranolazo> esperando;

  final List<ItemGranolazo> conError;

  int get total => procesando.length + esperando.length + conError.length;

  /// Cuánto falta, suponiendo que transcribir tarda más o menos lo que dura el audio.
  /// Es la misma cuenta que hace el panel web: sirve como orden de magnitud, no más.
  Duration get esperaEstimada => Duration(
        seconds:
            [...procesando, ...esperando].fold(0, (a, i) => a + i.duracionSegundos),
      );
}

/// Valores que existen hoy en el backend, para poblar los filtros.
class OpcionesDeFiltro {
  const OpcionesDeFiltro({
    required this.grupos,
    required this.tags,
    required this.fuentes,
  });
  final List<String> grupos;
  final List<String> tags;
  final List<String> fuentes;
}

/// Lo que se puede leer de una reunión: la transcripción literal y el resumen.
class TextoDeReunion {
  const TextoDeReunion({
    required this.id,
    required this.titulo,
    this.transcripcion,
    this.resumen,
  });

  final String id;
  final String titulo;
  final String? transcripcion;
  final String? resumen;

  bool get hayTranscripcion => (transcripcion ?? '').trim().isNotEmpty;
  bool get hayResumen => (resumen ?? '').trim().isNotEmpty;
  bool get hayAlgo => hayTranscripcion || hayResumen;
}
