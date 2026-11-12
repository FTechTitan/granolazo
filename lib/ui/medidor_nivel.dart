import 'package:flutter/material.dart';

import '../services/grabador_service.dart';

/// Muestra si el micrófono está entregando sonido, mientras se graba.
///
/// Existe por un caso concreto: el 2026-09-18 una grabación de 32 segundos salió en
/// silencio digital porque el micrófono estaba silenciado por hardware, y la app no dio
/// ninguna señal. Después se transcribió ese silencio, el modelo inventó "[Música]" y eso
/// llegó a Granolazo como si fuera una reunión.
///
/// La lección no es "avisar al final": es que **mientras se graba se tiene que ver que
/// entra sonido**. Un aviso a los 32 segundos ya perdió los 32 segundos.
class MedidorNivel extends StatelessWidget {
  const MedidorNivel({
    super.key,
    required this.nivelDbfs,
    this.compacto = false,
    this.etiqueta,
    this.textoSinSonido,
  });

  /// Qué decir cuando no entra nada por esta fuente.
  final String? textoSinSonido;

  /// Nivel de entrada en dBFS: 0 es el máximo y los valores son negativos.
  final double nivelDbfs;

  final bool compacto;

  /// De dBFS a una fracción de 0 a 1 para dibujar.
  ///
  /// Se recorta en -60 dBFS: por debajo de eso no hay nada audible y estirar la escala
  /// hasta el silencio digital (-160) dejaría la barra pegada al cero siempre.
  double get _fraccion {
    const piso = -60.0;
    if (nivelDbfs <= piso) return 0;
    if (nivelDbfs >= 0) return 1;
    return (nivelDbfs - piso) / -piso;
  }

  bool get _hayNada => nivelDbfs <= GrabadorService.umbralDeSilencio;

  /// Etiqueta de la fuente, cuando se muestran las dos.
  final String? etiqueta;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    final f = _fraccion;
    final color = _hayNada
        ? colores.error
        : (f > 0.9 ? Colors.orange : colores.primary);

    final barra = LayoutBuilder(
      builder: (context, caja) {
        const barras = 24;
        final encendidas = (f * barras).round();
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < barras; i++)
              Container(
                width: compacto ? 3 : 5,
                height: compacto ? 10 : 6 + (i / barras) * 18,
                margin: const EdgeInsets.symmetric(horizontal: 1.5),
                decoration: BoxDecoration(
                  color: i < encendidas
                      ? color
                      : colores.onSurfaceVariant.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
          ],
        );
      },
    );

    if (compacto) {
      final e = etiqueta;
      if (e == null) return barra;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 78,
            child: Text(
              e,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: _hayNada ? colores.onSurfaceVariant : colores.onSurface,
                  ),
              textAlign: TextAlign.right,
            ),
          ),
          const SizedBox(width: 8),
          barra,
          const SizedBox(width: 8),
          SizedBox(
            width: 92,
            child: Text(
              _hayNada ? 'sin sonido' : '${nivelDbfs.toStringAsFixed(0)} dB',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: _hayNada ? colores.onSurfaceVariant : colores.primary,
                  ),
            ),
          ),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(height: 28, child: barra),
        const SizedBox(height: 6),
        Text(
          _hayNada
              ? (textoSinSonido ??
                  'No se escucha nada: revisa que el micrófono no esté silenciado')
              : 'Entrando sonido · ${nivelDbfs.toStringAsFixed(0)} dB',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: _hayNada ? colores.error : colores.onSurfaceVariant,
                fontWeight: _hayNada ? FontWeight.w600 : null,
              ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
