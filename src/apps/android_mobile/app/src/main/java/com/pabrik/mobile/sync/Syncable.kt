package com.pabrik.mobile.sync

interface Syncable<T : Syncable<T>> {
    val syncId: String
    val updatedAtEpochMillis: Long
    val isDeleted: Boolean

    fun asDeleted(updatedAtEpochMillis: Long): T
}
