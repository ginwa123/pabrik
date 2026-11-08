package com.pabrik.mobile.git

import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GitCommitsHelperTest {

    private val utc: ZoneId = ZoneId.of("UTC")

    @Test
    fun aSingleNameUsesItsFirstTwoLetters() {
        assertEquals("Al", GitCommitsHelper.authorInitials("Alice"))
    }

    @Test
    fun aFullNameUsesFirstAndLastInitials() {
        assertEquals("AD", GitCommitsHelper.authorInitials("Alice Doe"))
    }

    @Test
    fun aMiddleNameIsIgnored() {
        assertEquals("AD", GitCommitsHelper.authorInitials("Alice B. Doe"))
    }

    @Test
    fun anEmptyNameFallsBackToAQuestionMark() {
        assertEquals("?", GitCommitsHelper.authorInitials("   "))
    }

    @Test
    fun footerShowsLoadedOfTotalWhenTotalIsKnown() {
        assertEquals("20 of 100", GitCommitsHelper.footerLabel(20, 100))
    }

    @Test
    fun footerShowsOnlyLoadedWhenTotalIsUnknown() {
        assertEquals("20", GitCommitsHelper.footerLabel(20, 0))
    }

    @Test
    fun morePagesExistWhileLoadedIsBelowTotal() {
        assertTrue(GitCommitsHelper.hasMore(20, 100))
    }

    @Test
    fun noMorePagesExistWhenEverythingIsLoaded() {
        assertFalse(GitCommitsHelper.hasMore(100, 100))
    }

    @Test
    fun shortShaKeepsSevenCharacters() {
        assertEquals("abc1234", GitCommitsHelper.shortSha("abc1234def5678"))
    }

    @Test
    fun aZeroTimestampRendersEmpty() {
        assertEquals("", GitCommitsHelper.formatDate(0, utc))
    }

    @Test
    fun aTimestampRendersAsAMonthDayYearDate() {
        assertEquals("Jan 1, 2026", GitCommitsHelper.formatDate(1_767_225_600, utc))
    }
}
