// Pruebas de la lógica pura: no tocan plugins nativos, así que corren en cualquier lado.
import 'package:flutter_test/flutter_test.dart';
import 'package:granolazo_app/models/grabacion.dart';

void main() {
  Grabacion base({EstadoGrabacion estado = EstadoGrabacion.pendiente}) => Grabacion(
        id: '123',
        rutaArchivo: '/tmp/a.m4a',
        grabadaEn: DateTime.utc(2026, 9, 18, 14, 30),
        estado: estado,
        duracionSegundos: 95,
      );

  test('el título por defecto sale de la fecha de grabación', () {
    expect(base().tituloVisible, contains('2026-09-18'));
  });

  test('un título propio gana sobre el generado', () {
    expect(base().copyWith(titulo: 'Reunión con el cliente').tituloVisible,
        'Reunión con el cliente');
  });

  test('la duración se muestra en minutos y segundos', () {
    expect(base().duracionLegible, '01:35');
    expect(base().copyWith(duracionSegundos: 3725).duracionLegible, '1:02:05');
    expect(base().copyWith(duracionSegundos: 0).duracionLegible, '--:--');
  });

  test('copyWith no muta el original', () {
    final original = base();
    final copia = original.copyWith(estado: EstadoGrabacion.lista);
    expect(original.estado, EstadoGrabacion.pendiente);
    expect(copia.estado, EstadoGrabacion.lista);
    expect(copia.id, original.id);
  });

  test('limpiarError borra el mensaje anterior', () {
    final conError = base().copyWith(
        estado: EstadoGrabacion.error, mensajeError: 'se cayó la red');
    expect(conError.copyWith(limpiarError: true).mensajeError, isNull);
  });

  test('la ida y vuelta a JSON conserva los datos', () {
    final g = base().copyWith(
        transcripcion: 'hola', itemIdRemoto: 'app-windows-123', titulo: 'Prueba');
    final vuelta = Grabacion.listaDesdeJson(Grabacion.listaAJson([g])).single;
    expect(vuelta.id, g.id);
    expect(vuelta.transcripcion, 'hola');
    expect(vuelta.itemIdRemoto, 'app-windows-123');
    expect(vuelta.grabadaEn, g.grabadaEn);
  });

  test('lo que quedó a medio procesar vuelve a pendiente al reabrir la app', () {
    // Si no, una grabación quedaría para siempre diciendo "transcribiendo".
    for (final estado in [
      EstadoGrabacion.transcribiendo,
      EstadoGrabacion.subiendo,
      EstadoGrabacion.grabando,
    ]) {
      final vuelta =
          Grabacion.listaDesdeJson(Grabacion.listaAJson([base(estado: estado)])).single;
      expect(vuelta.estado, EstadoGrabacion.pendiente, reason: estado.name);
    }
  });

  test('un estado terminal se conserva al reabrir', () {
    for (final estado in [EstadoGrabacion.lista, EstadoGrabacion.error]) {
      final vuelta =
          Grabacion.listaDesdeJson(Grabacion.listaAJson([base(estado: estado)])).single;
      expect(vuelta.estado, estado);
    }
  });

  test('un JSON corrupto no rompe la carga', () {
    expect(Grabacion.listaDesdeJson('{"no":"es una lista"}'), isEmpty);
  });

  group('grabar y transcribir por separado', _pruebasDeEspera);
}

/// Grabar y transcribir son dos momentos distintos: estos tests fijan esa separación,
/// que es lo que permite grabar sin clave, sin conexión y sin gastar.
void _pruebasDeEspera() {
  test('una grabación en espera sobrevive al cierre de la app', () {
    final g = Grabacion(
      id: '1',
      rutaArchivo: '/tmp/a.m4a',
      grabadaEn: DateTime.utc(2026, 9, 18, 12),
      estado: EstadoGrabacion.enEspera,
    );
    final vuelta = Grabacion.listaDesdeJson(Grabacion.listaAJson([g])).single;
    // Si volviera como pendiente, la app se pondría a transcribir sola algo que se
    // dejó en espera a propósito.
    expect(vuelta.estado, EstadoGrabacion.enEspera);
  });

  test('lo que quedó a medio transcribir sí vuelve a la cola', () {
    for (final estado in [EstadoGrabacion.transcribiendo, EstadoGrabacion.subiendo]) {
      final g = Grabacion(
        id: '2',
        rutaArchivo: '/tmp/b.m4a',
        grabadaEn: DateTime.utc(2026, 9, 18),
        estado: estado,
      );
      final vuelta = Grabacion.listaDesdeJson(Grabacion.listaAJson([g])).single;
      expect(vuelta.estado, EstadoGrabacion.pendiente, reason: 'viniendo de $estado');
    }
  });

  test('faltaProcesar cubre en espera, encoladas y con error, y nada más', () {
    expect(EstadoGrabacion.enEspera.faltaProcesar, isTrue);
    expect(EstadoGrabacion.pendiente.faltaProcesar, isTrue);
    expect(EstadoGrabacion.error.faltaProcesar, isTrue);
    expect(EstadoGrabacion.lista.faltaProcesar, isFalse);
    expect(EstadoGrabacion.transcribiendo.faltaProcesar, isFalse);
  });

  test('el motor con que se transcribió se conserva', () {
    final g = Grabacion(
      id: '3',
      rutaArchivo: '/tmp/c.m4a',
      grabadaEn: DateTime.utc(2026, 9, 18),
      estado: EstadoGrabacion.lista,
      motor: 'local',
    );
    expect(Grabacion.listaDesdeJson(Grabacion.listaAJson([g])).single.motor, 'local');
    expect(g.copyWith(estado: EstadoGrabacion.error).motor, 'local');
  });
}
