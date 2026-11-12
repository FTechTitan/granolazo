import 'package:flutter/material.dart';

import '../services/detector_reuniones.dart';

/// La ventana chica que asoma cuando parece que empezó una reunión.
///
/// **Sutil es un requisito, no un adorno.** Si esto interrumpe, la primera reacción va a
/// ser desactivar la detección entera y el resto deja de servir. Por eso: aparece abajo a
/// la derecha, sin robar el foco, con una sola acción obvia, y con la salida a mano —tanto
/// "ahora no" como "no me preguntes más por esta aplicación".
class AvisoReunion extends StatelessWidget {
  const AvisoReunion({
    super.key,
    required this.app,
    required this.alGrabar,
    required this.alDescartar,
    required this.alIgnorarApp,
  });

  final AppEnLlamada app;
  final VoidCallback alGrabar;
  final VoidCallback alDescartar;
  final VoidCallback alIgnorarApp;

  /// Tamaño de la ventana cuando se muestra el aviso.
  /// Alto pensado para el peor caso: un nombre de aplicación largo que hace envolver
  /// el texto en dos líneas. Con "Discord" sobra espacio; con uno largo, entra igual.
  static const Size tamano = Size(470, 262);

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    return Material(
      color: colores.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.graphic_eq, size: 18, color: colores.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '¿Grabo esta reunión?',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  iconSize: 18,
                  tooltip: 'Ahora no',
                  icon: const Icon(Icons.close),
                  onPressed: alDescartar,
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '${app.nombre} está usando el micrófono.',
              style: Theme.of(context).textTheme.bodyMedium,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              'Graba tu voz y lo que suena en el equipo. Queda en espera hasta que pidas '
              'transcribirla.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colores.onSurfaceVariant,
                  ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const Spacer(),
            Row(
              children: [
                // Flexible y con puntos suspensivos: la ventana es de tamaño fijo y este
                // es el texto que puede crecer. Sin esto la fila desborda y el botón de
                // Grabar queda cortado contra el borde.
                Flexible(
                  child: TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: alIgnorarApp,
                    child: const Text(
                      'Nunca esta app',
                      style: TextStyle(fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const Spacer(),
                TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: Size.zero,
                  ),
                  onPressed: alDescartar,
                  child: const Text('Ahora no'),
                ),
                const SizedBox(width: 6),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  onPressed: alGrabar,
                  icon: const Icon(Icons.fiber_manual_record, size: 15),
                  label: const Text('Grabar'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
