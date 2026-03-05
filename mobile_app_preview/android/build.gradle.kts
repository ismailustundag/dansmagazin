allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

subprojects {
    project.evaluationDependsOn(":app")
}

subprojects {
    plugins.withId("com.android.library") {
        if (name == "image_gallery_saver") {
            extensions.findByName("android")?.let { androidExt ->
                val setNamespace = androidExt.javaClass.methods.firstOrNull {
                    it.name == "setNamespace" && it.parameterTypes.size == 1
                }
                setNamespace?.invoke(androidExt, "com.example.image_gallery_saver")
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
