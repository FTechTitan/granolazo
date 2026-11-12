import 'package:flutter_test/flutter_test.dart';
import 'package:granolazo_app/cli/granolazo_cli.dart';

/// La regla que decide entre ventana y consola está escrita dos veces: acá y en
/// `windows/runner/main.cpp`, que es quien decide si se dibuja la ventana. Si las dos
/// dejan de coincidir aparece el peor de los fallos: la app abre una ventana y además
/// intenta responder por consola, o corre invisible sin que nadie se lo haya pedido.
/// Estos tests fijan el lado Dart; el comentario en el runner apunta acá.
void main() {
  group('esInvocacionDeConsola', () {
    test('sin argumentos abre la ventana', () {
      expect(GranolazoCli.esInvocacionDeConsola(const []), isFalse);
    });

    test('un comando suelto pide la consola', () {
      expect(GranolazoCli.esInvocacionDeConsola(const ['estado']), isTrue);
      expect(GranolazoCli.esInvocacionDeConsola(const ['importar', 'a.m4a']), isTrue);
    });

    test('las banderas que inyecta el motor de Flutter no cuentan', () {
      // Es lo que llega con `flutter run` en modo depuración: si esto se tomara como
      // modo consola, la app nunca mostraría la ventana al desarrollar.
      expect(
        GranolazoCli.esInvocacionDeConsola(const [
          '--observatory-port=0',
          '--enable-checked-mode',
          '--verify-entry-points',
        ]),
        isFalse,
      );
    });

    test('pedir ayuda cuenta aunque venga con guiones', () {
      for (final bandera in const ['--ayuda', '--help', '-h']) {
        expect(GranolazoCli.esInvocacionDeConsola([bandera]), isTrue,
            reason: 'con $bandera');
      }
    });

    test('--json solo no alcanza: sin comando no hay nada que responder', () {
      expect(GranolazoCli.esInvocacionDeConsola(const ['--json']), isFalse);
    });

    test('un comando entre banderas se detecta igual', () {
      expect(
        GranolazoCli.esInvocacionDeConsola(const ['--json', 'estado']),
        isTrue,
      );
    });

    test('los argumentos vacios se ignoran', () {
      expect(GranolazoCli.esInvocacionDeConsola(const ['']), isFalse);
    });
  });

  test('todos los comandos de la ayuda estan en la lista de comandos', () {
    // Evita el caso de agregar un comando al texto de ayuda y olvidarse de aceptarlo.
    for (final c in const [
      'estado',
      'listar',
      'importar',
      'grabar',
      'procesar',
      'reintentar',
      'eliminar',
      'clave',
      'modelo',
      'config',
      'probar',
      'entrar',
      'salir',
      'quien',
      'reuniones',
      'ver',
      'cola',
      'filtros',
      'reuniones-en-curso',
      'arranque',
      'ayuda',
    ]) {
      expect(GranolazoCli.comandos, contains(c));
    }
  });
}
