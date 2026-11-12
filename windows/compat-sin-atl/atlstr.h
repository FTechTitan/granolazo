#pragma once
// Reemplazo minimo de las dos utilidades de ATL que usa
// flutter_secure_storage_windows. Solo entra al build cuando la maquina NO tiene
// ATL instalado. La explicacion completa esta en LEEME.md, en esta misma carpeta.
//
// El plugin usa exactamente CA2W (5 usos) y CW2A (1 uso) para convertir entre
// texto de 8 bits y texto ancho de Windows. Nada mas de ATL.

#include <windows.h>

#include <new>

namespace granolazo_compat {

// Las cadenas vienen y van por el codec estandar de Flutter, que es UTF-8. ATL
// convertia usando la pagina de codigos ANSI del hilo, lo que pierde caracteres
// fuera de esa pagina; UTF-8 es lo correcto aca y coincide con ANSI para ASCII.
constexpr UINT kPaginaCodigos = CP_UTF8;

inline wchar_t* g_ancho_vacio() {
  static wchar_t vacio[1] = {L'\0'};
  return vacio;
}

inline char* g_angosto_vacio() {
  static char vacio[1] = {'\0'};
  return vacio;
}

}  // namespace granolazo_compat

// De texto de 8 bits a texto ancho.
class CA2W {
 public:
  explicit CA2W(const char* origen) : m_psz(granolazo_compat::g_ancho_vacio()) {
    if (origen == nullptr) return;
    const int largo =
        ::MultiByteToWideChar(granolazo_compat::kPaginaCodigos, 0, origen, -1, nullptr, 0);
    if (largo <= 0) return;
    wchar_t* destino = new (std::nothrow) wchar_t[static_cast<size_t>(largo)];
    if (destino == nullptr) return;
    if (::MultiByteToWideChar(granolazo_compat::kPaginaCodigos, 0, origen, -1, destino,
                              largo) <= 0) {
      delete[] destino;
      return;
    }
    m_psz = destino;
  }

  ~CA2W() {
    if (m_psz != granolazo_compat::g_ancho_vacio()) delete[] m_psz;
  }

  CA2W(const CA2W&) = delete;
  CA2W& operator=(const CA2W&) = delete;

  operator LPCWSTR() const { return m_psz; }

  LPWSTR m_psz;
};

// De texto ancho a texto de 8 bits.
class CW2A {
 public:
  explicit CW2A(LPCWSTR origen) : m_psz(granolazo_compat::g_angosto_vacio()) {
    if (origen == nullptr) return;
    const int largo = ::WideCharToMultiByte(granolazo_compat::kPaginaCodigos, 0, origen, -1,
                                            nullptr, 0, nullptr, nullptr);
    if (largo <= 0) return;
    char* destino = new (std::nothrow) char[static_cast<size_t>(largo)];
    if (destino == nullptr) return;
    if (::WideCharToMultiByte(granolazo_compat::kPaginaCodigos, 0, origen, -1, destino, largo,
                              nullptr, nullptr) <= 0) {
      delete[] destino;
      return;
    }
    m_psz = destino;
  }

  ~CW2A() {
    if (m_psz != granolazo_compat::g_angosto_vacio()) delete[] m_psz;
  }

  CW2A(const CW2A&) = delete;
  CW2A& operator=(const CW2A&) = delete;

  operator LPSTR() const { return m_psz; }

  LPSTR m_psz;
};
