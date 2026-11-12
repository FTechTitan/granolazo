import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/archivo_respaldo.dart';
import '../services/ajustes_service.dart';
import '../services/drive_cliente.dart';
import '../services/respaldo_service.dart';

/// Respaldo de la carpeta de videos del equipo en Drive.
///
/// Arriba se enciende y se ve en qué va; al medio, cuánto espacio se puede recuperar; abajo,
/// archivo por archivo. La configuración vive acá mismo y no en Ajustes: es lo primero que
/// hay que mirar cuando algo no sube.
class PantallaRespaldo extends StatefulWidget {
  const PantallaRespaldo({super.key, required this.respaldo});

  final RespaldoService respaldo;

  @override
  State<PantallaRespaldo> createState() => _PantallaRespaldoState();
}

class _PantallaRespaldoState extends State<PantallaRespaldo> {
  bool _liberando = false;
  bool _verRespaldados = false;
  bool _verLiberados = false;
  Timer? _refresco;

  RespaldoService get _r => widget.respaldo;

  @override
  void initState() {
    super.initState();
    _r.addListener(_alCambiar);
    if (!_r.cargado) _r.cargar();
    if (_r.nombreCarpetaDrive == null) _r.comprobarDrive();
    _r.actualizarTranscripciones();
    // Mientras se mira la pantalla, el avance de las transcripciones se refresca solo.
    _refresco = Timer.periodic(
        const Duration(minutes: 1), (_) => _r.actualizarTranscripciones());
  }

  @override
  void dispose() {
    _refresco?.cancel();
    _r.removeListener(_alCambiar);
    super.dispose();
  }

  void _alCambiar() {
    if (mounted) setState(() {});
  }

  void _avisar(String texto) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(texto)));
  }

  // ── acciones ─────────────────────────────────────────────────────────────────

  Future<void> _elegirCarpetaLocal() async {
    final ruta = await FilePicker.getDirectoryPath(
      dialogTitle: 'Carpeta a respaldar',
      initialDirectory: _r.carpetaLocal,
    );
    if (ruta == null) return;
    try {
      await _r.cambiarCarpetaLocal(ruta);
    } on ErrorDrive catch (e) {
      _avisar(e.mensaje);
    }
  }

  Future<void> _elegirPerfilGws() async {
    final ruta = await FilePicker.getDirectoryPath(
      dialogTitle: 'Carpeta del perfil de gws (la que tiene credentials.enc)',
      initialDirectory: _r.perfilGws.isEmpty ? null : _r.perfilGws,
    );
    if (ruta == null) return;
    await _r.cambiarPerfilGws(ruta);
    await _r.comprobarDrive();
  }

  Future<void> _elegirCarpetaDrive() async {
    final control = TextEditingController();
    final texto = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Carpeta de Drive'),
        content: SizedBox(
          width: 480,
          child: TextField(
            controller: control,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Enlace o id de la carpeta',
              hintText: 'https://drive.google.com/drive/folders/…',
            ),
            onSubmitted: (v) => Navigator.of(c).pop(v),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () => Navigator.of(c).pop(control.text),
            child: const Text('Usar esta'),
          ),
        ],
      ),
    );
    control.dispose();
    if (texto == null || texto.trim().isEmpty) return;
    try {
      await _r.cambiarCarpetaDrive(texto);
      _avisar('Los videos van a "${_r.nombreCarpetaDrive}"');
    } on ErrorDrive catch (e) {
      _avisar(e.mensaje);
    }
  }

  Future<void> _liberar() async {
    final cuantos = _r.respaldados.length;
    final bytes = _r.bytesLiberables;
    final seguro = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('¿Liberar ${tamanoLegible(bytes)}?'),
        content: Text(
          'Se borran de este equipo $cuantos '
          '${cuantos == 1 ? "video que ya está" : "videos que ya están"} en Drive.\n\n'
          'Antes de borrar cada uno se comprueba otra vez que la copia de Drive es '
          'idéntica (mismo MD5). Se borran definitivamente, sin pasar por la papelera: la '
          'copia que queda es la de Drive.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('No')),
          FilledButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('Liberar espacio'),
          ),
        ],
      ),
    );
    if (seguro != true) return;
    setState(() => _liberando = true);
    try {
      final r = await _r.liberarEspacio();
      final partes = [
        if (r.liberados > 0)
          'Liberados ${tamanoLegible(r.bytes)} '
              '(${r.liberados} ${r.liberados == 1 ? "video" : "videos"})',
        if (r.fallidos.isNotEmpty)
          '${r.fallidos.length} no se borraron: ${r.fallidos.values.first}',
      ];
      _avisar(partes.isEmpty ? 'No había nada que liberar' : partes.join(' · '));
    } on ErrorDrive catch (e) {
      _avisar(e.mensaje);
    } finally {
      if (mounted) setState(() => _liberando = false);
    }
  }

  // ── pantalla ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!_r.cargado) return const Center(child: CircularProgressIndicator());

    final enCurso = _r.enCurso;
    final pendientes = _r.pendientes;
    final errores = _r.conError;
    final respaldados = _r.respaldados;
    final liberados = _r.liberados;

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        _tarjetaEstado(context),
        if (_r.bytesLiberables > 0) _tarjetaLiberar(context),
        _tarjetaResumen(context),
        _tarjetaConfiguracion(context),
        if (enCurso != null) ...[
          _titulo(context, 'Subiendo ahora', 1),
          _filaSubiendo(context, enCurso),
        ],
        if (errores.isNotEmpty) ...[
          _titulo(context, 'Con error', errores.length),
          for (final a in errores) _filaError(context, a),
        ],
        if (pendientes.isNotEmpty) ...[
          _titulo(context, 'Por subir', pendientes.length),
          for (final a in pendientes) _filaPendiente(context, a),
        ],
        if (respaldados.isNotEmpty) ...[
          ListTile(
            title: Text('En Drive y todavía en el equipo (${respaldados.length})',
                style: Theme.of(context).textTheme.titleSmall),
            trailing: Icon(_verRespaldados ? Icons.expand_less : Icons.expand_more),
            onTap: () => setState(() => _verRespaldados = !_verRespaldados),
          ),
          if (_verRespaldados)
            for (final a in respaldados) _filaRespaldada(context, a),
        ],
        if (liberados.isNotEmpty) ...[
          ListTile(
            title: Text('Solo en Drive, ya liberados del equipo (${liberados.length})',
                style: Theme.of(context).textTheme.titleSmall),
            trailing: Icon(_verLiberados ? Icons.expand_less : Icons.expand_more),
            onTap: () => setState(() => _verLiberados = !_verLiberados),
          ),
          if (_verLiberados)
            for (final a in liberados) _filaRespaldada(context, a),
        ],
      ],
    );
  }

  Widget _tarjetaEstado(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    final error = _r.errorGeneral;
    final ultima = _r.ultimaRevision;
    final String estado;
    if (!_r.activo) {
      estado = 'Apagado. Los videos nuevos no se suben solos.';
    } else if (_r.revisando) {
      final a = _r.enCurso;
      estado = a == null
          ? 'Revisando la carpeta…'
          : 'Subiendo ${a.nombre} · ${(a.progreso * 100).floor()} %';
    } else if (_r.pendientes.isNotEmpty || _r.conError.isNotEmpty) {
      estado = 'Faltan ${_r.pendientes.length + _r.conError.length} por subir '
          '(${tamanoLegible(_r.bytesPendientes)}). Se revisa cada '
          '${_r.intervalo.inMinutes} min.';
    } else {
      estado = 'Al día. Se revisa cada ${_r.intervalo.inMinutes} min.';
    }

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Respaldar videos en Drive automáticamente'),
              subtitle: Text(estado),
              value: _r.activo,
              onChanged: (v) => _r.activar(v),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, size: 18, color: colores.error),
                    const SizedBox(width: 8),
                    Expanded(child: Text(error, style: TextStyle(color: colores.error))),
                  ],
                ),
              ),
            Row(
              children: [
                if (ultima != null)
                  Expanded(
                    child: Text(
                      'Última revisión: ${DateFormat('dd-MM HH:mm').format(ultima)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  )
                else
                  const Spacer(),
                if (_r.revisando && _r.enCurso != null)
                  TextButton.icon(
                    onPressed: _r.detenerSubida,
                    icon: const Icon(Icons.pause, size: 18),
                    label: const Text('Detener'),
                  ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: _r.revisando || _r.liberando ? null : _r.revisarAhora,
                  icon: const Icon(Icons.sync, size: 18),
                  label: const Text('Revisar ahora'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _tarjetaLiberar(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    final n = _r.respaldados.length;
    return Card(
      color: colores.secondaryContainer,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.cleaning_services_outlined, color: colores.onSecondaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Puedes liberar ${tamanoLegible(_r.bytesLiberables)}: $n '
                '${n == 1 ? "video ya está" : "videos ya están"} a salvo en Drive.',
                style: TextStyle(color: colores.onSecondaryContainer),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: _liberando || _r.liberando ? null : _liberar,
              icon: _liberando
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.delete_sweep_outlined, size: 18),
              label: const Text('Liberar espacio'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tarjetaResumen(BuildContext context) {
    final porSubir = _r.pendientes.length + _r.conError.length + (_r.enCurso == null ? 0 : 1);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
                child: _dato(context, '$porSubir', 'por subir',
                    tamanoLegible(_r.bytesPendientes))),
            Expanded(
                child: _dato(context, '${_r.respaldados.length}', 'en Drive y en el equipo',
                    tamanoLegible(_r.bytesLiberables))),
            Expanded(
                child: _dato(context, '${_r.liberados.length}', 'ya liberados',
                    tamanoLegible(_r.bytesLiberadosTotal))),
          ],
        ),
      ),
    );
  }

  Widget _dato(BuildContext context, String valor, String etiqueta, String detalle) =>
      Column(
        children: [
          Text(valor, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 2),
          Text(etiqueta,
              style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
          Text(detalle, style: Theme.of(context).textTheme.bodySmall),
        ],
      );

  Widget _tarjetaConfiguracion(BuildContext context) {
    final drive = _r.nombreCarpetaDrive;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.subtitles_outlined),
            title: const Text('Transcribir los videos en Granolazo'),
            subtitle: Text(_r.transcribir
                ? 'Van a ${AjustesService.carpetaDriveObsNombre} y Granolazo los '
                    'transcribe. Lo ya respaldado se mueve ahí, sin volver a subirlo.'
                : 'Solo respaldo: van a la carpeta de Drive de abajo, sin transcribir.'),
            value: _r.transcribir,
            onChanged: (v) => _r.activarTranscripcion(v),
          ),
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('Carpeta del equipo'),
            subtitle: Text(_r.carpetaLocal.isEmpty ? 'sin elegir' : _r.carpetaLocal),
            trailing: TextButton(onPressed: _elegirCarpetaLocal, child: const Text('Cambiar')),
          ),
          ListTile(
            leading: const Icon(Icons.add_to_drive_outlined),
            title: const Text('Carpeta de Drive'),
            subtitle: Text(drive ?? (_r.carpetaDrive.isEmpty ? '…' : _r.carpetaDrive)),
            // Con la transcripción encendida el destino es fijo: es la carpeta que vigila
            // el worker. Lo que se elige acá es la de solo respaldo.
            trailing: _r.transcribir
                ? null
                : TextButton(onPressed: _elegirCarpetaDrive, child: const Text('Cambiar')),
          ),
          ListTile(
            leading: const Icon(Icons.key_outlined),
            title: const Text('Cuenta de Google (perfil de gws)'),
            subtitle: Text(_r.perfilGws.isEmpty
                ? 'el perfil por defecto de gws'
                : _r.perfilGws),
            trailing: TextButton(onPressed: _elegirPerfilGws, child: const Text('Cambiar')),
          ),
        ],
      ),
    );
  }

  Widget _titulo(BuildContext context, String texto, int cuantos) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text('$texto ($cuantos)', style: Theme.of(context).textTheme.titleSmall),
      );

  String _fecha(DateTime d) => DateFormat('dd-MM-yyyy HH:mm').format(d);

  Widget _filaSubiendo(BuildContext context, ArchivoRespaldo a) => ListTile(
        leading: const Icon(Icons.cloud_upload_outlined),
        title: Text(a.nombre),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 6),
            LinearProgressIndicator(value: a.progreso),
            const SizedBox(height: 4),
            Text('${tamanoLegible(a.enviados)} de ${tamanoLegible(a.tamano)} · '
                '${(a.progreso * 100).floor()} %'),
          ],
        ),
      );

  Widget _filaPendiente(BuildContext context, ArchivoRespaldo a) {
    final fresco = DateTime.now().difference(a.modificado) < _r.reposo;
    return ListTile(
      dense: true,
      leading: Icon(fresco ? Icons.fiber_manual_record : Icons.schedule, size: 20),
      title: Text(a.nombre),
      subtitle: Text('${tamanoLegible(a.tamano)} · ${_fecha(a.modificado)}'
          '${fresco ? " · se está grabando, espera a que termine" : ""}'
          '${a.enviados > 0 ? " · subido ${(a.progreso * 100).floor()} %, sigue desde ahí" : ""}'),
    );
  }

  Widget _filaError(BuildContext context, ArchivoRespaldo a) => ListTile(
        dense: true,
        leading: Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
        title: Text(a.nombre),
        subtitle: Text('${tamanoLegible(a.tamano)} · ${a.error ?? "sin detalle"}'),
      );

  Widget _filaRespaldada(BuildContext context, ArchivoRespaldo a) {
    final transcripcion = _textoTranscripcion(a);
    return ListTile(
      dense: true,
      leading: const Icon(Icons.cloud_done_outlined, size: 20),
      title: Text(a.nombre),
      subtitle: Text('${tamanoLegible(a.tamano)} · en Drive desde '
          '${a.respaldadoEn == null ? "antes" : _fecha(a.respaldadoEn!)}'
          '${transcripcion == null ? "" : " · $transcripcion"}'
          '${a.error == null ? "" : " · ${a.error}"}'),
    );
  }

  /// En qué va la transcripción, o `null` si el video no va a transcribirse.
  String? _textoTranscripcion(ArchivoRespaldo a) {
    if (!_r.vaATranscribirse(a)) return null;
    final item = _r.transcripcionDe(a);
    if (item == null) return 'esperando que Granolazo lo tome';
    return switch (item.estado) {
      'transcribed' => 'transcrito',
      'error' => 'error al transcribir: ${item.mensajeError ?? "sin detalle"}',
      _ when item.progreso > 0 => 'transcribiendo ${item.progreso} %',
      _ => 'en cola de transcripción',
    };
  }
}
