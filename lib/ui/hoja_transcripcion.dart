import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/grabacion.dart';
import '../models/segmento.dart';
import '../services/reproductor_service.dart';

/// La transcripción de una grabación, con la hora de cada tramo.
///
/// Cada frase muestra cuándo se dijo y **se puede tocar para saltar a ese punto del
/// audio**. Es lo que convierte la marca de tiempo en algo útil: sin eso, saber que algo
/// se dijo en el minuto doce obliga a buscarlo a mano.
///
/// La hora que se muestra es la del reloj —la del día— y no el minuto dentro del archivo:
/// en una reunión es lo que se cruza con el calendario y con lo que uno recuerda.
class HojaTranscripcion extends StatelessWidget {
  const HojaTranscripcion({
    super.key,
    required this.grabacion,
    required this.reproductor,
  });

  final Grabacion grabacion;
  final ReproductorService reproductor;

  @override
  Widget build(BuildContext context) {
    final g = grabacion;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: Theme.of(context).dividerColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(g.tituloVisible,
                          style: Theme.of(context).textTheme.titleMedium),
                      Text(
                        '${g.duracionLegible}'
                        '${g.motor == null ? "" : " · ${g.motor == "local" ? "este equipo" : "servicio en línea"}"}'
                        '${g.hayTiempos ? " · con marcas de tiempo" : ""}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Copiar con las horas',
                  icon: const Icon(Icons.copy),
                  onPressed: () async {
                    await Clipboard.setData(
                        ClipboardData(text: g.textoConMarcas));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('texto copiado')),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: g.hayTiempos
                ? _conTiempos(context, scroll)
                : _corrido(context, scroll),
          ),
        ],
      ),
    );
  }

  Widget _conTiempos(BuildContext context, ScrollController scroll) {
    return ListenableBuilder(
      listenable: reproductor,
      builder: (context, _) {
        final sonandoEsta = reproductor.estaCargada(grabacion.id);
        final posicion = reproductor.posicion;
        return ListView.builder(
          controller: scroll,
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: grabacion.segmentos.length,
          itemBuilder: (context, i) {
            final s = grabacion.segmentos[i];
            // Se resalta el tramo que está sonando: al seguir una reunión en audio,
            // perder el renglón es lo que más molesta.
            final actual = sonandoEsta && posicion >= s.desde && posicion < s.hasta;
            return InkWell(
              onTap: () => _saltarA(context, s),
              child: Container(
                color: actual
                    ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)
                    : null,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 68,
                      child: Text(
                        s.horaDelDiaLegible(grabacion.grabadaEn),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                      ),
                    ),
                    Expanded(
                      child: Text(s.texto, style: const TextStyle(height: 1.45)),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _corrido(BuildContext context, ScrollController scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.all(20),
        children: [
          SelectableText(
            grabacion.transcripcion ?? '',
            style: const TextStyle(height: 1.5),
          ),
          const SizedBox(height: 16),
          Text(
            'Esta transcripción no tiene marcas de tiempo: se hizo antes de que la app '
            'las generara, o el motor no las devolvió.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      );

  Future<void> _saltarA(BuildContext context, Segmento s) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!reproductor.estaCargada(grabacion.id)) {
      final error = await reproductor.alternar(grabacion.id, grabacion.rutaArchivo);
      if (error != null) {
        messenger.showSnackBar(SnackBar(content: Text(error)));
        return;
      }
    }
    await reproductor.irA(s.desde);
  }
}
