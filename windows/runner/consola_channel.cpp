#include "consola_channel.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>
#include <string>

namespace {

constexpr char kNombreDelCanal[] = "granolazo/consola";

HANDLE g_salida = nullptr;
HANDLE g_error = nullptr;

bool Utilizable(HANDLE h) {
  return h != nullptr && h != INVALID_HANDLE_VALUE;
}

HANDLE DescriptorDe(DWORD cual) {
  HANDLE guardado = (cual == STD_OUTPUT_HANDLE) ? g_salida : g_error;
  if (Utilizable(guardado)) return guardado;
  return ::GetStdHandle(cual);
}

// Escribe los bytes tal cual en el descriptor que haya: consola, tuberia o archivo.
// WriteFile no usa buffer propio, asi que no hay nada que vaciar despues y no se pierde
// texto si el proceso termina enseguida. Devuelve cuantos bytes entraron, o -1 si no
// habia donde escribir; el lado Dart lo usa para dejar rastro cuando algo falla.
int32_t Escribir(DWORD cual, const std::string& texto) {
  HANDLE destino = DescriptorDe(cual);
  if (!Utilizable(destino)) return -1;
  if (texto.empty()) return 0;
  DWORD escritos = 0;
  if (!::WriteFile(destino, texto.data(), static_cast<DWORD>(texto.size()), &escritos,
                   nullptr)) {
    return -static_cast<int32_t>(::GetLastError());
  }
  return static_cast<int32_t>(escritos);
}

const std::string* TextoDelArgumento(const flutter::EncodableValue* argumentos) {
  if (argumentos == nullptr) return nullptr;
  return std::get_if<std::string>(argumentos);
}

int CodigoDelArgumento(const flutter::EncodableValue* argumentos) {
  if (argumentos == nullptr) return 0;
  if (const auto* entero = std::get_if<int32_t>(argumentos)) return *entero;
  return 0;
}

// Copia propia del descriptor, con su vida independiente del original.
//
// Hace falta porque reabrir los flujos estandar (freopen sobre CONOUT$, que es lo que
// hacen tanto la plantilla del runner como la resincronizacion del motor) CIERRA el
// descriptor heredado. Medido el 2026-09-18: despues de eso WriteFile devolvia el error 6
// -descriptor invalido- y, peor, cuando Windows reciclaba ese numero para otro objeto la
// escritura "funcionaba" yendo a parar a cualquier lado.
HANDLE Duplicar(HANDLE original) {
  if (!Utilizable(original)) return nullptr;
  HANDLE copia = nullptr;
  if (!::DuplicateHandle(::GetCurrentProcess(), original, ::GetCurrentProcess(), &copia, 0,
                         FALSE, DUPLICATE_SAME_ACCESS)) {
    return nullptr;
  }
  return copia;
}

}  // namespace

void FijarDescriptoresDeSalida(HANDLE salida, HANDLE error) {
  g_salida = Duplicar(salida);
  g_error = Duplicar(error);
}

void RegistrarCanalDeConsola(flutter::FlutterEngine* engine) {
  // Los acentos viajan en UTF-8 desde Dart; sin esto la consola los dibuja mal.
  ::SetConsoleOutputCP(CP_UTF8);

  auto canal = std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), kNombreDelCanal,
      &flutter::StandardMethodCodec::GetInstance());

  canal->SetMethodCallHandler(
      [canal](const flutter::MethodCall<flutter::EncodableValue>& llamada,
              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> resultado) {
        const std::string& metodo = llamada.method_name();

        if (metodo == "escribir" || metodo == "escribirError") {
          const std::string* texto = TextoDelArgumento(llamada.arguments());
          if (texto == nullptr) {
            resultado->Error("argumento", "se esperaba una cadena");
            return;
          }
          const int32_t escritos =
              Escribir(metodo == "escribir" ? STD_OUTPUT_HANDLE : STD_ERROR_HANDLE, *texto);
          resultado->Success(flutter::EncodableValue(escritos));
          return;
        }

        if (metodo == "terminar") {
          // Corta aca mismo. No se devuelve resultado a proposito: el proceso ya no
          // existe cuando Dart podria leerlo.
          //
          // TerminateProcess y no ExitProcess: esta ultima corre los DllMain de descarga
          // despues de matar los hilos, y con los del motor de Flutter vivos se quedaba
          // colgada en el cerrojo del cargador. Aca no hay nada que vaciar -WriteFile ya
          // escribio- asi que cortar en seco es correcto.
          ::TerminateProcess(::GetCurrentProcess(),
                             static_cast<UINT>(CodigoDelArgumento(llamada.arguments())));
          return;
        }

        resultado->NotImplemented();
      });
}
