import 'package:flutter/material.dart';

import '../services/sesion_service.dart';

/// Entrar a Granolazo con correo y contraseña.
///
/// **No es una barrera para usar la app.** Grabar tiene que poder hacerse sin conexión y
/// sin credenciales —es la razón de ser de la app—, así que la sesión es opcional y esta
/// pantalla se abre cuando se la pide. Lo que aporta es que las escrituras queden
/// atribuidas a una persona, y estar del lado correcto el día que la base tenga políticas
/// por fila.
class PantallaSesion extends StatefulWidget {
  const PantallaSesion({super.key, required this.sesion});

  final SesionService sesion;

  @override
  State<PantallaSesion> createState() => _PantallaSesionState();
}

class _PantallaSesionState extends State<PantallaSesion> {
  final _email = TextEditingController();
  final _clave = TextEditingController();
  final _formulario = GlobalKey<FormState>();
  bool _ocupado = false;
  bool _verClave = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _clave.dispose();
    super.dispose();
  }

  Future<void> _entrar() async {
    if (!(_formulario.currentState?.validate() ?? false)) return;
    setState(() {
      _ocupado = true;
      _error = null;
    });
    try {
      await widget.sesion.entrar(email: _email.text, clave: _clave.text);
      if (mounted) Navigator.of(context).pop(true);
    } on ErrorSesion catch (e) {
      if (mounted) setState(() => _error = e.mensaje);
    } catch (e) {
      if (mounted) setState(() => _error = 'no pude iniciar sesión: $e');
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Entrar a Granolazo')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Form(
              key: _formulario,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'La misma cuenta del panel web.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Grabar funciona sin sesión; esto sirve para ver y escribir con tu '
                    'nombre.',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: colores.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _email,
                    autofocus: true,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Correo',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        (v == null || !v.contains('@')) ? 'falta un correo válido' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _clave,
                    obscureText: !_verClave,
                    decoration: InputDecoration(
                      labelText: 'Contraseña',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(_verClave ? Icons.visibility_off : Icons.visibility),
                        tooltip: _verClave ? 'Ocultar' : 'Mostrar',
                        onPressed: () => setState(() => _verClave = !_verClave),
                      ),
                    ),
                    validator: (v) =>
                        (v == null || v.isEmpty) ? 'falta la contraseña' : null,
                    onFieldSubmitted: (_) => _entrar(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: colores.error)),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _ocupado ? null : _entrar,
                    child: _ocupado
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Entrar'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
