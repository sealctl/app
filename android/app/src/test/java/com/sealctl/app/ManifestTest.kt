package com.sealctl.app

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Test
import org.w3c.dom.Element

/** The exported surface (SPEC.md 10.2, 16.3). Unit tests run in the module directory. */
class ManifestTest {
    private val ns = "http://schemas.android.com/apk/res/android"

    private fun components(path: String): List<Element> {
        val f = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        val doc = f.newDocumentBuilder().parse(File(path))
        return listOf("activity", "receiver", "service", "provider").flatMap { tag ->
            val nodes = doc.getElementsByTagName(tag)
            (0 until nodes.length).map { nodes.item(it) as Element }
        }
    }

    private fun Element.attr(name: String) = getAttributeNS(ns, name)

    @Test
    fun onlyTheLauncherIsExported() {
        val all = components("src/main/AndroidManifest.xml")
        assertEquals(listOf(".MainActivity"), all.filter { it.attr("exported") == "true" }.map { it.attr("name") })
        val open = all.single { it.attr("name") == ".OpenActivity" }
        assertEquals("false", open.attr("exported"))
    }

    @Test
    fun debugPushReceiverNeedsDump() {
        val r = components("src/debug/AndroidManifest.xml").single { it.attr("name").endsWith("DebugPushReceiver") }
        assertEquals("android.permission.DUMP", r.attr("permission"))
    }
}
