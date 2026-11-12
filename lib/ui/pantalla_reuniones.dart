import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/item_granolazo.dart';
import '../services/granolazo_api.dart';
import 'pantalla_transcripcion.dart';

/// Las reuniones que hay en Granolazo, vengan de donde vengan.
///
/// A diferencia del panel web, que se trae la tabla entera y filtra en el navegador, acá
/// se filtra y se pagina contra el servidor: la misma app corre en un celular y el
/// listado ya trae los resúmenes de todo.
class PantallaReuniones extends StatefulWidget {
  const PantallaReuniones({super.key, required this.api});

  final GranolazoApi api;

  @override
  State<PantallaReuniones> createState() => _PantallaReunionesState();
}

class _PantallaReunionesState extends State<PantallaReuniones> {
  final _busqueda = TextEditingController();
  FiltroItems _filtro = const FiltroItems();
  List<ItemGranolazo> _items = const [];
  OpcionesDeFiltro? _opciones;
  bool _cargando = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cargar();
    _cargarOpciones();
  }

  @override
  void dispose() {
    _busqueda.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      final items = await widget.api.buscarItems(_filtro);
      if (mounted) setState(() => _items = items);
    } on ErrorGranolazo catch (e) {
      if (mounted) setState(() => _error = e.mensaje);
    } catch (e) {
      if (mounted) setState(() => _error = 'no pude leer las reuniones: $e');
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _cargarOpciones() async {
    try {
      final o = await widget.api.opcionesDeFiltro();
      if (mounted) setState(() => _opciones = o);
    } catch (_) {
      // Sin opciones se puede buscar igual por texto: no vale la pena molestar con esto.
    }
  }

  void _aplicar(FiltroItems nuevo) {
    setState(() => _filtro = nuevo);
    _cargar();
  }

  void _limpiar() {
    _busqueda.clear();
    _aplicar(const FiltroItems());
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _barraDeFiltros(context),
        const Divider(height: 1),
        Expanded(child: _cuerpo(context)),
      ],
    );
  }

  Widget _barraDeFiltros(BuildContext context) {
    final o = _opciones;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _busqueda,
                  decoration: InputDecoration(
                    hintText: 'Buscar en título, grupo o resumen',
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                    border: const OutlineInputBorder(),
                    suffixIcon: _busqueda.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              _busqueda.clear();
                              _aplicar(_filtro.copyWith(texto: null));
                            },
                          ),
                  ),
                  onSubmitted: (v) =>
                      _aplicar(_filtro.copyWith(texto: v.trim().isEmpty ? null : v.trim())),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Actualizar',
                onPressed: _cargando ? null : _cargar,
              ),
            ],
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _menu(
                  etiqueta: 'Grupo',
                  valor: _filtro.grupo,
                  opciones: o?.grupos ?? const [],
                  alElegir: (v) => _aplicar(_filtro.copyWith(grupo: v)),
                ),
                _menu(
                  etiqueta: 'Fuente',
                  valor: _filtro.fuente,
                  opciones: o?.fuentes ?? const [],
                  alElegir: (v) => _aplicar(_filtro.copyWith(fuente: v)),
                ),
                _menu(
                  etiqueta: 'Tag',
                  valor: _filtro.tag,
                  opciones: o?.tags ?? const [],
                  alElegir: (v) => _aplicar(_filtro.copyWith(tag: v)),
                ),
                _menu(
                  etiqueta: 'Estado',
                  valor: _filtro.estado,
                  opciones: const ['transcribed', 'pending', 'error'],
                  etiquetas: const {
                    'transcribed': 'Transcritas',
                    'pending': 'Pendientes',
                    'error': 'Con error',
                  },
                  alElegir: (v) => _aplicar(_filtro.copyWith(estado: v)),
                ),
                if (_filtro.hayAlguno)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: TextButton.icon(
                      icon: const Icon(Icons.filter_alt_off, size: 18),
                      label: const Text('Limpiar'),
                      onPressed: _limpiar,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _menu({
    required String etiqueta,
    required String? valor,
    required List<String> opciones,
    Map<String, String>? etiquetas,
    required void Function(String?) alElegir,
  }) {
    final activo = valor != null;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: PopupMenuButton<String?>(
        tooltip: etiqueta,
        onSelected: alElegir,
        itemBuilder: (_) => [
          const PopupMenuItem<String?>(value: null, child: Text('Todos')),
          for (final op in opciones)
            PopupMenuItem<String?>(value: op, child: Text(etiquetas?[op] ?? op)),
        ],
        child: Chip(
          avatar: Icon(activo ? Icons.check : Icons.arrow_drop_down, size: 18),
          label: Text(activo ? (etiquetas?[valor] ?? valor) : etiqueta),
        ),
      ),
    );
  }

  Widget _cuerpo(BuildContext context) {
    if (_cargando && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
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
    if (_items.isEmpty) {
      return Center(
        child: Text(_filtro.hayAlguno
            ? 'Ninguna reunión coincide con ese filtro'
            : 'Todavía no hay reuniones en Granolazo'),
      );
    }
    return RefreshIndicator(
      onRefresh: _cargar,
      child: ListView.separated(
        itemCount: _items.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, i) => _fila(context, _items[i]),
      ),
    );
  }

  Widget _fila(BuildContext context, ItemGranolazo item) {
    final colores = Theme.of(context).colorScheme;
    final fecha = item.fecha;
    final cuando = fecha == null
        ? 'sin fecha'
        : '${fecha.day.toString().padLeft(2, '0')}/'
            '${fecha.month.toString().padLeft(2, '0')}/${fecha.year}';

    return ListTile(
      leading: Icon(
        item.transcrita
            ? Icons.check_circle
            : (item.conError ? Icons.error : Icons.hourglass_empty),
        color: item.transcrita
            ? Colors.green
            : (item.conError ? colores.error : colores.onSurfaceVariant),
      ),
      title: Text(item.tituloVisible, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$cuando · ${item.duracionLegible} · ${item.fuente ?? "sin fuente"}'
              '${item.grupo != null ? " · ${item.grupo}" : ""}'),
          if (item.mensajeError != null)
            Text(item.mensajeError!,
                style: TextStyle(color: colores.error), maxLines: 1),
          if (item.tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 4,
                runSpacing: -8,
                children: [
                  for (final t in item.tags.take(6))
                    InputChip(
                      label: Text(t, style: const TextStyle(fontSize: 11)),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _aplicar(_filtro.copyWith(tag: t)),
                    ),
                ],
              ),
            ),
        ],
      ),
      isThreeLine: item.tags.isNotEmpty || item.mensajeError != null,
      trailing: IconButton(
        icon: const Icon(Icons.copy),
        tooltip: 'Copiar el identificador',
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: item.id));
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('identificador copiado')),
            );
          }
        },
      ),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PantallaTranscripcion(api: widget.api, item: item),
      )),
    );
  }
}
