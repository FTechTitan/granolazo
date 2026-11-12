import 'package:flutter_test/flutter_test.dart';
import 'package:granolazo_app/models/grabacion.dart';
import 'package:granolazo_app/models/segmento.dart';

/// Saber cuándo se dijo cada cosa es lo que permite volver al audio y lo que hace
/// buscable una reunión de una hora. Estos tests fijan el formato y que sobreviva al
/// disco, porque las marcas viajan dentro del propio texto que se sube a Granolazo.
void main() {
  final comienzo = DateTime(2026, 9, 18, 15, 30, 0);
  final segmentos = [
    const Segmento(
      desde: Duration(seconds: 0),
      hasta: Duration(seconds: 5),
      texto: 'Hola, buenas tardes.',
    ),
    const Segmento(
      desde: Duration(minutes: 12, seconds: 7),
      hasta: Duration(minutes: 12, seconds: 19),
      texto: 'Ahí quedamos con el presupuesto.',
    ),
    const Segmento(
      desde: Duration(hours: 1, minutes: 3, seconds: 40),
      hasta: Duration(hours: 1, minutes: 3, seconds: 55),
      texto: 'Nos hablamos el lunes.',
    ),
  ];

  group('marcas de tiempo', () {
    test('la marca pasa a horas solo cuando hace falta', () {
      expect(segmentos[0].marca, '00:00');
      expect(segmentos[1].marca, '12:07');
      expect(segmentos[2].marca, '1:03:40');
    });

    test('la hora del día se calcula desde el comienzo de la grabación', () {
      // Es lo que se busca cuando uno pregunta "a qué hora dijo eso": la hora del
      // reloj se cruza con el calendario; el minuto dentro del archivo, no.
      expect(segmentos[0].horaDelDiaLegible(comienzo), '15:30:00');
      expect(segmentos[1].horaDelDiaLegible(comienzo), '15:42:07');
      expect(segmentos[2].horaDelDiaLegible(comienzo), '16:33:40');
    });

    test('el texto plano no lleva marcas', () {
      expect(
        Segmento.textoPlano(segmentos),
        'Hola, buenas tardes. Ahí quedamos con el presupuesto. Nos hablamos el lunes.',
      );
    });

    test('el texto con marcas lleva una línea por tramo', () {
      final t = Segmento.textoConMarcas(segmentos, comienzo: comienzo);
      expect(t.split('\n'), hasLength(3));
      expect(t, startsWith('[15:30:00] Hola'));
      expect(t, contains('[15:42:07] Ahí quedamos'));
    });

    test('los tramos vacíos se descartan', () {
      final con = [
        ...segmentos,
        const Segmento(
          desde: Duration(seconds: 90),
          hasta: Duration(seconds: 92),
          texto: '   ',
        ),
      ];
      expect(Segmento.textoConMarcas(con, comienzo: comienzo).split('\n'), hasLength(3));
    });
  });

  group('la grabación conserva los tiempos', () {
    Grabacion conSegmentos(List<Segmento> ss) => Grabacion(
          id: '1',
          rutaArchivo: '/tmp/a.m4a',
          grabadaEn: comienzo,
          estado: EstadoGrabacion.lista,
          transcripcion: Segmento.textoPlano(ss),
          segmentos: ss,
        );

    test('los segmentos sobreviven al cierre de la app', () {
      final g = conSegmentos(segmentos);
      final vuelta = Grabacion.listaDesdeJson(Grabacion.listaAJson([g])).single;
      expect(vuelta.segmentos, hasLength(3));
      expect(vuelta.segmentos[1].desde, const Duration(minutes: 12, seconds: 7));
      expect(vuelta.segmentos[1].texto, 'Ahí quedamos con el presupuesto.');
    });

    test('lo que se sube lleva las horas adentro del texto', () {
      // Es lo que ve el panel web, que lee raw_transcript como texto plano.
      expect(conSegmentos(segmentos).textoConMarcas, contains('[15:42:07]'));
    });

    test('sin segmentos se sube el texto corrido, no vacío', () {
      // Las transcripciones hechas antes de que esto existiera no tienen tiempos: no
      // pueden quedar sin texto por eso.
      final g = Grabacion(
        id: '2',
        rutaArchivo: '/tmp/b.m4a',
        grabadaEn: comienzo,
        estado: EstadoGrabacion.lista,
        transcripcion: 'texto viejo sin marcas',
      );
      expect(g.hayTiempos, isFalse);
      expect(g.textoConMarcas, 'texto viejo sin marcas');
    });
  });
}
