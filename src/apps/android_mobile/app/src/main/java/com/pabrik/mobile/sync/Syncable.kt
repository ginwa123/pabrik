package com.pabrik.mobile.sync

// Contract for an entity that participates in LWW sync. Implementations are
// plain data classes; the engine is pure and has no I/O.
interface Syncable {
    val syncId: String
    val updatedAtEpochMillis: Long
    val isDeleted: Boolean
}
