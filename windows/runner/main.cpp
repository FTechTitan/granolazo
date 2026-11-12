#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>
#include <vector>

#include "consola_channel.h"
#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments = GetCommandLineArguments();

  // Modo consola: la misma app corre sin ventana y responde por la salida estandar.
  // La regla es la misma que aplica GranolazoCli.esInvocacionDeConsola en Dart, y tiene
  // que quedar igual en los dos lados: el motor de Flutter inyecta sus propias banderas
  // (siempre con guiones) en modo depuracion, asi que un argumento suelto SIN guiones es
  // lo que distingue a una persona o un script.
  bool modo_consola = false;
  for (const std::string &argumento : command_line_arguments) {
    if (argumento.empty()) continue;
    if (argumento.front() != '-' || argumento == "--ayuda" ||
        argumento == "--help" || argumento == "-h") {
      modo_consola = true;
      break;
    }
  }

  // OJO: AttachConsole reemplaza los descriptores estandar por los de la consola a la
  // que se engancha, y con eso se lleva puesta la redireccion que haya puesto el shell.
  // Medido el 2026-09-18: con la salida a un archivo o a una tuberia, el destino quedaba
  // vacio porque escribiamos en la consola del padre. Por eso se guardan antes y se
  // reponen si eran validos; si no habia ninguno -lanzada desde el escritorio- se deja
  // lo que haya dejado AttachConsole.
  HANDLE salida_heredada = ::GetStdHandle(STD_OUTPUT_HANDLE);
  HANDLE error_heredado = ::GetStdHandle(STD_ERROR_HANDLE);
  FijarDescriptoresDeSalida(salida_heredada, error_heredado);

  // Arrancada por el sistema al encender: la app va a la bandeja y NO se muestra
  // ventana. Tiene que decidirse aca y no del lado Dart: este arranque llama a Show()
  // en el primer cuadro por su cuenta, asi que esconderla despues desde Dart deja ver
  // un parpadeo -o directamente no la esconde, como paso el 2026-09-19-.
  bool arranca_en_bandeja = false;
  for (const std::string &argumento : command_line_arguments) {
    if (argumento == "--bandeja") {
      arranca_en_bandeja = true;
      break;
    }
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project,
                       /*mostrar_ventana=*/!modo_consola && !arranca_en_bandeja);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Granolazo", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
