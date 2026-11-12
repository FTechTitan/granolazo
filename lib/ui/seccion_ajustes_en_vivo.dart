import 'package:flutter/material.dart';

import '../en_vivo/coordinador_en_vivo.dart';
import '../en_vivo/motor_en_vivo.dart';
import '../services/ajustes_service.dart';

/// Ajustes de la transcripción en vivo. Autónoma: lee y guarda por su cuenta para no
/// engordar la pantalla de ajustes.
class SeccionAjustesEnVivo extends StatefulWidget {
  const SeccionAjustesEnVivo({super.key});

  @override
  State<SeccionAjustesEnVivo> createState() => _SeccionAjustesEnVivoState();
}

class _SeccionAjustesEnVivoState extends State<SeccionAjustesEnVivo> {
  final _ajustes = AjustesService();
  bool _cargado = false;
  bool _activo = false;
  ModeloEnVivo _modelo = ModeloEnVivo.base;
  int _trozo = 20;
  int _hilos = 2;
  int _puerto = 47821;
  bool _modeloListo = false;
  bool _bajando = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final c = await ConfigEnVivo.leer(_ajustes);
    final listo = await MotorEnVivoWhisper(modelo: c.modelo, hilos: c.hilos).modeloDescargado();
    if (!mounted) return;
    setState(() {
      _activo = c.activo;
      _modelo = c.modelo;
      _trozo = c.trozoSeg;
      _hilos = c.hilos;
      _puerto = c.puerto;
      _modeloListo = listo;
      _cargado = true;
    });
  }

  Future<void> _cambiarModelo(ModeloEnVivo m) async {
    await _ajustes.guardarEnVivoModelo(m.nombre);
    final listo = await MotorEnVivoWhisper(modelo: m, hilos: _hilos).modeloDescargado();
    if (!mounted) return;
    setState(() {
      _modelo = m;
      _modeloListo = listo;
    });
  }

  Future<void> _bajar() async {
    setState(() => _bajando = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await MotorEnVivoWhisper(modelo: _modelo, hilos: _hilos).descargarModelo();
      if (mounted) setState(() => _modeloListo = true);
      messenger.showSnackBar(SnackBar(content: Text('modelo ${_modelo.nombre} listo')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('no pude bajar el modelo: $e')));
    } finally {
      if (mounted) setState(() => _bajando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_cargado) return const SizedBox.shrink();
    final tema = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Transcripción en vivo', style: tema.titleMedium),
        const SizedBox(height: 4),
        SwitchListTile(
          key: const Key('ajuste-en-vivo'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Mostrar el texto mientras se graba'),
          subtitle: const Text(
              'Un borrador rápido que se ve en la ventana y que otro programa puede leer '
              '(granolazo en-vivo). Gasta procesador mientras graba. La transcripción buena '
              'sigue haciéndose al terminar, igual que siempre. No se sube a ningún servidor.'),
          value: _activo,
          onChanged: (v) async {
            setState(() => _activo = v);
            await _ajustes.guardarEnVivo(v);
          },
        ),
        if (_activo) ...[
          const SizedBox(height: 8),
          DropdownButtonFormField<ModeloEnVivo>(
            initialValue: _modelo,
            decoration: const InputDecoration(
              labelText: 'Modelo del borrador',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final m in ModeloEnVivo.values)
                DropdownMenuItem(value: m, child: Text('${m.nombre} · ${m.megas} MB')),
            ],
            onChanged: (v) => v == null ? null : _cambiarModelo(v),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                _modeloListo ? Icons.check_circle : Icons.download_for_offline,
                size: 18,
                color: _modeloListo ? Colors.green : null,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _modeloListo
                      ? 'El modelo está bajado.'
                      : 'Falta bajarlo (${_modelo.megas} MB, una sola vez). Sin él, el borrador no arranca.',
                  style: tema.bodySmall,
                ),
              ),
              if (!_modeloListo)
                FilledButton.tonal(
                  onPressed: _bajando ? null : _bajar,
                  child: _bajando
                      ? const SizedBox(
                          height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Bajar'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<int>(
                  initialValue: const [10, 15, 20, 30, 45, 60].contains(_trozo) ? _trozo : 20,
                  decoration: const InputDecoration(
                    labelText: 'Cada cuántos segundos',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final s in const [10, 15, 20, 30, 45, 60])
                      DropdownMenuItem(value: s, child: Text('$s s')),
                  ],
                  onChanged: (v) async {
                    if (v == null) return;
                    setState(() => _trozo = v);
                    await _ajustes.guardarEnVivoTrozoSeg(v);
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<int>(
                  initialValue: _hilos,
                  decoration: const InputDecoration(
                    labelText: 'Hilos de CPU',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (var n = ConfigEnVivo.hilosMin; n <= ConfigEnVivo.hilosMax; n++)
                      DropdownMenuItem(value: n, child: Text('$n')),
                  ],
                  onChanged: (v) async {
                    if (v == null) return;
                    setState(() => _hilos = v);
                    await _ajustes.guardarEnVivoHilos(v);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _puerto > 0
                ? 'Mientras graba se puede leer en http://127.0.0.1:$_puerto/en-vivo '
                    '(solo desde este mismo equipo). Cambiar el puerto: '
                    'granolazo config --en-vivo-puerto N (0 lo desactiva).'
                : 'El acceso por http://127.0.0.1 está desactivado; sigue disponible '
                    'granolazo en-vivo.',
            style: tema.bodySmall,
          ),
        ],
      ],
    );
  }
}
