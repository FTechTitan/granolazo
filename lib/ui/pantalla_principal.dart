import 'package:flutter/material.dart';

import '../controllers/grabaciones_controller.dart';
import '../services/granolazo_api.dart';
import '../services/presencia_service.dart';
import '../services/reproductor_service.dart';
import '../services/respaldo_service.dart';
import '../services/sesion_service.dart';
import 'aviso_reunion.dart';
import 'pantalla_ajustes.dart';
import 'pantalla_cola.dart';
import 'pantalla_inicio.dart';
import 'pantalla_respaldo.dart';
import 'pantalla_reuniones.dart';
import 'pantalla_sesion.dart';

/// El armazón de la app: grabar, las reuniones de Granolazo y la cola del pipeline.
///
/// En pantallas anchas la navegación va al costado y en angostas abajo, que es lo que
/// espera cada sistema. Es el mismo código para escritorio y para el celular.
class PantallaPrincipal extends StatefulWidget {
  const PantallaPrincipal({
    super.key,
    required this.controller,
    required this.api,
    required this.sesion,
    required this.reproductor,
    required this.presencia,
    this.respaldo,
  });

  final GrabacionesController controller;
  final GranolazoApi api;
  final SesionService sesion;
  final ReproductorService reproductor;
  final PresenciaService presencia;

  /// El respaldo de videos a Drive. Solo existe en Windows; sin él no hay sección.
  final RespaldoService? respaldo;

  @override
  State<PantallaPrincipal> createState() => _PantallaPrincipalState();
}

class _PantallaPrincipalState extends State<PantallaPrincipal> {
  int _seccion = 0;

  List<({IconData icono, IconData activo, String titulo})> get _secciones => [
        (icono: Icons.mic, activo: Icons.mic, titulo: 'Grabar'),
        (icono: Icons.forum_outlined, activo: Icons.forum, titulo: 'Reuniones'),
        (icono: Icons.schedule_outlined, activo: Icons.schedule, titulo: 'Cola'),
        if (widget.respaldo != null)
          (icono: Icons.backup_outlined, activo: Icons.backup, titulo: 'Respaldo'),
      ];

  @override
  void initState() {
    super.initState();
    widget.sesion.cargar();
    widget.sesion.addListener(_alCambiarSesion);
    widget.presencia.addListener(_alCambiarSesion);
  }

  @override
  void dispose() {
    widget.sesion.removeListener(_alCambiarSesion);
    widget.presencia.removeListener(_alCambiarSesion);
    super.dispose();
  }

  void _alCambiarSesion() {
    if (mounted) setState(() {});
  }

  Future<void> _sesion() async {
    final u = widget.sesion.usuario;
    if (u == null) {
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => PantallaSesion(sesion: widget.sesion)),
      );
      return;
    }
    final salir = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(u.email),
        content: const Text('¿Cerrar la sesión en este dispositivo?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(false), child: const Text('No')),
          FilledButton(
              onPressed: () => Navigator.of(c).pop(true), child: const Text('Cerrar')),
        ],
      ),
    );
    if (salir == true) await widget.sesion.salir();
  }

  Future<void> _abrirAjustes() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PantallaAjustes(controller: widget.controller),
    ));
  }

  @override
  Widget build(BuildContext context) {
    // En modo aviso la ventana ES el aviso: chica, abajo a la derecha y encima de todo.
    if (widget.presencia.modo == ModoVentana.aviso &&
        widget.presencia.sugerida != null) {
      return AvisoReunion(
        app: widget.presencia.sugerida!,
        alGrabar: widget.presencia.aceptarSugerencia,
        alDescartar: widget.presencia.descartarSugerencia,
        alIgnorarApp: widget.presencia.ignorarApp,
      );
    }

    final ancha = MediaQuery.of(context).size.width >= 720;
    final u = widget.sesion.usuario;

    final cuerpo = switch (_seccion) {
      1 => PantallaReuniones(api: widget.api),
      2 => PantallaCola(api: widget.api),
      3 when widget.respaldo != null => PantallaRespaldo(respaldo: widget.respaldo!),
      _ => PantallaInicio(
          controller: widget.controller,
          reproductor: widget.reproductor,
          conArmazon: false,
        ),
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(_secciones[_seccion].titulo == 'Grabar'
            ? 'Granolazo'
            : 'Granolazo · ${_secciones[_seccion].titulo}'),
        actions: [
          TextButton.icon(
            icon: Icon(u == null ? Icons.login : Icons.account_circle, size: 20),
            label: Text(u == null ? 'Entrar' : u.email.split('@').first),
            onPressed: _sesion,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Ajustes',
            onPressed: _abrirAjustes,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          // Con la ventana a la vista el aviso va adentro, como una banda: asomar la
          // ventanita encima de lo que alguien está usando es lo contrario de sutil.
          if (widget.presencia.sugerida != null)
            _BandaSugerencia(presencia: widget.presencia),
          Expanded(
            child: ancha
                ? Row(
                    children: [
                      NavigationRail(
                        selectedIndex: _seccion,
                        onDestinationSelected: (i) => setState(() => _seccion = i),
                        labelType: NavigationRailLabelType.all,
                        destinations: [
                          for (final s in _secciones)
                            NavigationRailDestination(
                              icon: Icon(s.icono),
                              selectedIcon: Icon(s.activo),
                              label: Text(s.titulo),
                            ),
                        ],
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(child: cuerpo),
                    ],
                  )
                : cuerpo,
          ),
        ],
      ),
      bottomNavigationBar: ancha
          ? null
          : NavigationBar(
              selectedIndex: _seccion,
              onDestinationSelected: (i) => setState(() => _seccion = i),
              destinations: [
                for (final s in _secciones)
                  NavigationDestination(
                    icon: Icon(s.icono),
                    selectedIcon: Icon(s.activo),
                    label: s.titulo,
                  ),
              ],
            ),
    );
  }
}

/// El aviso de reunión cuando la ventana ya está a la vista.
class _BandaSugerencia extends StatelessWidget {
  const _BandaSugerencia({required this.presencia});

  final PresenciaService presencia;

  @override
  Widget build(BuildContext context) {
    final app = presencia.sugerida;
    if (app == null) return const SizedBox.shrink();
    final colores = Theme.of(context).colorScheme;
    return Material(
      color: colores.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(Icons.graphic_eq, size: 18, color: colores.onSecondaryContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${app.nombre} está usando el micrófono. ¿Grabo esta reunión?',
                style: TextStyle(color: colores.onSecondaryContainer),
              ),
            ),
            TextButton(
              onPressed: presencia.ignorarApp,
              child: const Text('No preguntar más'),
            ),
            TextButton(
              onPressed: presencia.descartarSugerencia,
              child: const Text('Ahora no'),
            ),
            const SizedBox(width: 4),
            FilledButton.icon(
              onPressed: presencia.aceptarSugerencia,
              icon: const Icon(Icons.fiber_manual_record, size: 16),
              label: const Text('Grabar'),
            ),
          ],
        ),
      ),
    );
  }
}
