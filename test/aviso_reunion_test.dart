import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granolazo_app/services/detector_reuniones.dart';
import 'package:granolazo_app/ui/aviso_reunion.dart';

/// El aviso es lo único que ve el usuario cuando la app vive en la bandeja. Si un botón
/// no hace lo suyo, la detección entera no sirve para nada.
void main() {
  final app = AppEnLlamada(
    ejecutable: r'C:\Users\x\AppData\Local\Discord\Discord.exe',
    nombre: 'Discord',
    desde: DateTime(2026, 9, 19, 10, 30),
  );

  Future<Map<String, int>> montar(WidgetTester t, {Size tamano = const Size(470, 262)}) async {
    final veces = {'grabar': 0, 'descartar': 0, 'ignorar': 0};
    t.view.physicalSize = tamano;
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: AvisoReunion(
        app: app,
        alGrabar: () => veces['grabar'] = veces['grabar']! + 1,
        alDescartar: () => veces['descartar'] = veces['descartar']! + 1,
        alIgnorarApp: () => veces['ignorar'] = veces['ignorar']! + 1,
      ),
    ));
    return veces;
  }

  testWidgets('dice qué aplicación disparó el aviso', (t) async {
    await montar(t);
    expect(find.textContaining('Discord'), findsOneWidget);
    expect(find.text('¿Grabo esta reunión?'), findsOneWidget);
  });

  testWidgets('Grabar avisa a quien corresponde', (t) async {
    final veces = await montar(t);
    await t.tap(find.widgetWithText(FilledButton, 'Grabar'));
    await t.pump();
    expect(veces['grabar'], 1);
    expect(veces['descartar'], 0);
  });

  testWidgets('Ahora no descarta sin silenciar la aplicación', (t) async {
    final veces = await montar(t);
    await t.tap(find.widgetWithText(TextButton, 'Ahora no'));
    await t.pump();
    expect(veces['descartar'], 1);
    expect(veces['ignorar'], 0, reason: 'descartar una vez no es silenciar para siempre');
  });

  testWidgets('Nunca esta app silencia', (t) async {
    final veces = await montar(t);
    await t.tap(find.widgetWithText(TextButton, 'Nunca esta app'));
    await t.pump();
    expect(veces['ignorar'], 1);
  });

  testWidgets('entra completo en su tamaño, sin desbordes', (t) async {
    // El aviso vive en una ventana de tamaño fijo: si el contenido no entra, los botones
    // quedan cortados y no hay forma de aceptarlo. Ya pasó dos veces.
    await montar(t, tamano: AvisoReunion.tamano);
    expect(sinExcepciones(), isTrue);
    expect(find.widgetWithText(FilledButton, 'Grabar'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Ahora no'), findsOneWidget);
  });

  testWidgets('con un nombre largo tampoco desborda', (t) async {
    t.view.physicalSize = AvisoReunion.tamano;
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: AvisoReunion(
        app: AppEnLlamada(
          ejecutable: r'C:\x\una_aplicacion_con_nombre_larguisimo.exe',
          nombre: 'una aplicación con un nombre francamente larguísimo y molesto',
          desde: DateTime(2026, 9, 19),
        ),
        alGrabar: () {},
        alDescartar: () {},
        alIgnorarApp: () {},
      ),
    ));
    expect(sinExcepciones(), isTrue);
    expect(find.widgetWithText(FilledButton, 'Grabar'), findsOneWidget);
  });
}

/// `true` si el marco de pruebas no registró un error de dibujo (desbordes incluidos).
bool sinExcepciones() => TestWidgetsFlutterBinding.instance.takeException() == null;
