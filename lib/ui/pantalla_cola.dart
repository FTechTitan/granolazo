import 'dart:async';

import 'package:flutter/material.dart';

import '../models/item_granolazo.dart';
import '../services/granolazo_api.dart';

/// La cola del pipeline de Granolazo: qué se está transcribiendo, qué espera y qué falló.
///
/// Es la cola del backend, no la de este dispositivo. Se lee igual que en el panel web: un
/// item `pending` que ya tiene `proc_started_at` es uno que un worker tomó y está
/// procesando; sin eso, espera turno.
class PantallaCola extends StatefulWidget {
  const PantallaCola({super.key, required this.api});

  final GranolazoApi api;

  @override
  State<PantallaCola> createState() => _PantallaColaState();
}

class _PantallaColaState extends State<PantallaCola> {
  EstadoCola? _cola;
  bool _cargando = true;
  String? _error;
  Timer? _refresco;

  @override
  void initState() {
    super.initState();
    _cargar();
    // Mientras la pantalla esté abierta se refresca sola. Medio minuto alcanza: una
    // transcripción tarda más o menos lo que dura el audio, no hay nada que ver cada
    // segundo, y así no se castiga la batería de un celular.
    _refresco = Timer.periodic(const Duration(seconds: 30), (_) => _cargar());
  }

  @override
  void dispose() {
    _refresco?.cancel();
    super.dispose();
  }

  Future<void> _cargar() async {
    if (!mounted) return;
    setState(() => _error = null);
    try {
      final c = await widget.api.estadoDeLaCola();
      if (mounted) setState(() => _cola = c);
    } on ErrorGranolazo catch (e) {
      if (mounted) setState(() => _error = e.mensaje);
    } catch (e) {
      if (mounted) setState(() => _error = 'no pude leer la cola: $e');
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_cargando && _cola == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null && _cola == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 40),
              const SizedBox(height: 12),
              Text(error, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _cargar, child: const Text('Reintentar')),
            ],
          ),
        ),
      );
    }

    final cola = _cola!;
    if (cola.total == 0) {
      return RefreshIndicator(
        onRefresh: _cargar,
        child: ListView(
          children: const [
            SizedBox(height: 120),
            Icon(Icons.check_circle_outline, size: 48),
            SizedBox(height: 12),
            Center(child: Text('La cola está vacía')),
            SizedBox(height: 4),
            Center(child: Text('No hay nada pendiente ni fallado')),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _cargar,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _resumen(context, cola),
          if (cola.procesando.isNotEmpty) ...[
            _titulo(context, 'Transcribiendo ahora', cola.procesando.length),
            for (final i in cola.procesando) _filaEnProceso(context, i),
          ],
          if (cola.esperando.isNotEmpty) ...[
            _titulo(context, 'Esperando turno', cola.esperando.length),
            for (final i in cola.esperando) _fila(context, i),
          ],
          if (cola.conError.isNotEmpty) ...[
            _titulo(context, 'Con error', cola.conError.length),
            for (final i in cola.conError) _filaConError(context, i),
          ],
        ],
      ),
    );
  }

  Widget _resumen(BuildContext context, EstadoCola cola) {
    final minutos = cola.esperaEstimada.inMinutes;
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(child: _dato(context, '${cola.procesando.length}', 'procesando')),
            Expanded(child: _dato(context, '${cola.esperando.length}', 'esperando')),
            Expanded(child: _dato(context, '${cola.conError.length}', 'con error')),
            Expanded(
              child: _dato(
                context,
                minutos >= 60 ? '${(minutos / 60).toStringAsFixed(1)} h' : '$minutos min',
                'falta, más o menos',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dato(BuildContext context, String valor, String etiqueta) => Column(
        children: [
          Text(valor, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 2),
          Text(etiqueta,
              style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
        ],
      );

  Widget _titulo(BuildContext context, String texto, int cuantos) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text('$texto ($cuantos)',
            style: Theme.of(context).textTheme.titleSmall),
      );

  Widget _filaEnProceso(BuildContext context, ItemGranolazo i) => ListTile(
        leading: SizedBox(
          width: 40,
          height: 40,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: i.progreso > 0 ? i.progreso / 100 : null,
                strokeWidth: 3,
              ),
              Text('${i.progreso}', style: const TextStyle(fontSize: 10)),
            ],
          ),
        ),
        title: Text(i.tituloVisible, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text('${i.duracionLegible} · ${i.fuente ?? "sin fuente"}'
            '${i.estadoOpenai == "running" ? " · por el servicio rápido" : ""}'),
      );

  Widget _fila(BuildContext context, ItemGranolazo i) => ListTile(
        leading: Icon(i.pausada ? Icons.pause_circle_outline : Icons.schedule),
        title: Text(i.tituloVisible, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text('${i.duracionLegible} · ${i.fuente ?? "sin fuente"}'
            '${i.pausada ? " · en pausa" : ""}'),
      );

  Widget _filaConError(BuildContext context, ItemGranolazo i) => ListTile(
        leading: Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
        title: Text(i.tituloVisible, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(i.mensajeError ?? 'sin detalle del error'),
      );
}
