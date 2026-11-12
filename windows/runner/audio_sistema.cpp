#include "audio_sistema.h"

#include <audioclient.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <mmdeviceapi.h>
#include <windows.h>

#include <atomic>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr char kNombreDelCanal[] = "granolazo/audio_sistema";

// Cuanto esperar entre lecturas del buffer. WASAPI avisa por evento, pero con sondeo
// alcanza y el codigo queda mucho mas simple; 10 ms es holgado frente al buffer por
// defecto, que ronda los 10-30 ms.
constexpr DWORD kPausaEntreLecturasMs = 10;

// Nivel que se informa cuando no entra nada, en dBFS. Coincide con el piso que usa el
// medidor del microfono del lado Dart.
constexpr double kSilencio = -160.0;

class CapturaDelSistema {
 public:
  ~CapturaDelSistema() { Detener(); }

  // Arranca la captura hacia |ruta|. Devuelve un mensaje de error, o cadena vacia si
  // salio bien.
  std::string Iniciar(const std::wstring& ruta) {
    if (corriendo_.load()) return "ya hay una captura en curso";
    error_.clear();
    nivel_.store(kSilencio);
    listo_ = false;
    corriendo_.store(true);
    hilo_ = std::thread([this, ruta] { Bucle(ruta); });

    // Se espera a que el hilo confirme que pudo abrir el dispositivo: si falla, hay que
    // poder decirlo en el momento y no dejar al usuario grabando sin la mitad del audio.
    std::unique_lock<std::mutex> cerrojo(mutex_);
    listo_cv_.wait(cerrojo, [this] { return listo_; });
    if (!error_.empty()) {
      corriendo_.store(false);
      if (hilo_.joinable()) hilo_.join();
      return error_;
    }
    return "";
  }

  void Detener() {
    if (!corriendo_.exchange(false)) return;
    if (hilo_.joinable()) hilo_.join();
  }

  bool Capturando() const { return corriendo_.load(); }
  double Nivel() const { return nivel_.load(); }

 private:
  // Cabecera WAV. Se escribe al empezar con los tamanos en cero y se corrige al cerrar,
  // que es lo que hace cualquier grabador: no se sabe cuanto va a durar.
  struct CabeceraWav {
    char riff[4] = {'R', 'I', 'F', 'F'};
    uint32_t tamanoTotal = 0;
    char wave[4] = {'W', 'A', 'V', 'E'};
    char fmt[4] = {'f', 'm', 't', ' '};
    uint32_t tamanoFmt = 16;
    uint16_t formato = 1;
    uint16_t canales = 2;
    uint32_t muestrasPorSegundo = 48000;
    uint32_t bytesPorSegundo = 0;
    uint16_t alineacion = 0;
    uint16_t bitsPorMuestra = 16;
    char data[4] = {'d', 'a', 't', 'a'};
    uint32_t tamanoDatos = 0;
  };

  void Avisar(const std::string& error) {
    {
      std::lock_guard<std::mutex> cerrojo(mutex_);
      error_ = error;
      listo_ = true;
    }
    listo_cv_.notify_all();
  }

  void Bucle(const std::wstring& ruta) {
    // El hilo necesita su propio COM: el del hilo principal no vale aca.
    const HRESULT comOk = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool desinicializar = SUCCEEDED(comOk);

    IMMDeviceEnumerator* enumerador = nullptr;
    IMMDevice* dispositivo = nullptr;
    IAudioClient* cliente = nullptr;
    IAudioCaptureClient* captura = nullptr;
    WAVEFORMATEX* formato = nullptr;
    FILE* archivo = nullptr;
    uint32_t bytesEscritos = 0;
    bool esFlotanteRef = false;

    auto limpiar = [&]() {
      if (archivo) {
        // Recien ahora se conocen los tamanos: se vuelve al principio y se corrigen.
        CabeceraWav cab;
        if (formato) {
          // OJO: se escribe el formato RESUELTO, no WAVE_FORMAT_EXTENSIBLE.
          //
          // WASAPI casi siempre entrega EXTENSIBLE, pero ese valor exige una cabecera
          // `fmt ` de 40 bytes con el GUID del subformato; declararlo con los 16 bytes de
          // la cabecera basica produce un WAV invalido. Paso el 2026-09-18: el archivo se
          // escribia bien pero ffmpeg no podia leerlo y la mezcla salia vacia.
          cab.formato = esFlotanteRef ? WAVE_FORMAT_IEEE_FLOAT : WAVE_FORMAT_PCM;
          cab.canales = formato->nChannels;
          cab.muestrasPorSegundo = formato->nSamplesPerSec;
          cab.bytesPorSegundo = formato->nAvgBytesPerSec;
          cab.alineacion = formato->nBlockAlign;
          cab.bitsPorMuestra = formato->wBitsPerSample;
        }
        cab.tamanoDatos = bytesEscritos;
        cab.tamanoTotal = 36 + bytesEscritos;
        ::fseek(archivo, 0, SEEK_SET);
        ::fwrite(&cab, sizeof(cab), 1, archivo);
        ::fclose(archivo);
      }
      if (captura) captura->Release();
      if (cliente) cliente->Release();
      if (dispositivo) dispositivo->Release();
      if (enumerador) enumerador->Release();
      if (formato) ::CoTaskMemFree(formato);
      if (desinicializar) ::CoUninitialize();
    };

    HRESULT hr = ::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                    __uuidof(IMMDeviceEnumerator),
                                    reinterpret_cast<void**>(&enumerador));
    if (FAILED(hr)) {
      Avisar("no pude enumerar los dispositivos de audio");
      limpiar();
      return;
    }

    // eRender + loopback: se escucha lo que sale por los parlantes.
    hr = enumerador->GetDefaultAudioEndpoint(eRender, eConsole, &dispositivo);
    if (FAILED(hr)) {
      Avisar("este equipo no tiene salida de audio predeterminada");
      limpiar();
      return;
    }

    hr = dispositivo->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                               reinterpret_cast<void**>(&cliente));
    if (FAILED(hr)) {
      Avisar("no pude abrir la salida de audio");
      limpiar();
      return;
    }

    hr = cliente->GetMixFormat(&formato);
    if (FAILED(hr) || formato == nullptr) {
      Avisar("no pude leer el formato de la salida de audio");
      limpiar();
      return;
    }

    // Un segundo de buffer: de sobra para un bucle que lee cada 10 ms.
    hr = cliente->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK,
                             10000000, 0, formato, nullptr);
    if (FAILED(hr)) {
      Avisar("la salida de audio no admite captura en modo loopback");
      limpiar();
      return;
    }

    hr = cliente->GetService(__uuidof(IAudioCaptureClient),
                             reinterpret_cast<void**>(&captura));
    if (FAILED(hr)) {
      Avisar("no pude obtener el lector de la salida de audio");
      limpiar();
      return;
    }

    if (::_wfopen_s(&archivo, ruta.c_str(), L"wb") != 0 || archivo == nullptr) {
      Avisar("no pude crear el archivo del audio del sistema");
      limpiar();
      return;
    }
    CabeceraWav cabeceraVacia;
    ::fwrite(&cabeceraVacia, sizeof(cabeceraVacia), 1, archivo);

    hr = cliente->Start();
    if (FAILED(hr)) {
      Avisar("no pude arrancar la captura de la salida de audio");
      limpiar();
      return;
    }

    Avisar("");  // listo, sin error

    const bool esFlotante =
        formato->wBitsPerSample == 32 &&
        (formato->wFormatTag == WAVE_FORMAT_IEEE_FLOAT ||
         (formato->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
          reinterpret_cast<WAVEFORMATEXTENSIBLE*>(formato)->SubFormat ==
              KSDATAFORMAT_SUBTYPE_IEEE_FLOAT));
    esFlotanteRef = esFlotante;

    while (corriendo_.load()) {
      UINT32 disponible = 0;
      if (FAILED(captura->GetNextPacketSize(&disponible))) break;
      if (disponible == 0) {
        ::Sleep(kPausaEntreLecturasMs);
        continue;
      }

      while (disponible > 0) {
        BYTE* datos = nullptr;
        UINT32 cuadros = 0;
        DWORD banderas = 0;
        if (FAILED(captura->GetBuffer(&datos, &cuadros, &banderas, nullptr, nullptr))) {
          break;
        }
        const UINT32 bytes = cuadros * formato->nBlockAlign;

        if (banderas & AUDCLNT_BUFFERFLAGS_SILENT) {
          // WASAPI entrega el buffer sin rellenar cuando no suena nada: hay que escribir
          // los ceros igual, o el audio del sistema quedaria corrido respecto del
          // microfono al mezclarlos.
          std::vector<BYTE> ceros(bytes, 0);
          ::fwrite(ceros.data(), 1, bytes, archivo);
          nivel_.store(kSilencio);
        } else {
          ::fwrite(datos, 1, bytes, archivo);
          nivel_.store(PicoEnDbfs(datos, cuadros, *formato, esFlotante));
        }
        bytesEscritos += bytes;

        captura->ReleaseBuffer(cuadros);
        if (FAILED(captura->GetNextPacketSize(&disponible))) {
          disponible = 0;
        }
      }
    }

    cliente->Stop();
    nivel_.store(kSilencio);
    limpiar();
  }

  // Pico del bloque, en dBFS. Se usa para el medidor: sirve saber si entra algo, no el
  // valor exacto.
  static double PicoEnDbfs(const BYTE* datos, UINT32 cuadros, const WAVEFORMATEX& f,
                           bool esFlotante) {
    double pico = 0.0;
    const UINT32 muestras = cuadros * f.nChannels;
    if (esFlotante) {
      const float* p = reinterpret_cast<const float*>(datos);
      for (UINT32 i = 0; i < muestras; i++) {
        const double v = std::fabs(static_cast<double>(p[i]));
        if (v > pico) pico = v;
      }
    } else if (f.wBitsPerSample == 16) {
      const int16_t* p = reinterpret_cast<const int16_t*>(datos);
      for (UINT32 i = 0; i < muestras; i++) {
        const double v = std::fabs(static_cast<double>(p[i])) / 32768.0;
        if (v > pico) pico = v;
      }
    } else {
      return kSilencio;
    }
    if (pico <= 0.0000001) return kSilencio;
    return 20.0 * std::log10(pico);
  }

  std::atomic<bool> corriendo_{false};
  std::atomic<double> nivel_{kSilencio};
  std::thread hilo_;
  std::mutex mutex_;
  std::condition_variable listo_cv_;
  bool listo_ = false;
  std::string error_;
};

CapturaDelSistema g_captura;

std::wstring AnchoDesdeUtf8(const std::string& s) {
  if (s.empty()) return std::wstring();
  const int largo =
      ::MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
  std::wstring salida(largo, L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), salida.data(),
                        largo);
  return salida;
}

}  // namespace

void RegistrarCanalDeAudioDelSistema(flutter::FlutterEngine* engine) {
  auto canal = std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), kNombreDelCanal,
      &flutter::StandardMethodCodec::GetInstance());

  canal->SetMethodCallHandler(
      [canal](const flutter::MethodCall<flutter::EncodableValue>& llamada,
              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> resultado) {
        const std::string& metodo = llamada.method_name();

        if (metodo == "iniciar") {
          const auto* ruta = std::get_if<std::string>(llamada.arguments());
          if (ruta == nullptr) {
            resultado->Error("argumento", "se esperaba la ruta del archivo");
            return;
          }
          const std::string error = g_captura.Iniciar(AnchoDesdeUtf8(*ruta));
          if (error.empty()) {
            resultado->Success(flutter::EncodableValue(true));
          } else {
            resultado->Error("captura", error);
          }
          return;
        }

        if (metodo == "detener") {
          g_captura.Detener();
          resultado->Success();
          return;
        }

        if (metodo == "nivel") {
          resultado->Success(flutter::EncodableValue(g_captura.Nivel()));
          return;
        }

        if (metodo == "capturando") {
          resultado->Success(flutter::EncodableValue(g_captura.Capturando()));
          return;
        }

        resultado->NotImplemented();
      });
}
