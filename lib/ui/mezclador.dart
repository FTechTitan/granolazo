import 'package:flutter/material.dart';

import '../controllers/grabaciones_controller.dart';
import 'medidor_nivel.dart';

/// Las dos fuentes de la grabación, con su nivel y su volumen.
///
/// Las dos rara vez entran parejas: en una llamada, el otro sale por los parlantes a un
/// volumen y uno habla al micrófono a otro. Si una tapa a la otra, la transcripción pierde
/// media conversación. Por eso cada una tiene su control, y el medidor muestra **cómo va a
/// quedar en la mezcla**, no el nivel crudo: es lo único que sirve para emparejarlas.
class Mezclador extends StatelessWidget {
  const Mezclador({super.key, required this.controller});

  final GrabacionesController controller;

  @override
  Widget build(BuildContext context) {
    final puedeSistema = controller.puedeCapturarSistema;
    final sinNada = controller.grabando &&
        controller.nivelMicrofonoConGanancia <= -70 &&
        (!puedeSistema || controller.nivelSistemaConGanancia <= -70);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Fuente(
          etiqueta: 'Micrófono',
          icono: Icons.mic,
          nivel: controller.nivelMicrofonoConGanancia,
          ganancia: controller.gananciaMicrofono,
          activa: controller.grabando,
          alCambiar: controller.cambiarGananciaMicrofono,
        ),
        if (puedeSistema) ...[
          const SizedBox(height: 4),
          _Fuente(
            etiqueta: 'Equipo',
            icono: Icons.volume_up,
            nivel: controller.nivelSistemaConGanancia,
            ganancia: controller.gananciaSistema,
            activa: controller.grabando,
            alCambiar: controller.cambiarGananciaSistema,
          ),
        ],
        if (!puedeSistema)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'En esta plataforma todavía no se captura el audio del equipo',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        // Decirlo acá y no en una nota escondida: es la diferencia entre entender por qué
        // una llamada quedó con una sola voz y creer que la app está fallando.
        if (puedeSistema && !controller.capturaLlamadas)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Android no deja grabar la voz del otro en una llamada. Esto toma videos y '
              'lo que se reproduzca; para una llamada, pon el altavoz y entra por el '
              'micrófono.',
              style: Theme.of(context).textTheme.labelSmall,
              textAlign: TextAlign.center,
            ),
          ),
        if (sinNada)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'No entra sonido por ninguna de las dos',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
      ],
    );
  }
}

class _Fuente extends StatelessWidget {
  const _Fuente({
    required this.etiqueta,
    required this.icono,
    required this.nivel,
    required this.ganancia,
    required this.activa,
    required this.alCambiar,
  });

  final String etiqueta;
  final IconData icono;
  final double nivel;
  final double ganancia;
  final bool activa;
  final Future<void> Function(double) alCambiar;

  /// Tope del control. Triplicar es mucho y ya mete ruido de fondo; más que eso no
  /// arregla un audio malo, lo empeora.
  static const double maximo = 3.0;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icono, size: 16, color: colores.onSurfaceVariant),
        const SizedBox(width: 6),
        SizedBox(
          width: 104,
          child: Text(
            etiqueta,
            style: Theme.of(context).textTheme.labelMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        MedidorNivel(nivelDbfs: activa ? nivel : -160, compacto: true),
        const SizedBox(width: 10),
        SizedBox(
          width: 150,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: Slider(
              value: ganancia.clamp(0.0, maximo),
              max: maximo,
              divisions: 30,
              onChanged: (v) => alCambiar(v),
            ),
          ),
        ),
        SizedBox(
          width: 46,
          child: Text(
            '${(ganancia * 100).round()}%',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: (ganancia - 1).abs() < 0.01
                      ? colores.onSurfaceVariant
                      : colores.primary,
                ),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }
}
