package com.pabrik.mobile.workspace

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class McpServersHelperTest {

    @Test
    fun aCommandEntryParsesAsStdio() {
        val servers = McpServersHelper.parseServers(mapOf("fs" to RawMcpEntry(command = "npx")))
        assertEquals("stdio", servers.single().transport)
        assertEquals("npx", servers.single().command)
    }

    @Test
    fun aUrlEntryParsesAsHttp() {
        val servers = McpServersHelper.parseServers(mapOf("web" to RawMcpEntry(url = "https://x")))
        assertEquals("http", servers.single().transport)
        assertEquals("https://x", servers.single().url)
    }

    @Test
    fun anEntryWithNeitherCommandNorUrlIsDropped() {
        assertTrue(McpServersHelper.parseServers(mapOf("bad" to RawMcpEntry())).isEmpty())
    }

    @Test
    fun aNullMapParsesToNothing() {
        assertTrue(McpServersHelper.parseServers(null).isEmpty())
    }

    @Test
    fun serversAreSortedByName() {
        val servers = McpServersHelper.parseServers(
            mapOf("zeta" to RawMcpEntry(command = "a"), "alpha" to RawMcpEntry(command = "b")),
        )
        assertEquals(listOf("alpha", "zeta"), servers.map { it.name })
    }

    @Test
    fun httpHeadersAreParsed() {
        val servers = McpServersHelper.parseServers(
            mapOf("web" to RawMcpEntry(url = "https://x", headers = mapOf("Authorization" to "Bearer t"))),
        )
        assertEquals(listOf(McpHeader("Authorization", "Bearer t")), servers.single().headers)
    }

    @Test
    fun aDisabledEntryStaysDisabled() {
        val servers = McpServersHelper.parseServers(mapOf("fs" to RawMcpEntry(command = "npx", enabled = false)))
        assertFalse(servers.single().enabled)
    }

    @Test
    fun aStdioServerSerializesBackToACommandEntry() {
        val raw = McpServersHelper.serializeServers(
            listOf(McpServer(name = "fs", transport = "stdio", command = "npx", args = listOf("-y"))),
        )
        assertEquals("npx", raw.getValue("fs").command)
        assertEquals(listOf("-y"), raw.getValue("fs").args)
    }

    @Test
    fun anHttpServerSerializesBackToAUrlEntry() {
        val raw = McpServersHelper.serializeServers(
            listOf(McpServer(name = "web", transport = "http", url = "https://x")),
        )
        assertEquals("https://x", raw.getValue("web").url)
    }

    @Test
    fun aServerWithoutItsRequiredFieldIsDroppedOnSerialize() {
        assertTrue(McpServersHelper.serializeServers(listOf(McpServer(name = "fs", transport = "stdio"))).isEmpty())
    }

    @Test
    fun aHeaderKeyWithASpaceIsInvalid() {
        assertFalse(McpServersHelper.isValidHeaderKey("Bad Key"))
    }

    @Test
    fun aHeaderKeyWithAColonIsInvalid() {
        assertFalse(McpServersHelper.isValidHeaderKey("Bad:Key"))
    }

    @Test
    fun aPlainHeaderKeyIsValid() {
        assertTrue(McpServersHelper.isValidHeaderKey("Authorization"))
    }

    @Test
    fun duplicateHeaderKeysAreReported() {
        val headers = listOf(McpHeader("A", "1"), McpHeader("A", "2"), McpHeader("B", "3"))
        assertEquals(listOf("A"), McpServersHelper.duplicateHeaderKeys(headers))
    }

    @Test
    fun noDuplicatesYieldsAnEmptyList() {
        assertTrue(McpServersHelper.duplicateHeaderKeys(listOf(McpHeader("A", "1"))).isEmpty())
    }

    @Test
    fun anHttpsUrlIsValid() {
        assertTrue(McpServersHelper.isValidUrl("https://example.com"))
    }

    @Test
    fun anHttpUrlIsValid() {
        assertTrue(McpServersHelper.isValidUrl("http://example.com"))
    }

    @Test
    fun aUrlWithoutASchemeIsInvalid() {
        assertFalse(McpServersHelper.isValidUrl("example.com"))
    }
}
