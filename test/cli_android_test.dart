import 'package:flutter_test/flutter_test.dart';
import 'package:granolazo_app/cli/granolazo_cli.dart';
import 'package:granolazo_app/cli/salida_consola.dart';

/// El modo consola de Android recibe el comando como **un solo texto**, porque `adb` no
/// sabe entregar una lista de argumentos. Todo lo que en Windows hace el shell —separar,
/// respetar comillas, dejar pasar los espacios de adentro— hay que hacerlo acá.
///
/// Es exactamente el tipo de cosa que parece trivial y no lo es: un alias con espacio, un
/// correo entre comillas o un argumento vacío a propósito rompen la versión ingenua.
void main() {
  group('partir la línea de comando', () {
    test('separa por espacios', () {
      expect(GranolazoCli.partirLinea('listar --json'), ['listar', '--json']);
    });

    test('respeta lo que va entre comillas', () {
      expect(
        GranolazoCli.partirLinea('importar "C:/mis audios/reunion del lunes.m4a"'),
        ['importar', 'C:/mis audios/reunion del lunes.m4a'],
      );
    });

    test('acepta comilla simple, que es la que sobrevive a adb', () {
      // `adb shell` se come un nivel de comillas: las dobles suelen desaparecer por el
      // camino y termina llegando la simple.
      expect(
        GranolazoCli.partirLinea("entrar --correo 'a b@example.com'"),
        ['entrar', '--correo', 'a b@example.com'],
      );
    });

    test('un argumento vacío entre comillas no se pierde', () {
      // `--alias ""` es "borrale el alias", no "no me pasaron alias". Si se descarta, el
      // comando hace algo distinto de lo que se le pidió.
      expect(GranolazoCli.partirLinea('ver 7 --alias ""'), ['ver', '7', '--alias', '']);
    });

    test('aguanta espacios de más y tabulaciones', () {
      expect(GranolazoCli.partirLinea('  listar    --json  '), ['listar', '--json']);
    });

    test('una línea vacía no produce argumentos', () {
      expect(GranolazoCli.partirLinea('   '), isEmpty);
    });

    test('las comillas pegadas a una palabra no la parten', () {
      expect(GranolazoCli.partirLinea('config --nombre="mi pc"'),
          ['config', '--nombre=mi pc']);
    });
  });

  group('salida en memoria', () {
    test('junta lo escrito en orden, salida normal y errores', () {
      final s = SalidaEnMemoria();
      s.escribir('primero');
      s.escribirError('un problema');
      s.escribir('segundo');
      expect(s.texto, 'primero\nun problema\nsegundo\n');
    });

    test('empieza sin error', () {
      expect(SalidaEnMemoria().codigo, 0);
    });

    test('terminar no mata el proceso', () async {
      // Es la diferencia clave con la salida de escritorio: acá el motor puede ser el de
      // la app que el usuario tiene abierta, y matarlo se la llevaría puesta.
      final s = SalidaEnMemoria();
      await expectLater(s.terminar(1), throwsStateError);
      expect(s.codigo, 1);
    });
  });

  test('los comandos nuevos de reuniones siguen reconocidos', () {
    // El modo consola de Android corre el mismo CLI: si un comando deja de existir acá,
    // deja de existir en el teléfono.
    expect(GranolazoCli.comandos, containsAll(['arranque', 'reuniones-en-curso']));
  });
}
