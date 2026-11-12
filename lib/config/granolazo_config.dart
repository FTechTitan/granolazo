/// Configuración de conexión al backend de Granolazo.
///
/// La app es un **cliente** del mismo Supabase self-hosted que ya usa el panel web
/// (`web/`) y que alimentan los workers: no monta un backend nuevo. Una grabación hecha
/// acá termina siendo una fila de `items` igual que cualquier otra fuente, y el trigger
/// `items_emit_meeting_event` emite su evento en `ingest_events` sin tratamiento especial.
///
/// La clave pública se pasa en tiempo de compilación para no versionarla en el código:
///
///   flutter run --dart-define-from-file=granolazo.env
///   flutter build apk --dart-define-from-file=granolazo.env
///
/// El archivo `granolazo.env` no se versiona. Hay una plantilla en `granolazo.env.example`.
library;

class GranolazoConfig {
  const GranolazoConfig._();

  /// URL base del Supabase de Granolazo.
  static const String supabaseUrl = String.fromEnvironment(
    'GRANOLAZO_URL',
    defaultValue: 'https://your-project.supabase.example',
  );

  /// Clave pública (anon). Nunca la de servicio: esto es un cliente instalable.
  static const String anonKey = String.fromEnvironment('GRANOLAZO_ANON_KEY');

  /// Endpoint de transcripción. Por defecto la API de OpenAI; se puede apuntar a una
  /// Edge Function propia para no tener ninguna clave en el dispositivo.
  static const String transcriptionEndpoint = String.fromEnvironment(
    'GRANOLAZO_TRANSCRIPTION_ENDPOINT',
    defaultValue: 'https://api.openai.com/v1/audio/transcriptions',
  );

  /// Modelo de transcripción.
  static const String transcriptionModel = String.fromEnvironment(
    'GRANOLAZO_TRANSCRIPTION_MODEL',
    defaultValue: 'gpt-4o-transcribe',
  );

  static const String restPath = '/rest/v1';

  static bool get isConfigured => anonKey.isNotEmpty;

  static Map<String, String> get restHeaders => {
        'apikey': anonKey,
        'Authorization': 'Bearer $anonKey',
        'Content-Type': 'application/json',
      };
}
