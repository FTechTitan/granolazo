import 'package:flutter/material.dart';

import '../config/granolazo_config.dart';
import '../controllers/grabaciones_controller.dart';
import '../services/ajustes_service.dart';
import '../services/reproductor_service.dart';
import 'pantalla_ajustes.dart';
import 'mezclador.dart';
import 'panel_en_vivo.dart';
import 'tarjeta_grabacion.dart';

/// Pantalla principal: grabar, ver la cola y abrir ajustes.
class PantallaInicio extends StatefulWidget {
  const PantallaInicio({
    super.key,
    required this.controller,
    required this.reproductor,
    this.conArmazon = true,
  });

  final GrabacionesController controller;
  final ReproductorService reproductor;

  /// Con `false` no dibuja su propia barra ni su Scaffold: la está conteniendo el
  /// armazón de la app, que ya tiene navegación y acciones propias.
  final bool conArmazon;

  @override
  State<PantallaInicio> createState() => _PantallaInicioState();
}

class _PantallaInicioState extends State<PantallaInicio> {
  final _ajustes = AjustesService();

  /// ¿Se puede transcribir ahora mismo? Con el motor local es que el modelo esté bajado;
  /// con el servicio en línea, que haya clave. Lo que importa mostrar es esto, no si hay
  /// clave: desde que se transcribe en el propio equipo, la clave puede no hacer falta.
  bool _listoParaTranscribir = true;
  String _motor = 'local';

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_alCambiar);
    _revisarClave();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_alCambiar);
    super.dispose();
  }

  Future<void> _revisarClave() async {
    final listo = await widget.controller.listoParaTranscribir;
    final motor = await _ajustes.leerMotorTranscripcion();
    if (mounted) {
      setState(() {
        _listoParaTranscribir = listo;
        _motor = motor;
      });
    }
  }

  void _alCambiar() {
    final aviso = widget.controller.aviso;
    if (aviso != null && mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(aviso)));
      widget.controller.limpiarAviso();
    }
  }

  Future<void> _abrirAjustes() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PantallaAjustes(controller: widget.controller),
    ));
    await _revisarClave();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final cuerpo = ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        if (c.cargando) {
          return const Center(child: CircularProgressIndicator());
        }
        return Column(
          children: [
            if (!GranolazoConfig.isConfigured)
              _Banner(
                icono: Icons.cloud_off_outlined,
                texto: 'La app se compiló sin la clave del backend. '
                    'Las grabaciones se transcriben pero no se suben.',
                color: Theme.of(context).colorScheme.errorContainer,
              ),
            if (!_listoParaTranscribir)
              _Banner(
                icono: Icons.key_off_outlined,
                texto: _motor == 'api'
                    ? 'Falta la clave del servicio de transcripción. '
                        'Entra a Ajustes para agregarla.'
                    : 'Falta bajar el modelo para transcribir en este equipo. '
                        'Entra a Ajustes para bajarlo.',
                color: Theme.of(context).colorScheme.tertiaryContainer,
                alTocar: _abrirAjustes,
              ),
            _PanelGrabacion(controller: c),
            const Divider(height: 1),
            // Mientras corre el borrador, el texto ocupa el lugar de la cola: no hay nada
            // que mirar en ella hasta que termine la grabación.
            Expanded(
              child: ListenableBuilder(
                listenable: c.enVivo,
                builder: (context, _) => Column(
                  children: [
                    if (c.grabando && !c.enVivo.activo && c.enVivo.aviso != null)
                      _Banner(
                        icono: Icons.subtitles_off_outlined,
                        texto: c.enVivo.aviso!,
                        color: Theme.of(context).colorScheme.tertiaryContainer,
                      ),
                    Expanded(
                      child: c.enVivo.activo
                          ? PanelEnVivo(coordinador: c.enVivo, expandir: true)
                          : _Lista(controller: c, reproductor: widget.reproductor),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );

    if (!widget.conArmazon) {
      // Embebida: la barra de acciones la pone el armazón, salvo importar, que es
      // propio de esta sección y se ofrece como botón flotante.
      return Scaffold(
        body: cuerpo,
        floatingActionButton: FloatingActionButton.small(
          tooltip: 'Importar audios del dispositivo',
          onPressed: c.grabando ? null : c.importarDelDispositivo,
          child: const Icon(Icons.library_music_outlined),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Granolazo'),
        actions: [
          IconButton(
            tooltip: 'Importar audios del dispositivo',
            onPressed: c.grabando ? null : c.importarDelDispositivo,
            icon: const Icon(Icons.library_music_outlined),
          ),
          IconButton(
            tooltip: 'Ajustes',
            onPressed: _abrirAjustes,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: cuerpo,
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icono,
    required this.texto,
    required this.color,
    this.alTocar,
  });

  final IconData icono;
  final String texto;
  final Color color;
  final VoidCallback? alTocar;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      child: InkWell(
        onTap: alTocar,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(icono, size: 20),
              const SizedBox(width: 12),
              Expanded(child: Text(texto)),
              if (alTocar != null) const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class _PanelGrabacion extends StatelessWidget {
  const _PanelGrabacion({required this.controller});

  final GrabacionesController controller;

  String _reloj(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final grabando = controller.grabando;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Mezclador(controller: controller),
          ),
          Text(
            grabando ? _reloj(controller.duracionActual) : 'Listo para grabar',
            style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (grabando) ...[
                IconButton.filledTonal(
                  onPressed: controller.cancelarGrabacion,
                  iconSize: 28,
                  tooltip: 'Descartar',
                  icon: const Icon(Icons.delete_outline),
                ),
                const SizedBox(width: 24),
              ],
              SizedBox(
                width: 84,
                height: 84,
                child: FilledButton(
                  onPressed: grabando
                      ? controller.detenerGrabacion
                      : controller.comenzarGrabacion,
                  style: FilledButton.styleFrom(
                    shape: const CircleBorder(),
                    backgroundColor: grabando
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.primary,
                  ),
                  child: Icon(grabando ? Icons.stop : Icons.mic, size: 36),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          InterruptorEnVivo(coordinador: controller.enVivo, grabando: grabando),
          if (controller.pendientes > 0) ...[
            const SizedBox(height: 16),
            Text(
              '${controller.pendientes} por procesar',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

class _Lista extends StatelessWidget {
  const _Lista({required this.controller, required this.reproductor});

  final GrabacionesController controller;
  final ReproductorService reproductor;

  @override
  Widget build(BuildContext context) {
    final items = controller.grabaciones;
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.graphic_eq,
                  size: 48, color: Theme.of(context).disabledColor),
              const SizedBox(height: 12),
              Text(
                'Todavía no hay grabaciones.\n'
                'Graba con el botón o importa audios que ya tengas.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) => TarjetaGrabacion(
        reproductor: reproductor,
        grabacion: items[i],
        controller: controller,
      ),
    );
  }
}
