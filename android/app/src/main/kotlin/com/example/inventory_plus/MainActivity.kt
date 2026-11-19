package com.example.inventory_plus

import android.Manifest
import android.content.ContentValues
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.io.IOException
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val downloadChannel = "inventory_plus/report_download"
    private val legacyPermissionRequest = 7412
    private var pendingLegacyDownload: Triple<String, ByteArray, MethodChannel.Result>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, downloadChannel)
            .setMethodCallHandler { call, result ->
                if (call.method != "savePdfToDownloads") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val rawName = call.argument<String>("fileName")
                val bytes = call.argument<ByteArray>("bytes")
                if (rawName.isNullOrBlank() || bytes == null) {
                    result.error("INVALID_REPORT", "Missing report name or PDF bytes", null)
                    return@setMethodCallHandler
                }
                val fileName = rawName.replace(Regex("[^A-Za-z0-9._-]"), "_")
                if (!fileName.endsWith(".pdf", ignoreCase = true)) {
                    result.error("INVALID_REPORT", "Report must be a PDF", null)
                    return@setMethodCallHandler
                }
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
                    checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
                    PackageManager.PERMISSION_GRANTED
                ) {
                    if (pendingLegacyDownload != null) {
                        result.error("DOWNLOAD_BUSY", "Another download is waiting for permission", null)
                        return@setMethodCallHandler
                    }
                    pendingLegacyDownload = Triple(fileName, bytes, result)
                    requestPermissions(
                        arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                        legacyPermissionRequest,
                    )
                    return@setMethodCallHandler
                }
                saveAsync(fileName, bytes, result)
            }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != legacyPermissionRequest) return
        val pending = pendingLegacyDownload ?: return
        pendingLegacyDownload = null
        if (grantResults.firstOrNull() != PackageManager.PERMISSION_GRANTED) {
            pending.third.error("PERMISSION_DENIED", "Downloads permission was denied", null)
            return
        }
        saveAsync(pending.first, pending.second, pending.third)
    }

    private fun saveAsync(fileName: String, bytes: ByteArray, result: MethodChannel.Result) {
        Thread {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    saveWithMediaStore(fileName, bytes)
                } else {
                    saveLegacy(fileName, bytes)
                }
                runOnUiThread { result.success("Downloads") }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("DOWNLOAD_FAILED", error.message ?: "Could not save PDF", null)
                }
            }
        }.start()
    }

    private fun saveWithMediaStore(fileName: String, bytes: ByteArray) {
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
            put(MediaStore.MediaColumns.MIME_TYPE, "application/pdf")
            put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IOException("Could not create Downloads entry")
        try {
            contentResolver.openOutputStream(uri, "w")?.use { it.write(bytes) }
                ?: throw IOException("Could not open Downloads entry")
            contentResolver.update(
                uri,
                ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) },
                null,
                null,
            )
        } catch (error: Exception) {
            contentResolver.delete(uri, null, null)
            throw error
        }
    }

    @Suppress("DEPRECATION")
    private fun saveLegacy(fileName: String, bytes: ByteArray) {
        val directory = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        if (!directory.exists() && !directory.mkdirs()) {
            throw IOException("Could not create Downloads directory")
        }
        File(directory, fileName).outputStream().use { it.write(bytes) }
    }
}
