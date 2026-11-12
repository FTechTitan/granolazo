import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:granolazo_app/en_vivo/pcm.dart';

Uint8List _pcm(List<int> muestras) {
  final b = ByteData(muestras.length * 2);
  for (var i = 0; i < muestras.length; i++) {
    b.setInt16(i * 2, muestras[i], Endian.little);
  }
  return b.buffer.asUint8List();
}

void main() {
  test('aWav arma una cabecera de 44 bytes que se lee de vuelta', () {
    final wav = Pcm.aWav(_pcm([1, 2, 3, 4]));
    expect(wav.length, 44 + 8);
    final c = CabeceraWav.leer(wav)!;
    expect(c.tasaHz, 16000);
    expect(c.canales, 1);
    expect(c.bits, 16);
    expect(c.flotante, isFalse);
    expect(c.inicioDatos, 44);
  });

  test('un WAV a medio escribir (tamaños en cero) igual se reconoce', () {
    final wav = Pcm.aWav(_pcm([5, 6]));
    final bd = ByteData.sublistView(wav);
    bd.setUint32(4, 0, Endian.little);
    bd.setUint32(40, 0, Endian.little);
    final c = CabeceraWav.leer(wav);
    expect(c, isNotNull);
    expect(c!.inicioDatos, 44);
  });

  test('basura o cabecera incompleta devuelven null', () {
    expect(CabeceraWav.leer(Uint8List(10)), isNull);
    expect(CabeceraWav.leer(Uint8List(64)), isNull);
  });

  test('rmsDbfs: silencio es muy bajo, una señal fuerte es cercana a 0', () {
    expect(Pcm.rmsDbfs(Pcm.silencio(1)), -160);
    final fuerte = _pcm(List.filled(1600, 20000));
    expect(Pcm.rmsDbfs(fuerte), closeTo(-4.3, 0.3));
    expect(Pcm.rmsDbfs(Uint8List(0)), -160);
  });

  test('mezclar suma pista contra pista, con tope y completando la corta', () {
    final r = Pcm.mezclar(_pcm([100, 30000, -30000]), _pcm([50, 30000]));
    final bd = ByteData.sublistView(r);
    expect(r.length, 6);
    expect(bd.getInt16(0, Endian.little), 150);
    expect(bd.getInt16(2, Endian.little), 32767);
    expect(bd.getInt16(4, Endian.little), -30000);
  });

  group('ConversorAMono16k', () {
    CabeceraWav cab({required bool flotante, required int canales, required int tasa, required int bits}) =>
        CabeceraWav(flotante: flotante, canales: canales, tasaHz: tasa, bits: bits, inicioDatos: 44);

    test('48 kHz estéreo float pasa a 16 kHz mono con un tercio de las muestras', () {
      final conv = ConversorAMono16k(cab(flotante: true, canales: 2, tasa: 48000, bits: 32));
      const cuadros = 4800; // 0,1 s
      final b = ByteData(cuadros * 2 * 4);
      for (var i = 0; i < cuadros; i++) {
        b.setFloat32(i * 8, 0.5, Endian.little);
        b.setFloat32(i * 8 + 4, 0.25, Endian.little);
      }
      final out = conv.convertir(b.buffer.asUint8List());
      expect(out.length ~/ 2, 1600);
      final v = ByteData.sublistView(out).getInt16(0, Endian.little);
      expect(v, closeTo(0.375 * 32767, 2));
    });

    test('un cuadro partido entre dos lecturas no se pierde ni se corrompe', () {
      final conv = ConversorAMono16k(cab(flotante: false, canales: 1, tasa: 16000, bits: 16));
      final todo = _pcm([1000, 2000, 3000, 4000]);
      final a = conv.convertir(Uint8List.sublistView(todo, 0, 3));
      final b = conv.convertir(Uint8List.sublistView(todo, 3));
      final junto = BytesBuilder()
        ..add(a)
        ..add(b);
      final bd = ByteData.sublistView(junto.takeBytes());
      expect([for (var i = 0; i < 4; i++) bd.getInt16(i * 2, Endian.little)], [1000, 2000, 3000, 4000]);
    });

    test('44,1 kHz da una cantidad de muestras proporcional, sin acumular error', () {
      final conv = ConversorAMono16k(cab(flotante: false, canales: 1, tasa: 44100, bits: 16));
      var total = 0;
      for (var i = 0; i < 10; i++) {
        total += conv.convertir(_pcm(List.filled(4410, 1000))).length ~/ 2;
      }
      expect(total, closeTo(16000, 2));
    });
  });
}
