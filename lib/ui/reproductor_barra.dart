import 'package:flutter/material.dart';

import '../models/grabacion.dart';
import '../services/reproductor_service.dart';

/// Los controles de reproducción de una grabación: barra, tiempos y saltos.
///
/// Aparece bajo la grabación que se está escuchando. Un botón de reproducir solo no
/// alcanza: si el audio dura media hora, sin barra ni saltos no hay forma de llegar al
/// minuto que interesa, y sin los tiempos no se sabe ni cuánto falta.
class ReproductorBarra extends StatelessWidget {
  const ReproductorBarra({
    super.key,
    required this.grabacion,
    required this.reproductor,
  });

  final Grabacion grabacion;
  final ReproductorService reproductor;

  /// Cuánto salta cada flecha. Quince segundos es el salto habitual de los reproductores
  /// de voz: suficiente para pasar una frase, poco para no perderse.
  static const salto = Duration(seconds: 15);

  static String _reloj(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: reproductor,
      builder: (context, _) {
        if (!reproductor.estaCargada(grabacion.id)) {
          return const SizedBox.shrink();
        }

        // Mientras el reproductor no informó la duración se usa la que ya se conoce de la
        // grabación: así la barra no arranca en cero y después pega un salto.
        final total = reproductor.duracion > Duration.zero
            ? reproductor.duracion
            : Duration(seconds: grabacion.duracionSegundos);
        final posicion = reproductor.posicion > total ? total : reproductor.posicion;
        final maximo = total.inMilliseconds.toDouble();
        final valor = posicion.inMilliseconds.toDouble().clamp(0, maximo).toDouble();
        final sonando = reproductor.sonando;

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Column(
            children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                ),
                child: Slider(
                  value: valor,
                  max: maximo <= 0 ? 1 : maximo,
                  onChanged: maximo <= 0
                      ? null
                      : (v) => reproductor.irA(Duration(milliseconds: v.round())),
                ),
              ),
              Row(
                children: [
                  Text(_reloj(posicion),
                      style: Theme.of(context).textTheme.labelSmall),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Atrás 15 segundos',
                    icon: const Icon(Icons.replay_10, size: 22),
                    onPressed: () {
                      final destino = posicion - salto;
                      reproductor.irA(destino < Duration.zero ? Duration.zero : destino);
                    },
                  ),
                  IconButton.filledTonal(
                    tooltip: sonando ? 'Pausar' : 'Reproducir',
                    icon: Icon(sonando ? Icons.pause : Icons.play_arrow),
                    onPressed: () =>
                        reproductor.alternar(grabacion.id, grabacion.rutaArchivo),
                  ),
                  IconButton(
                    tooltip: 'Adelante 15 segundos',
                    icon: const Icon(Icons.forward_10, size: 22),
                    onPressed: () {
                      final destino = posicion + salto;
                      reproductor.irA(destino > total ? total : destino);
                    },
                  ),
                  IconButton(
                    tooltip: 'Detener',
                    icon: const Icon(Icons.stop, size: 20),
                    onPressed: reproductor.detener,
                  ),
                  const Spacer(),
                  Text(_reloj(total), style: Theme.of(context).textTheme.labelSmall),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
