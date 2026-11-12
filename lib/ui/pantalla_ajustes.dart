import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/granolazo_config.dart';
import '../controllers/grabaciones_controller.dart';
import '../services/ajustes_service.dart';
import '../services/arranque_service.dart';
import '../services/puente_android.dart';
import '../services/transcriptor_local.dart';
import 'seccion_ajustes_en_vivo.dart';

/// Ajustes: clave de transcripción, identidad del dispositivo y conexión al backend.
class PantallaAjustes extends StatefulWidget {
  const PantallaAjustes({super.key, required this.controller});

  final GrabacionesController controller;

  @override
  State<PantallaAjustes> createState() => _PantallaAjustesState();
}

class _PantallaAjustesState extends State<PantallaAjustes> {
  final _ajustes = AjustesService();
  final _claveCtrl = TextEditingController();
  final _dispositivoCtrl = TextEditingController();

  bool _cargando = true;
  bool _subidaAutomatica = true;
  bool _mostrarClave = false;
  bool _hayClaveGuardada = false;
  String _idioma = 'es';
  String _motor = 'local';
  ModeloLocal _modelo = ModeloLocal.small;
  bool _modeloDescargado = false;
  bool _bajandoModelo = false;
  bool _transcripcionAutomatica = false;
  final _arranque = ArranqueService();
  final _puente = PuenteAndroid();
  String? _cliToken;
  bool _arrancaConElSistema = false;
  bool _detectarReuniones = true;
  String? _estadoConexion;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void dispose() {
    _claveCtrl.dispose();
    _dispositivoCtrl.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    final clave = await _ajustes.leerClaveTranscripcion();
    final dispositivo =
        await _ajustes.leerNombreDispositivo(widget.controller.plataforma);
    final subida = await _ajustes.leerSubidaAutomatica();
    final idioma = await _ajustes.leerIdiomaAudio();
    final motor = await _ajustes.leerMotorTranscripcion();
    final modelo = ModeloLocal.desdeNombre(await _ajustes.leerModeloLocal());
    final automatica = await _ajustes.leerTranscripcionAutomatica();
    final bajado = await TranscriptorLocal(modelo: modelo).modeloDescargado();
    final arranca = await _arranque.activo;
    // En Android manda el ajuste nativo: el vigilante tiene que poder leerlo al encender
    // el telefono, cuando todavia no existe ningun motor de Flutter al que preguntarle.
    final detectar = PuenteAndroid.soportado
        ? await _puente.detectarActivo()
        : await _ajustes.leerDetectarReuniones();
    final token = await _puente.cliToken();
    if (!mounted) return;
    setState(() {
      _hayClaveGuardada = clave != null;
      _dispositivoCtrl.text = dispositivo;
      _subidaAutomatica = subida;
      _idioma = idioma;
      _motor = motor;
      _modelo = modelo;
      _modeloDescargado = bajado;
      _transcripcionAutomatica = automatica;
      _arrancaConElSistema = arranca;
      _detectarReuniones = detectar;
      _cliToken = token;
      _cargando = false;
    });
  }

  Future<void> _cambiarModelo(ModeloLocal m) async {
    await _ajustes.guardarModeloLocal(m.nombre);
    final bajado = await TranscriptorLocal(modelo: m).modeloDescargado();
    if (!mounted) return;
    setState(() {
      _modelo = m;
      _modeloDescargado = bajado;
    });
  }

  Future<void> _bajarModelo() async {
    setState(() => _bajandoModelo = true);
    try {
      await TranscriptorLocal(modelo: _modelo).descargarModelo();
      if (mounted) setState(() => _modeloDescargado = true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('modelo ${_modelo.nombre} listo')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('no pude bajar el modelo: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _bajandoModelo = false);
    }
  }

  Future<void> _guardarClave() async {
    final valor = _claveCtrl.text.trim();
    if (valor.isEmpty) return;
    await _ajustes.guardarClaveTranscripcion(valor);
    _claveCtrl.clear();
    if (!mounted) return;
    setState(() => _hayClaveGuardada = true);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('clave guardada en el almacén seguro')));
  }

  Future<void> _borrarClave() async {
    await _ajustes.guardarClaveTranscripcion(null);
    if (!mounted) return;
    setState(() => _hayClaveGuardada = false);
  }

  Future<void> _probar() async {
    setState(() => _estadoConexion = 'probando…');
    final ok = await widget.controller.probarBackend();
    if (!mounted) return;
    setState(() => _estadoConexion = ok
        ? 'conecta bien con Granolazo'
        : 'no pude conectar con Granolazo');
  }

  @override
  Widget build(BuildContext context) {
    if (_cargando) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Transcripción', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            _hayClaveGuardada
                ? 'Hay una clave guardada en el almacén seguro del dispositivo.'
                : 'Sin clave no se puede transcribir. Se guarda cifrada en el dispositivo y '
                    'no viaja a ningún lado salvo al servicio de transcripción.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _claveCtrl,
            obscureText: !_mostrarClave,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: _hayClaveGuardada ? 'Reemplazar clave' : 'Clave de transcripción',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_mostrarClave ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _mostrarClave = !_mostrarClave),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton(onPressed: _guardarClave, child: const Text('Guardar')),
              const SizedBox(width: 12),
              if (_hayClaveGuardada)
                TextButton(onPressed: _borrarClave, child: const Text('Borrar')),
            ],
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'local',
                icon: Icon(Icons.memory),
                label: Text('Este equipo'),
              ),
              ButtonSegment(
                value: 'api',
                icon: Icon(Icons.cloud),
                label: Text('Servicio en línea'),
              ),
            ],
            selected: {_motor},
            onSelectionChanged: (s) async {
              final v = s.first;
              setState(() => _motor = v);
              await _ajustes.guardarMotorTranscripcion(v);
            },
          ),
          const SizedBox(height: 6),
          Text(
            _motor == 'local'
                ? 'Transcribe con el procesador de este equipo: gratis, sin conexión y '
                    'sin ninguna clave guardada. Tarda más que el servicio en línea.'
                : 'Manda el audio a un servicio que cobra por minuto y necesita una clave '
                    'en este dispositivo. Es más rápido.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_motor == 'local') ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<ModeloLocal>(
              initialValue: _modelo,
              decoration: const InputDecoration(
                labelText: 'Modelo',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final m in ModeloLocal.values)
                  DropdownMenuItem(
                    value: m,
                    child: Text('${m.nombre} · ${m.megas} MB · ${m.descripcion}'),
                  ),
              ],
              onChanged: (v) => v == null ? null : _cambiarModelo(v),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  _modeloDescargado ? Icons.check_circle : Icons.download_for_offline,
                  size: 18,
                  color: _modeloDescargado ? Colors.green : null,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _modeloDescargado
                        ? 'El modelo está bajado y listo.'
                        : 'Falta bajarlo. Son ${_modelo.megas} MB, una sola vez.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (!_modeloDescargado)
                  FilledButton.tonal(
                    onPressed: _bajandoModelo ? null : _bajarModelo,
                    child: _bajandoModelo
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Bajar'),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Transcribir apenas termina de grabar'),
            subtitle: const Text(
                'Apagado, la grabación queda en espera y se transcribe cuando lo pidas: '
                'así se puede grabar sin conexión y sin gastar'),
            value: _transcripcionAutomatica,
            onChanged: (v) async {
              setState(() => _transcripcionAutomatica = v);
              await _ajustes.guardarTranscripcionAutomatica(v);
            },
          ),
          DropdownButtonFormField<String>(
            initialValue: _idioma,
            decoration: const InputDecoration(
              labelText: 'Idioma del audio',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'es', child: Text('Español')),
              DropdownMenuItem(value: 'en', child: Text('Inglés')),
              DropdownMenuItem(value: 'pt', child: Text('Portugués')),
            ],
            onChanged: (v) async {
              if (v == null) return;
              setState(() => _idioma = v);
              await _ajustes.guardarIdiomaAudio(v);
            },
          ),
          const Divider(height: 40),
          const SeccionAjustesEnVivo(),
          const Divider(height: 40),
          Text(
            Platform.isAndroid ? 'En este teléfono' : 'En este equipo',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(Platform.isAndroid
                ? 'Quedar atento al encender el teléfono'
                : 'Arrancar al prender el computador'),
            subtitle: Text(Platform.isAndroid
                ? 'No abre la app: deja corriendo el aviso de reuniones. Se puede '
                    'desactivar también desde los ajustes del teléfono'
                : 'Queda en la bandeja del sistema, sin abrir ventana. Se puede desactivar '
                    'también desde el Administrador de tareas, pestaña Inicio'),
            value: _arrancaConElSistema,
            onChanged: _arranque.soportado
                ? (v) async {
                    final messenger = ScaffoldMessenger.of(context);
                    final error =
                        v ? await _arranque.activar() : await _arranque.desactivar();
                    if (!mounted) return;
                    setState(() => _arrancaConElSistema = error == null && v);
                    if (error != null) {
                      messenger.showSnackBar(SnackBar(content: Text(error)));
                    }
                  }
                : null,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Avisarme cuando empiece una reunión'),
            subtitle: Text(Platform.isAndroid
                ? 'Se da cuenta cuando el teléfono entra en una llamada —Discord, Meet, '
                    'Zoom, WhatsApp— y ofrece grabar con una notificación'
                : 'Mira qué aplicación está usando el micrófono —Discord, Meet, Zoom, '
                    'WhatsApp— y ofrece grabar'),
            value: _detectarReuniones,
            onChanged: (v) async {
              setState(() => _detectarReuniones = v);
              await _ajustes.guardarDetectarReuniones(v);
              // En Android el que avisa con la app cerrada es un servicio nativo: hay que
              // prenderlo y apagarlo aparte del ajuste.
              if (PuenteAndroid.soportado) {
                await _puente.vigilante(v);
                if (v) await _puente.pedirNotificaciones();
              }
            },
          ),
          if (Platform.isAndroid) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Nombrar la aplicación que llama'),
              subtitle: const Text(
                  'Opcional. Sin esto el aviso dice "una llamada" en vez de "Discord". '
                  'Hay que darle a Granolazo el acceso al uso de aplicaciones'),
              trailing: const Icon(Icons.open_in_new, size: 18),
              onTap: _puente.abrirUsoDeApps,
            ),
            if (_cliToken != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Llave del modo consola'),
                subtitle: Text(
                  'Para manejar la app por adb. Toca para copiarla. $_cliToken',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                trailing: const Icon(Icons.copy, size: 18),
                onTap: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  await Clipboard.setData(ClipboardData(text: _cliToken!));
                  messenger.showSnackBar(
                    const SnackBar(content: Text('Llave copiada')),
                  );
                },
              ),
          ],
          const Divider(height: 40),
          Text('Granolazo', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(GranolazoConfig.supabaseUrl,
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          TextField(
            controller: _dispositivoCtrl,
            decoration: const InputDecoration(
              labelText: 'Nombre de este dispositivo',
              helperText: 'Aparece en Granolazo para saber de dónde salió la grabación',
              border: OutlineInputBorder(),
            ),
            onSubmitted: _ajustes.guardarNombreDispositivo,
            onChanged: _ajustes.guardarNombreDispositivo,
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Subir a Granolazo automáticamente'),
            subtitle: const Text(
                'Si lo apagas, las grabaciones se transcriben pero quedan solo en el dispositivo'),
            value: _subidaAutomatica,
            onChanged: (v) async {
              setState(() => _subidaAutomatica = v);
              await _ajustes.guardarSubidaAutomatica(v);
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _probar,
                icon: const Icon(Icons.wifi_tethering),
                label: const Text('Probar conexión'),
              ),
              const SizedBox(width: 12),
              if (_estadoConexion != null) Expanded(child: Text(_estadoConexion!)),
            ],
          ),
          const SizedBox(height: 32),
          Text(
            'Las grabaciones se guardan como items de Granolazo, igual que las de cualquier '
            'otra fuente, y disparan el mismo evento que consume el sistema agéntico.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
