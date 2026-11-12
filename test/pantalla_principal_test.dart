import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granolazo_app/controllers/grabaciones_controller.dart';
import 'package:granolazo_app/services/granolazo_api.dart';
import 'package:granolazo_app/services/ajustes_service.dart';
import 'package:granolazo_app/services/detector_reuniones.dart';
import 'package:granolazo_app/services/presencia_service.dart';
import 'package:granolazo_app/services/reproductor_service.dart';
import 'package:granolazo_app/services/sesion_service.dart';
import 'package:granolazo_app/ui/pantalla_principal.dart';
import 'package:granolazo_app/ui/pantalla_sesion.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Reunión de mentira, con la forma exacta que devuelve PostgREST.
final _reunion = {
  'id': 'obs-prueba.mkv',
  'title': 'Reunión con el cliente',
  'alias': null,
  'topic': 'Proyecto Demo',
  'status': 'transcribed',
  'error_msg': null,
  'recorded_at': '2026-09-10T14:00:00+00:00',
  'discovered_at': '2026-09-10T15:00:00+00:00',
  'transcribed_at': '2026-09-10T15:30:00+00:00',
  'summary': 'Se habló del bot',
  'keywords': ['cliente', 'seguimiento'],
  'duration_seconds': 1800,
  'source': 'obs',
  'source_folder': 'obs-2026',
  'participants': [
    {'email': 'someone@example.com'}
  ],
  'drive_url': null,
  'transcription_provider': 'local-whisper',
  'progress': 100,
};

final _pendiente = {
  'id': 's22-nota.m4a',
  'title': 'Nota de voz',
  'alias': null,
  'status': 'pending',
  'error_msg': null,
  'recorded_at': '2026-09-17T09:00:00+00:00',
  'duration_seconds': 600,
  'progress': 0,
  'paused': false,
  'queue_priority': 0,
  'proc_started_at': null,
  'proc_heartbeat': null,
  'openai_status': null,
  'openai_chunks_done': null,
  'openai_chunks_total': null,
  'source': 's22',
};

/// Un backend de mentira que responde según qué columnas se pidan.
///
/// Sirve para probar que la app arma bien las consultas y dibuja lo que vuelve, sin
/// tocar el Granolazo de verdad ni depender de que haya red.
http.Client _backendFalso({List<Uri>? registro}) => MockClient((peticion) async {
      registro?.add(peticion.url);
      final select = peticion.url.queryParameters['select'] ?? '';
      if (select.contains('proc_started_at')) {
        return http.Response(jsonEncode([_pendiente]), 200,
            headers: {'content-type': 'application/json'});
      }
      if (select.contains('raw_transcript')) {
        return http.Response(
            jsonEncode([
              {'id': _reunion['id'], 'raw_transcript': 'texto', 'summary': null}
            ]),
            200,
            headers: {'content-type': 'application/json'});
      }
      if (select == 'topic,keywords,source') {
        return http.Response(jsonEncode([_reunion]), 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response(jsonEncode([_reunion]), 200,
          headers: {'content-type': 'application/json'});
    });

Widget _app(GranolazoApi api, {SesionService? sesion}) => MaterialApp(
      home: PantallaPrincipal(
        controller: GrabacionesController(api: api),
        api: api,
        sesion: sesion ?? SesionService(cliente: _backendFalso()),
        reproductor: ReproductorService(),
        presencia: PresenciaService(
          // Un detector que nunca encuentra nada: la sugerencia se prueba aparte.
          detector: DetectorReuniones(correr: (_, _) async => ''),
          ajustes: AjustesService(),
        ),
      ),
    );

void main() {
  testWidgets('el armazón ofrece grabar, reuniones y cola', (t) async {
    await t.pumpWidget(_app(GranolazoApi(cliente: _backendFalso())));
    await t.pump();

    expect(find.text('Grabar'), findsWidgets);
    expect(find.text('Reuniones'), findsWidgets);
    expect(find.text('Cola'), findsWidgets);
  });

  testWidgets('sin sesión la barra invita a entrar', (t) async {
    await t.pumpWidget(_app(GranolazoApi(cliente: _backendFalso())));
    await t.pump();

    expect(find.text('Entrar'), findsOneWidget);

    await t.tap(find.text('Entrar'));
    await t.pumpAndSettle();
    expect(find.byType(PantallaSesion), findsOneWidget);
  });

  testWidgets('la pantalla de sesión no deja entrar con el correo vacío', (t) async {
    await t.pumpWidget(MaterialApp(
      home: PantallaSesion(sesion: SesionService(cliente: _backendFalso())),
    ));
    await t.pumpAndSettle();

    await t.tap(find.widgetWithText(FilledButton, 'Entrar'));
    await t.pump();

    expect(find.text('falta un correo válido'), findsOneWidget);
    expect(find.text('falta la contraseña'), findsOneWidget);
  });

  testWidgets('las reuniones del backend se listan', (t) async {
    await t.pumpWidget(_app(GranolazoApi(cliente: _backendFalso())));
    await t.pump();

    await t.tap(find.text('Reuniones').last);
    await t.pumpAndSettle();

    expect(find.text('Reunión con el cliente'), findsOneWidget);
    // La fecha, la duración y la fuente van juntas en el subtítulo.
    expect(find.textContaining('30:00'), findsOneWidget);
    expect(find.textContaining('obs'), findsOneWidget);
  });

  testWidgets('el listado NO se trae la transcripción', (t) async {
    // Es la diferencia deliberada con el panel web: la transcripción pesa y solo se pide
    // al abrir una reunión. Si alguien la agrega al select, este test lo detecta.
    final urls = <Uri>[];
    await t.pumpWidget(_app(GranolazoApi(cliente: _backendFalso(registro: urls))));
    await t.pump();
    await t.tap(find.text('Reuniones').last);
    await t.pumpAndSettle();

    final listados = urls.where((u) =>
        (u.queryParameters['select'] ?? '').contains('duration_seconds'));
    expect(listados, isNotEmpty);
    for (final u in listados) {
      expect(u.queryParameters['select'], isNot(contains('raw_transcript')));
    }
  });

  testWidgets('la cola separa lo que espera de lo que está corriendo', (t) async {
    await t.pumpWidget(_app(GranolazoApi(cliente: _backendFalso())));
    await t.pump();

    await t.tap(find.text('Cola').last);
    await t.pumpAndSettle();

    expect(find.textContaining('Esperando turno'), findsOneWidget);
    expect(find.text('Nota de voz'), findsOneWidget);
    // Sin proc_started_at no se está procesando: no debe aparecer esa sección.
    expect(find.textContaining('Transcribiendo ahora'), findsNothing);
  });
}
