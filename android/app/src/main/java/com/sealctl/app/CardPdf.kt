package com.sealctl.app

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import android.os.Bundle
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.print.PageRange
import android.print.PrintAttributes
import android.print.PrintDocumentAdapter
import android.print.PrintDocumentInfo
import android.print.PrintManager
import androidx.core.content.FileProvider
import java.io.File
import java.io.FileOutputStream

/**
 * The blank card (SPEC.md 11.3 step 3): 24 numbered lines with four boxes each, a box for the
 * words fingerprint and the date. Blank: no words, no fingerprint, no date.
 */
object CardPdf {
    fun file(context: Context, letter: Boolean): File {
        val dir = File(context.cacheDir, "cards").apply { mkdirs() }
        val f = File(dir, if (letter) "sealctl-card-letter.pdf" else "sealctl-card-a4.pdf")
        if (!f.exists()) write(f, letter)
        return f
    }

    private fun write(f: File, letter: Boolean) {
        val (w, h) = if (letter) 612 to 792 else 595 to 842
        val doc = PdfDocument()
        val page = doc.startPage(PdfDocument.PageInfo.Builder(w, h, 1).create())
        val c = page.canvas
        val ink = Paint().apply { color = Color.rgb(0x1a, 0x21, 0x33); isAntiAlias = true }
        val line = Paint(ink).apply { strokeWidth = 0.8f; style = Paint.Style.STROKE }
        val mono = Paint(ink).apply { typeface = Typeface.MONOSPACE; textSize = 16f; isFakeBoldText = true }
        val small = Paint(ink).apply { textSize = 9f; color = Color.rgb(0x6b, 0x71, 0x83) }
        val num = Paint(ink).apply { typeface = Typeface.MONOSPACE; textSize = 10f }
        val margin = 48f
        c.drawText("sealctl", margin, margin + 8, mono)
        c.drawText("Write each word in full: first four letters in the boxes, the whole word on the line.", margin, margin + 26, small)
        c.drawText("Keep this card away from cameras. Anyone with it can open everything.", margin, margin + 38, small)
        val top = margin + 64
        val colW = (w - 2 * margin) / 2
        val rowH = (h - top - margin - 60) / 12
        for (i in 0 until 24) {
            val col = i / 12
            val row = i % 12
            val x = margin + col * colW
            val y = top + row * rowH
            c.drawText("${i + 1}".padStart(2), x, y + 14, num)
            for (b in 0 until 4) c.drawRect(x + 20 + b * 16, y + 2, x + 34 + b * 16, y + 18, line)
            c.drawLine(x + 90, y + 18, x + colW - 16, y + 18, line)
        }
        val by = h - margin - 40
        c.drawText("Words fingerprint", margin, by, small)
        for (b in 0 until 4) c.drawRect(margin + 90 + b * 16, by - 12, margin + 104 + b * 16, by + 4, line)
        c.drawText("Written on", margin + colW, by, small)
        c.drawLine(margin + colW + 56, by + 4, w - margin, by + 4, line)
        c.drawText("Retired on", margin, by + 26, small)
        c.drawLine(margin + 56, by + 30, margin + colW - 16, by + 30, line)
        doc.finishPage(page)
        FileOutputStream(f).use { doc.writeTo(it) }
        doc.close()
    }

    fun share(context: Context, letter: Boolean) {
        val uri = FileProvider.getUriForFile(context, "com.sealctl.app.files", file(context, letter))
        context.startActivity(
            Intent.createChooser(
                Intent(Intent.ACTION_SEND).setType("application/pdf").putExtra(Intent.EXTRA_STREAM, uri)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
                null,
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }

    fun print(context: Context, letter: Boolean) {
        val f = file(context, letter)
        val pm = context.getSystemService(PrintManager::class.java) ?: return
        pm.print("sealctl card", object : PrintDocumentAdapter() {
            override fun onLayout(old: PrintAttributes?, new: PrintAttributes, cancel: CancellationSignal?, cb: LayoutResultCallback, extras: Bundle?) {
                cb.onLayoutFinished(PrintDocumentInfo.Builder(f.name).setContentType(PrintDocumentInfo.CONTENT_TYPE_DOCUMENT).setPageCount(1).build(), true)
            }

            override fun onWrite(pages: Array<out PageRange>?, dest: ParcelFileDescriptor, cancel: CancellationSignal?, cb: WriteResultCallback) {
                FileOutputStream(dest.fileDescriptor).use { out -> f.inputStream().use { it.copyTo(out) } }
                cb.onWriteFinished(arrayOf(PageRange.ALL_PAGES))
            }
        }, PrintAttributes.Builder().setMediaSize(if (letter) PrintAttributes.MediaSize.NA_LETTER else PrintAttributes.MediaSize.ISO_A4).build())
    }
}
