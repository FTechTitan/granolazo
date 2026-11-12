import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/grabaciones_controller.dart';
import '../models/grabacion.dart';
import '../services/reproductor_service.dart';
import 'hoja_transcripcion.dart';
import 'reproductor_barra.dart';

/// Una fila de la lista de grabaciones, con su estado y acciones.
class TarjetaGrabacion extends StatelessWidget {
  const TarjetaGrabacion({
    super.key,
    required this.grabacion,
    required this.controller,
    required this.reproductor,
  });

  final Grabacion grabacion;
  final GrabacionesController controller;
  final ReproductorService reproductor;

  Color _colorEstado(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return switch (grabacion.estado) {
      EstadoGrabacion.lista => cs.primary,
      EstadoGrabacion.error => cs.error,
      _ => cs.tertiary,
    };
  }

  IconData get _icono => switch (grabacion.estado) {
        EstadoGrabacion.enEspera => Icons.pause_circle_outline,
        EstadoGrabacion.lista => Icons.check_circle_outline,
        EstadoGrabacion.error => Icons.error_outline,
        EstadoGrabacion.transcribiendo => Icons.graphic_eq,
        EstadoGrabacion.subiendo => Icons.cloud_upload_outlined,
        _ => Icons.schedule,
      };

  @override
  Widget build(BuildContext context) {
    final g = grabacion;
    final subtitulo = StringBuffer()
      ..write(_fecha(g.grabadaEn))
      ..write('  ·  ')
      ..write(g.duracionLegible);
    if (g.importada) subtitulo.write('  ·  importada');

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _fila(context, g, subtitulo),
        ReproductorBarra(grabacion: g, reproductor: reproductor),
      ],
    );
  }

  Widget _fila(BuildContext context, Grabacion g, StringBuffer subtitulo) {
    return ListTile(
      title: Text(g.tituloVisible, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(subtitulo.toString()),
          if (g.estado.enProceso) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: g.progreso > 0 ? g.progreso / 100 : null,
              minHeight: 3,
            ),
          ],
          if (g.estado == EstadoGrabacion.error && g.mensajeError != null) ...[
            const SizedBox(height: 4),
            Text(
              g.mensajeError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12),
            ),
          ],
          if (g.estado == EstadoGrabacion.lista && g.itemIdRemoto != null) ...[
            const SizedBox(height: 4),
            Text('en Granolazo', style: Theme.of(context).textTheme.labelSmall),
          ],
        ],
      ),
      isThreeLine: g.estado == EstadoGrabacion.error || g.estado.enProceso,
      leading: _BotonEscuchar(
        grabacion: g,
        reproductor: reproductor,
        color: _colorEstado(context),
        icono: _icono,
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (v) => _accion(context, v),
        itemBuilder: (_) => [
          if (g.transcripcion != null)
            const PopupMenuItem(value: 'ver', child: Text('Ver transcripción')),
          if (g.transcripcion != null)
            const PopupMenuItem(value: 'copiar', child: Text('Copiar texto')),
          if (g.transcripcion != null)
            const PopupMenuItem(value: 'exportar', child: Text('Guardar como texto')),
          if (g.estado == EstadoGrabacion.enEspera)
            const PopupMenuItem(
                value: 'transcribir', child: Text('Transcribir ahora')),
          if (g.estado == EstadoGrabacion.error)
            const PopupMenuItem(value: 'reintentar', child: Text('Reintentar')),
          const PopupMenuItem(value: 'eliminar', child: Text('Eliminar')),
        ],
      ),
      onTap: g.transcripcion != null ? () => _verTexto(context) : null,
    );
  }

  String _fecha(DateTime d) {
    final l = d.toLocal();
    final dd = l.day.toString().padLeft(2, '0');
    final mm = l.month.toString().padLeft(2, '0');
    final hh = l.hour.toString().padLeft(2, '0');
    final mi = l.minute.toString().padLeft(2, '0');
    return '$dd-$mm-${l.year} $hh:$mi';
  }

  Future<void> _accion(BuildContext context, String valor) async {
    final messenger = ScaffoldMessenger.of(context);
    switch (valor) {
      case 'ver':
        _verTexto(context);
      case 'copiar':
        await Clipboard.setData(ClipboardData(text: grabacion.textoConMarcas));
        messenger.showSnackBar(const SnackBar(content: Text('texto copiado')));
      case 'exportar':
        final f = await controller.exportar(grabacion);
        messenger.showSnackBar(SnackBar(
          content: Text(f == null ? 'no había texto que guardar' : 'guardado junto al audio'),
        ));
      case 'transcribir':
        await controller.transcribirAhora(grabacion);
      case 'reintentar':
        await controller.reintentar(grabacion);
      case 'eliminar':
        await controller.eliminar(grabacion);
        messenger.showSnackBar(const SnackBar(content: Text('grabación eliminada')));
    }
  }

  void _verTexto(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => HojaTranscripcion(
        grabacion: grabacion,
        reproductor: reproductor,
      ),
    );
  }
}


/// Reproduce la grabación, o muestra su estado cuando el audio ya no está.
///
/// Ocupa el lugar donde antes había solo un icono de estado: delante de un audio, lo que
/// uno quiere tocar es escucharlo. El estado sigue estando, en el color y en el icono de
/// reposo.
class _BotonEscuchar extends StatelessWidget {
  const _BotonEscuchar({
    required this.grabacion,
    required this.reproductor,
    required this.color,
    required this.icono,
  });

  final Grabacion grabacion;
  final ReproductorService reproductor;
  final Color color;
  final IconData icono;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: reproductor,
      builder: (context, _) {
        final sonando = reproductor.estaSonando(grabacion.id);
        final cargada = reproductor.estaCargada(grabacion.id);
        return Tooltip(
          message: sonando ? 'Pausar' : 'Escuchar',
          child: IconButton(
            iconSize: 28,
            color: color,
            icon: Icon(
              sonando
                  ? Icons.pause_circle_filled
                  : (cargada ? Icons.play_circle_fill : Icons.play_circle_outline),
            ),
            onPressed: () async {
              final error =
                  await reproductor.alternar(grabacion.id, grabacion.rutaArchivo);
              if (error != null && context.mounted) {
                ScaffoldMessenger.of(context)
                  ..clearSnackBars()
                  ..showSnackBar(SnackBar(content: Text(error)));
              }
            },
          ),
        );
      },
    );
  }
}
