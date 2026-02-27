package com.example.jorat_geofence

import android.content.ContentUris
import android.content.ContentValues
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    companion object {
        private const val DOWNLOAD_CHANNEL = "jorat/downloads"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DOWNLOAD_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "saveCsvToDownloads") {
                    val fileName = call.argument<String>("fileName")
                    val content = call.argument<String>("content")
                    if (fileName.isNullOrBlank() || content == null) {
                        result.error("INVALID_ARGS", "Paramètres fileName/content manquants", null)
                        return@setMethodCallHandler
                    }

                    try {
                        val location = saveCsvToDownloads(fileName, content)
                        result.success(location)
                    } catch (e: Exception) {
                        result.error("SAVE_FAILED", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun saveCsvToDownloads(fileName: String, content: String): String {
        val safeName = if (fileName.endsWith(".csv")) fileName else "$fileName.csv"
        val resolver = applicationContext.contentResolver

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val existingUri = findExistingDownloadUri(safeName)
            if (existingUri != null) {
                resolver.openOutputStream(existingUri, "wt")?.use { stream ->
                    stream.write(content.toByteArray(Charsets.UTF_8))
                } ?: throw IllegalStateException("Impossible d'écrire le fichier CSV existant")
                return existingUri.toString()
            }

            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, safeName)
                put(MediaStore.MediaColumns.MIME_TYPE, "text/csv")
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }

            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("Impossible de créer le fichier dans Téléchargements")

            try {
                resolver.openOutputStream(uri)?.use { stream ->
                    stream.write(content.toByteArray(Charsets.UTF_8))
                } ?: throw IllegalStateException("Impossible d'écrire le fichier CSV")

                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
                return uri.toString()
            } catch (e: Exception) {
                resolver.delete(uri, null, null)
                throw e
            }
        }

        @Suppress("DEPRECATION")
        val downloadsDir = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOWNLOADS
        )
        if (!downloadsDir.exists()) {
            downloadsDir.mkdirs()
        }

        val file = File(downloadsDir, safeName)
        file.writeText(content, Charsets.UTF_8)
        return file.absolutePath
    }

    private fun findExistingDownloadUri(fileName: String): Uri? {
        val resolver = applicationContext.contentResolver
        val projection = arrayOf(MediaStore.MediaColumns._ID)
        val selection = "${MediaStore.MediaColumns.DISPLAY_NAME} = ?"
        val selectionArgs = arrayOf(fileName)

        resolver.query(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            projection,
            selection,
            selectionArgs,
            "${MediaStore.MediaColumns.DATE_MODIFIED} DESC"
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val idColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                val id = cursor.getLong(idColumn)
                return ContentUris.withAppendedId(MediaStore.Downloads.EXTERNAL_CONTENT_URI, id)
            }
        }

        return null
    }
}
