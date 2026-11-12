allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// Nivel minimo de API con el que compilan los plugins.
//
// Cada plugin de Flutter trae su propio `compileSdk` y algunos se quedan atras respecto de
// sus propias dependencias. Caso concreto (2026-09-18): `whisper_ggml` declara 34, pero
// arrastra `ffmpeg_kit_flutter_new_min`, que exige 35 o mas, y el build aborta en
// `checkReleaseAarMetadata` con un mensaje que no dice que hacer al respecto.
//
// En vez de esperar a que cada plugin se actualice, se los sube a todos a un piso comun.
// Subir el `compileSdk` no cambia contra que version corre la app -eso lo mandan `minSdk`
// y `targetSdk` de `app/build.gradle.kts`-, solo contra que APIs se compila.
//
// OJO CON EL ORDEN: este bloque tiene que ir ANTES del `evaluationDependsOn(":app")` de
// mas abajo. Aquel fuerza la evaluacion de los subproyectos, y registrar un
// `afterEvaluate` sobre un proyecto ya evaluado falla con "Cannot run
// Project.afterEvaluate(Action) when the project is already evaluated".
val compileSdkMinimoDeLosPlugins = 36

subprojects {
    afterEvaluate {
        val android = project.extensions.findByName("android") ?: return@afterEvaluate

        // Por reflexion a proposito: el tipo de la extension de Android cambio entre
        // versiones del plugin de Gradle y este archivo no lo aplica, asi que no hay una
        // clase estable que nombrar sin atarse a una version.
        val actual = runCatching {
            android.javaClass.getMethod("getCompileSdk").invoke(android) as? Int
        }.getOrNull()
        if (actual != null && actual >= compileSdkMinimoDeLosPlugins) return@afterEvaluate

        val setter = android.javaClass.methods.firstOrNull {
            it.name == "setCompileSdk" && it.parameterTypes.size == 1
        }
        if (setter == null) {
            // Falla ruidosa: si esto deja de funcionar, el build muere despues con un
            // error de metadatos del AAR que no apunta a este archivo.
            logger.warn(
                "granolazo: no encontre como fijar compileSdk en ${project.name}; " +
                    "si el build falla por checkReleaseAarMetadata, revisar " +
                    "android/build.gradle.kts"
            )
        } else {
            runCatching { setter.invoke(android, compileSdkMinimoDeLosPlugins) }
                .onFailure {
                    logger.warn(
                        "granolazo: no pude fijar compileSdk en ${project.name}: ${it.message}"
                    )
                }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
