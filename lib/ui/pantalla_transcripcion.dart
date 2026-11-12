import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/item_granolazo.dart';
import '../services/granolazo_api.dart';

/// Lee una reunión: su transcripción literal y su resumen.
///
/// Las dos cosas se muestran en pestañas separadas y bien rotuladas. No es un detalle
/// estético: las reuniones que entran por las notas de Gemini de Meet a veces traen solo
/// el resumen, y confundirlo con la transcripción lleva a citar como dicho algo que nadie
/// dijo.
class PantallaTranscripcion extends StatefulWidget {
  const PantallaTranscripcion({super.key, required this.api, required this.item});

  final GranolazoApi api;
  final ItemGranolazo item;

  @override
  State<PantallaTranscripcion> createState() => _PantallaTranscripcionState();
}

class _PantallaTranscripcionState extends State<PantallaTranscripcion> {
  TextoDeReunion? _texto;
  bool _cargando = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      // El texto no viaja en el listado: pesa y solo hace falta al abrir una reunión.
      final t = await widget.api.textoDe(widget.item.id);
      if (mounted) setState(() => _texto = t);
    } on ErrorGranolazo catch (e) {
      if (mounted) setState(() => _error = e.mensaje);
    } catch (e) {
      if (mounted) setState(() => _error = 'no pude leer la reunión: $e');
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _texto;
    final hayTranscripcion = t?.hayTranscripcion ?? false;
    final hayResumen = t?.hayResumen ?? false;
    final pestanas = <String>[
      if (hayTranscripcion) 'Transcripción',
      if (hayResumen) 'Resumen',
    ];

    return DefaultTabController(
      length: pestanas.isEmpty ? 1 : pestanas.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.item.tituloVisible, maxLines: 2),
          bottom: pestanas.length > 1
              ? TabBar(tabs: [for (final p in pestanas) Tab(text: p)])
              : null,
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Actualizar',
              onPressed: _cargando ? null : _cargar,
            ),
          ],
        ),
        body: _cuerpo(context, pestanas),
      ),
    );
  }

  Widget _cuerpo(BuildContext context, List<String> pestanas) {
    if (_cargando) return const Center(child: CircularProgressIndicator());

    final error = _error;
    if (error != null) {
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

    final t = _texto;
    if (t == null || !t.hayAlgo) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.pending_outlined, size: 40),
              const SizedBox(height: 12),
              Text(
                widget.item.conError
                    ? 'Esta reunión falló al transcribirse:\n'
                        '${widget.item.mensajeError ?? "sin detalle"}'
                    : 'Todavía no tiene transcripción ni resumen.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return TabBarView(
      children: [
        if (t.hayTranscripcion) _texto1(context, t.transcripcion!, 'la transcripción'),
        if (t.hayResumen) _texto1(context, t.resumen!, 'el resumen'),
      ],
    );
  }

  Widget _texto1(BuildContext context, String contenido, String queEs) {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SelectableText(contenido, style: const TextStyle(height: 1.5)),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Text('${contenido.length} caracteres',
                  style: Theme.of(context).textTheme.bodySmall),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copiar'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: contenido));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('$queEs copiada')),
                    );
                  }
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}
