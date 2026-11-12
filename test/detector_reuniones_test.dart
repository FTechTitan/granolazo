import 'package:flutter_test/flutter_test.dart';
import 'package:granolazo_app/services/detector_reuniones.dart';

/// Salida real de `reg query`, copiada de este PC el 2026-09-19. Se usa tal cual y no una
/// versión idealizada: el formato de esa herramienta es lo que hay que aguantar.
const _registro = r'''
HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone\NonPackaged
    Value    REG_SZ    Allow
    LastSetTime    REG_QWORD    0x1dd22b677fc93a8

HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone\NonPackaged\C:#Users#Dell#AppData#Local#Discord#app-1.0.9257#Discord.exe
    LastUsedTimeStart    REG_QWORD    0x1dd47b38e2898db
    LastUserAnnotatedLabel    REG_DWORD    0x2
    LastUsedTimeStop    REG_QWORD    0x0
    PersistedInDatabase    REG_DWORD    0x1

HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone\NonPackaged\C:#Program Files#obs-studio#bin#64bit#obs64.exe
    LastUsedTimeStart    REG_QWORD    0x1dd47b38e2898db
    LastUsedTimeStop    REG_QWORD    0x1dd47b38fa8a298
    PersistedInDatabase    REG_DWORD    0x1

HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone\NonPackaged\C:#Program Files#Google#Chrome#Application#chrome.exe
    LastUsedTimeStart    REG_QWORD    0x1dd47b38e2898db
    LastUsedTimeStop    REG_QWORD    0x0
    PersistedInDatabase    REG_DWORD    0x1
''';

const _tasklist = '''
"System Idle Process","0","Services","0","8 KB"
"Discord.exe","1234","Console","1","250.000 KB"
"chrome.exe","5678","Console","1","800.000 KB"
''';

DetectorReuniones _detector({String registro = _registro, String tareas = _tasklist}) =>
    DetectorReuniones(
      correr: (programa, args) async => programa == 'reg' ? registro : tareas,
    );

void main() {
  test('detecta las que estan usando el microfono ahora', () async {
    final d = _detector();
    final r = await d.revisar();
    // Discord y Chrome tienen comienzo sin final Y estan corriendo.
    expect(r.map((a) => a.nombre), containsAll(['Discord', 'el navegador (Meet, WhatsApp Web…)']));
    expect(d.hayReunion, isTrue);
  });

  test('ignora las que ya soltaron el microfono', () async {
    final r = await _detector().revisar();
    // OBS tiene final: ya termino.
    expect(r.any((a) => a.nombre == 'OBS'), isFalse);
  });

  test('ignora una entrada abierta de un proceso que ya no existe', () async {
    // Este es el caso que arruina la version ingenua: una app que murio de golpe deja
    // la entrada marcada como "en uso" para siempre, y sin el cruce sugeririamos grabar
    // cada pocos segundos para siempre.
    final d = _detector(tareas: '"chrome.exe","5678","Console","1","800.000 KB"\n');
    final r = await d.revisar();
    expect(r.any((a) => a.nombre == 'Discord'), isFalse,
        reason: 'Discord no esta corriendo: su entrada abierta es basura');
    expect(r, hasLength(1));
  });

  test('sin nada usando el microfono no sugiere nada', () async {
    final sinAbiertas = _registro.replaceAll('0x0\n', '0x1dd47b38fa8a298\n');
    final d = _detector(registro: sinAbiertas);
    expect(await d.revisar(), isEmpty);
    expect(d.hayReunion, isFalse);
  });

  test('no se confunde con la clave contenedora', () async {
    // La primera clave del listado no es una aplicacion; si se tomara como tal,
    // aparecerian sugerencias fantasma.
    final r = await _detector().revisar();
    expect(r.every((a) => a.ejecutable.contains(r'\')), isTrue);
  });

  test('una app desconocida se nombra igual, no se descarta', () async {
    const raro = r'''
HKEY_CURRENT_USER\...\NonPackaged\C:#apps#cosarara.exe
    LastUsedTimeStart    REG_QWORD    0x1dd47b38e2898db
    LastUsedTimeStop    REG_QWORD    0x0
''';
    final d = _detector(registro: raro, tareas: '"cosarara.exe","1","Console","1","1 KB"\n');
    final r = await d.revisar();
    expect(r.single.nombre, 'Cosarara');
  });

  test('se puede silenciar una aplicacion', () async {
    final d = _detector();
    final r = await d.revisar();
    final discord = r.firstWhere((a) => a.nombre == 'Discord');
    d.ignorar(discord);
    expect(d.enLlamada.contains(discord), isFalse);
    // Y sigue ignorada en la siguiente vuelta.
    expect((await d.revisar()).contains(discord), isFalse);
  });
}
