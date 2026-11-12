#ifndef RUNNER_AUDIO_SISTEMA_H_
#define RUNNER_AUDIO_SISTEMA_H_

#include <flutter/flutter_engine.h>

// Captura el audio que SALE por los parlantes de este equipo.
//
// Por que hace falta: grabando solo el microfono, de una llamada queda una sola voz. Lo
// que dice el otro sale por los parlantes y el microfono no lo toma -y si lo tomara,
// entraria con eco y a media calidad-. Sin esto la app no sirve para transcribir
// reuniones, que es para lo que existe.
//
// Se hace con WASAPI en modo loopback, que es lo mismo que usan OBS y las apps de
// videollamada. La alternativa de usuario -habilitar "Mezcla estereo" en el panel de
// sonido- se descarto porque depende del driver, en este equipo esta deshabilitada y
// obliga a configurar algo a mano.
//
// El audio se escribe en un WAV con el formato nativo del dispositivo, sin convertir:
// convertir es trabajo de ffmpeg, que ya se usa para mezclarlo con el microfono.
void RegistrarCanalDeAudioDelSistema(flutter::FlutterEngine* engine);

#endif  // RUNNER_AUDIO_SISTEMA_H_
