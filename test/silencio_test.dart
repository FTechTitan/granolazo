import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:granolazo_app/models/grabacion.dart';
import 'package:granolazo_app/services/grabador_service.dart';

/// El 2026-09-18 una grabación de 32 segundos salió en silencio digital porque el
/// micrófono estaba silenciado por hardware. La app no dio ninguna señal, transcribió el
/// silencio, el modelo inventó "[Música]" y eso llegó a Granolazo como si fuera una
/// reunión. Estos tests fijan el umbral y el arrastre del dato.
void main() {
  group('detección de silencio', () {
    test('el umbral deja afuera el silencio digital y adentro una voz baja', () {
      // Un micrófono mudo o desconectado entrega alrededor de -91 dBFS.
      expect(-91.0 <= GrabadorService.umbralDeSilencio, isTrue,
          reason: 'un micrófono mudo tiene que dar por silencio');
      // Una habitación callada con el micrófono vivo ronda -50; hablar bajito, -35.
      expect(-50.0 > GrabadorService.umbralDeSilencio, isTrue,
          reason: 'una sala callada pero con micrófono vivo NO es silencio');
      expect(-35.0 > GrabadorService.umbralDeSilencio, isTrue,
          reason: 'hablar bajito nunca puede darse por silencio');
    });

    test('el umbral está lejos de los dos extremos, no pegado a uno', () {
      // Si estuviera pegado a -91 no detectaría un micrófono con ruido de fondo mínimo;
      // si estuviera pegado a -50 daría falsos positivos con voz baja.
      expect(GrabadorService.umbralDeSilencio, lessThan(-60));
      expect(GrabadorService.umbralDeSilencio, greaterThan(-85));
    });

    test('que una grabación quedó muda sobrevive al cierre de la app', () {
      final g = Grabacion(
        id: '1',
        rutaArchivo: '/tmp/a.m4a',
        grabadaEn: DateTime.utc(2026, 9, 18),
        estado: EstadoGrabacion.enEspera,
        muda: true,
      );
      final vuelta = Grabacion.listaDesdeJson(Grabacion.listaAJson([g])).single;
      // El archivo existe y pesa: sin este dato no hay forma de distinguirla de una buena.
      expect(vuelta.muda, isTrue);
    });

    test('lo normal es que no esté muda', () {
      final g = Grabacion(
        id: '2',
        rutaArchivo: '/tmp/b.m4a',
        grabadaEn: DateTime.utc(2026, 9, 18),
        estado: EstadoGrabacion.lista,
      );
      expect(g.muda, isFalse);
      expect(Grabacion.listaDesdeJson(Grabacion.listaAJson([g])).single.muda, isFalse);
    });
  });

  group('volumen de cada fuente', _pruebasDeGanancia);
}

/// La ganancia se muestra sumada al nivel medido, porque lo que hay que emparejar es cómo
/// van a quedar las dos fuentes EN LA MEZCLA, no cómo entran.
void _pruebasDeGanancia() {
  // Multiplicar la amplitud por g equivale a sumar 20·log10(g) decibeles.
  double conGanancia(double dbfs, double g) =>
      g <= 0 ? -160 : dbfs + 20 * (math.log(g) / math.ln10);

  test('dejar el volumen en 1 no cambia el nivel', () {
    expect(conGanancia(-30, 1.0), closeTo(-30, 0.001));
  });

  test('duplicar el volumen suma unos 6 dB', () {
    expect(conGanancia(-30, 2.0), closeTo(-23.98, 0.05));
  });

  test('bajarlo a la mitad resta unos 6 dB', () {
    expect(conGanancia(-30, 0.5), closeTo(-36.02, 0.05));
  });

  test('bajarlo a cero es silencio, no menos infinito', () {
    // Sin este caso, log(0) daría -infinito y el medidor se rompería al dibujar.
    expect(conGanancia(-30, 0.0), -160);
  });

  test('emparejar dos fuentes distintas da el mismo nivel de salida', () {
    // Caso real: el otro sale fuerte por los parlantes y uno habla bajo al micrófono.
    const micro = -40.0;
    const equipo = -20.0;
    // Subiendo el micrófono al triple y bajando el equipo a un tercio se acercan.
    final m = conGanancia(micro, 3.0);
    final e = conGanancia(equipo, 1 / 3);
    expect((m - e).abs(), lessThan(1.0),
        reason: 'con esos volúmenes las dos tienen que quedar casi al mismo nivel');
  });
}
