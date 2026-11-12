# Compilar en Windows sin el componente ATL

`flutter_secure_storage_windows` usa ATL en su código nativo. En un equipo sin ese
componente de Visual Studio, la compilación aborta:

```
error C1083: No se puede abrir el archivo incluir: 'atlstr.h'
```

ATL viene con *C++ ATL for latest build tools*, que no está instalado en este PC y cuya
instalación exige permisos de administrador y unos cientos de megas de descarga.

## Qué usa el plugin, exactamente

Lo medimos sobre la versión 4.2.2. De toda ATL, el plugin usa **dos conversores de
texto**, en cinco lugares:

| Utilidad | Usos | Para qué |
|---|---|---|
| `CA2W` | 5 | pasar el nombre de una credencial a texto ancho antes de `CredReadW`, `CredDeleteW` y `CredEnumerateW` |
| `CW2A` | 1 | leer de vuelta el nombre que devuelve `CredEnumerateW` |

Nada más: ni punteros inteligentes, ni objetos COM, ni `CString`. Por eso este directorio
los reimplementa en 90 líneas sobre `MultiByteToWideChar` y `WideCharToMultiByte`, que son
las llamadas nativas de Windows que ATL envuelve.

## Una diferencia deliberada con ATL

ATL convierte usando la página de códigos ANSI del hilo. Nuestra versión usa **UTF-8**.

No es un descuido: las claves llegan desde Dart por el códec estándar de Flutter, que
entrega UTF-8. Convertirlas como ANSI corrompe cualquier carácter fuera de esa página —un
nombre de clave con tilde, por ejemplo—, así que el comportamiento de ATL era el
equivocado para este camino. Para texto ASCII, que es lo que guarda la app hoy, ambas
conversiones dan exactamente lo mismo.

## Cómo está enganchado

El `CMakeLists.txt` de `windows/` comprueba primero si el ATL de verdad está disponible y
**solo agrega esta carpeta al camino de inclusión cuando no lo está**. En un equipo con
ATL instalado, estos archivos nunca se usan y no hay riesgo de tapar la cabecera real.

El alcance está acotado a los plugins: la comprobación se hace después de agregar el
ejecutable de la app, así que el código propio no la ve.

El archivo `atlstr.h` está escrito solo en ASCII a propósito. La compilación corre con
`/W4 /WX`, y MSVC emite el aviso C4819 ante caracteres que no entran en la página de
códigos del sistema, lo que convertiría un comentario con tildes en un error de
compilación. La explicación con ortografía completa vive acá, en este documento.

## Cómo se revierte

Cuando el proyecto original deje de depender de ATL —o si se decide instalarlo en todas
las máquinas que compilen— borrar esta carpeta y las cinco líneas marcadas en
`windows/CMakeLists.txt`.

Para instalar ATL en lugar de usar este reemplazo (necesita administrador):

```powershell
& "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vs_installer.exe" modify `
  --installPath "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools" `
  --add Microsoft.VisualStudio.Component.VC.ATL --passive
```

## Seguimiento

Es el problema de los issues 356 y 596 de `juliansteenbakker/flutter_secure_storage`,
cerrados con la recomendación de instalar ATL en vez de quitar la dependencia. La rama
principal del proyecto original seguía igual al 2026-09-18.
