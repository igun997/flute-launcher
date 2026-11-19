package id.nst.focus_launcher

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.content.FileProvider
import java.io.File
import java.io.IOException

/**
 * Files the agent made (reports, CSV, PDF, pictures): share, open and save to Downloads.
 * Only files inside the app's outputs and images folders are touched; every other path is refused.
 */
object FluteFiles {
    private const val DEFAULT_MIME = "application/octet-stream"
    private const val AUTHORITY_SUFFIX = ".files"
    private const val MAX_NAME_TRIES = 200

    /** Opens the system share chooser for [path]. True once the chooser has started. */
    fun share(context: Context, path: String, mime: String, name: String): Boolean {
        val file = ownedFile(context, path) ?: return false
        val uri = uriFor(context, file)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = mimeOrDefault(mime)
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = ClipData.newRawUri(name, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val chooser = Intent.createChooser(send, name).apply {
            clipData = send.clipData
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return start(context, chooser)
    }

    /** Opens [path] in an app that handles [mime]. False when no app can, or the path is refused. */
    fun open(context: Context, path: String, mime: String): Boolean {
        val file = ownedFile(context, path) ?: return false
        val uri = uriFor(context, file)
        val view = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mimeOrDefault(mime))
            clipData = ClipData.newRawUri("", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return start(context, view)
    }

    /**
     * Copies [path] into the public Downloads folder under [name], or a free variant of it.
     * Returns the name saved, or null on failure and before Android 10 (MediaStore Downloads).
     * Call from a worker thread.
     */
    fun saveToDownloads(context: Context, path: String, name: String, mime: String): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val file = ownedFile(context, path) ?: return null
        val resolver = context.contentResolver
        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val wanted = uniqueName(resolver, collection, safeName(name, file))
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, wanted)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeOrDefault(mime))
            put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val item = resolver.insert(collection, values) ?: return null
        return try {
            val out = resolver.openOutputStream(item) ?: throw IOException("no output stream")
            out.use { stream -> file.inputStream().use { it.copyTo(stream) } }
            resolver.update(
                item,
                ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) },
                null,
                null,
            )
            // MediaStore may still rename on a clash with a file this app cannot see: report the real name.
            savedName(resolver, item) ?: wanted
        } catch (e: Exception) {
            // Class name only: the file name and path must not reach logs or the UI.
            resolver.delete(item, null, null)
            null
        }
    }

    /** Folders under the app's files directory that results are written to; nothing else is shared. */
    private val sharedFolders = listOf("outputs", "images")

    /** The file at [path] when it is a regular file inside a shared folder, symlinks resolved. */
    private fun ownedFile(context: Context, path: String): File? {
        val file = try {
            File(path).canonicalFile
        } catch (e: IOException) {
            return null
        }
        if (!file.isFile) return null
        val roots = sharedFolders.map { File(context.filesDir, it).canonicalFile }
        return file.takeIf { f -> roots.any { f.path.startsWith(it.path + File.separator) } }
    }

    private fun uriFor(context: Context, file: File): Uri =
        FileProvider.getUriForFile(context, context.packageName + AUTHORITY_SUFFIX, file)

    /** Starts [intent]. False when no activity can take it, instead of throwing. */
    private fun start(context: Context, intent: Intent): Boolean {
        // The channel hands us the application context: an activity must be started in a new task.
        if (context !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            context.startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        } catch (e: SecurityException) {
            false
        }
    }

    private fun mimeOrDefault(mime: String): String = mime.ifBlank { DEFAULT_MIME }

    /** The last path segment, without separators (MediaStore rejects '/'); the file's own name when blank. */
    private fun safeName(name: String, file: File): String {
        val clean = name.substringAfterLast('/').substringAfterLast('\\').trim()
        return clean.ifBlank { file.name }
    }

    /** [name], or "stem (2).ext", "stem (3).ext", ... whichever no Downloads entry uses yet. */
    private fun uniqueName(resolver: ContentResolver, collection: Uri, name: String): String {
        val dot = name.lastIndexOf('.').takeIf { it > 0 } ?: name.length
        val stem = name.substring(0, dot)
        val ext = name.substring(dot)
        var candidate = name
        var n = 2
        while (n < MAX_NAME_TRIES && nameTaken(resolver, collection, candidate)) {
            candidate = "$stem ($n)$ext"
            n++
        }
        return candidate
    }

    private fun nameTaken(resolver: ContentResolver, collection: Uri, name: String): Boolean =
        resolver.query(
            collection,
            arrayOf(MediaStore.MediaColumns._ID),
            "${MediaStore.MediaColumns.DISPLAY_NAME} = ?",
            arrayOf(name),
            null,
        )?.use { it.moveToFirst() } ?: false

    private fun savedName(resolver: ContentResolver, item: Uri): String? =
        resolver.query(item, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
}
