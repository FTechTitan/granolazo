import 'package:flutter/material.dart';

import '../en_vivo/coordinador_en_vivo.dart';
import '../en_vivo/estado_en_vivo.dart';

/// El interruptor «Transcripción en vivo», junto al botón de grabar.
///
/// Se puede cambiar mientras no se graba: el modo se decide al empezar cada grabación.
class InterruptorEnVivo extends StatelessWidget {
  const InterruptorEnVivo({super.key, required this.coordinador, required this.grabando});

  final CoordinadorEnVivo coordinador;
  final bool grabando;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: coordinador,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: coordinador.encendido,
            onChanged: grabando ? null : coordinador.cambiarEncendido,
          ),
          const SizedBox(width: 4),
          Tooltip(
            message: grabando
                ? 'Se decide antes de empezar a grabar'
                : 'Muestra el texto mientras se graba (borrador). La transcripción final '
                    'sigue saliendo al terminar.',
            child: const Text('Transcripción en vivo'),
          ),
        ],
      ),
    );
  }
}

/// El texto del borrador saliendo mientras se graba.
///
/// Siempre dice que es un borrador: el que vale es la transcripción que se hace al
/// terminar, con más cuidado.
class PanelEnVivo extends StatefulWidget {
  const PanelEnVivo({super.key, required this.coordinador, this.alto = 220, this.expandir = false});

  final CoordinadorEnVivo coordinador;
  final double alto;

  /// Ocupa todo el espacio que le den (el alto fijo [alto] se ignora).
  final bool expandir;

  @override
  State<PanelEnVivo> createState() => _PanelEnVivoState();
}

class _PanelEnVivoState extends State<PanelEnVivo> {
  final _scroll = ScrollController();
  int _vistos = 0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  static String _hora(DateTime d) {
    final l = d.toLocal();
    String dos(int n) => n.toString().padLeft(2, '0');
    return '${dos(l.hour)}:${dos(l.minute)}:${dos(l.second)}';
  }

  /// Baja al final cuando llega texto nuevo, salvo que la persona haya subido a releer.
  void _seguirElFinal(int segmentos) {
    if (segmentos == _vistos) return;
    _vistos = segmentos;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final p = _scroll.position;
      if (p.maxScrollExtent - p.pixels < 120) {
        _scroll.animateTo(p.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.coordinador,
      builder: (context, _) {
        final c = widget.coordinador;
        final e = c.estado;
        if (!c.activo) return const SizedBox.shrink();
        _seguirElFinal(e?.segmentos.length ?? 0);
        final atrasado = e != null && e.rezagoSeg > e.trozoSeg * 2.5;
        return Container(
          key: const Key('panel-en-vivo'),
          constraints: const BoxConstraints(maxWidth: 720),
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          decoration: BoxDecoration(
            border: Border.all(color: colores.outlineVariant),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: widget.expandir ? MainAxisSize.max : MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Row(
                  children: [
                    Icon(Icons.subtitles_outlined, size: 18, color: colores.primary),
                    const SizedBox(width: 8),
                    Text('Transcripción en vivo',
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(width: 8),
                    Chip(
                      label: const Text('borrador'),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      labelStyle: Theme.of(context).textTheme.labelSmall,
                    ),
                    const Spacer(),
                    if (e != null)
                      Text(
                        e.finalizando
                            ? 'terminando…'
                            : 'actualizado ${_hora(e.ultimaActualizacion)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              _CuerpoTexto(
                expandir: widget.expandir,
                alto: widget.alto,
                child: (e == null || e.segmentos.isEmpty)
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            e == null
                                ? (c.aviso ?? 'Preparando…')
                                : 'Esperando las primeras palabras… (el texto aparece cada '
                                    '${e.trozoSeg} s más o menos)',
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(color: colores.onSurfaceVariant),
                          ),
                        ),
                      )
                    : Scrollbar(
                        controller: _scroll,
                        child: ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.all(12),
                          itemCount: e.segmentos.length,
                          itemBuilder: (_, i) {
                            final s = e.segmentos[i];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: SelectableText.rich(TextSpan(children: [
                                TextSpan(
                                  text: '${_marca(s)}  ',
                                  style: TextStyle(
                                    color: colores.onSurfaceVariant,
                                    fontFeatures: const [FontFeature.tabularFigures()],
                                  ),
                                ),
                                TextSpan(text: s.texto),
                              ])),
                            );
                          },
                        ),
                      ),
              ),
              if (atrasado || c.aviso != null)
                Container(
                  color: colores.tertiaryContainer,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Text(
                    [
                      if (atrasado)
                        'El borrador va ${e.rezagoSeg.round()} s atrasado: este equipo no da '
                            'abasto con el modelo ${e.modelo}.',
                      if (c.aviso != null) c.aviso!,
                    ].join(' '),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Text(
                  'Es un borrador rápido y puede tener errores. La transcripción buena se '
                  'hace al terminar la grabación.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: colores.onSurfaceVariant),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static String _marca(SegmentoEnVivo s) {
    final t = s.desdeSeg.floor();
    final h = t ~/ 3600;
    final m = ((t % 3600) ~/ 60).toString().padLeft(2, '0');
    final seg = (t % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$seg' : '$m:$seg';
  }
}

/// El área del texto: de alto fijo, o estirada para llenar el panel.
class _CuerpoTexto extends StatelessWidget {
  const _CuerpoTexto({required this.expandir, required this.alto, required this.child});

  final bool expandir;
  final double alto;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      expandir ? Expanded(child: child) : SizedBox(height: alto, child: child);
}
