#ifndef RUNNER_CONSOLA_CHANNEL_H_
#define RUNNER_CONSOLA_CHANNEL_H_

#include <flutter/flutter_engine.h>
#include <windows.h>

// Canal que le presta al lado Dart la salida estandar y la terminacion del proceso.
//
// Por que existe: el ejecutable se enlaza como aplicacion de ventanas, y en ese modo el
// `stdout` que ve Dart no queda conectado al descriptor real que dio la terminal. Medido
// el 2026-09-18: con la salida redirigida a un archivo, el archivo quedaba vacio y
// `exit()` de Dart ni siquiera terminaba el proceso, porque el bucle de mensajes de Win32
// sigue corriendo en el hilo principal.
//
// La solucion es no pelear con eso: el lado nativo, que si tiene el descriptor bueno,
// escribe con WriteFile y termina con ExitProcess. Los detalles del envoltorio quedan de
// este lado y el codigo de la aplicacion no se entera.

// Guarda los descriptores que entrego el shell ANTES de que nadie los toque.
//
// Hay dos cosas que los pisan: AttachConsole, que los cambia por los de la consola a la
// que se engancha, y la resincronizacion de flujos del motor de Flutter, que reabre
// CONOUT$. Con una copia propia el canal escribe siempre donde corresponde, sin importar
// lo que hagan despues. Se aceptan descriptores invalidos: en ese caso se consulta el
// descriptor vigente al momento de escribir.
void FijarDescriptoresDeSalida(HANDLE salida, HANDLE error);

void RegistrarCanalDeConsola(flutter::FlutterEngine* engine);

#endif  // RUNNER_CONSOLA_CHANNEL_H_
