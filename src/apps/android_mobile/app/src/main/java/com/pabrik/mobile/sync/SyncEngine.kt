package com.pabrik.mobile.sync

object SyncEngine {

    fun <T : Syncable<T>> merge(local: List<T>, remote: List<T>): List<T> {
        val localById = local.associateBy { it.syncId }
        val remoteById = remote.associateBy { it.syncId }
        val ids = localById.keys + remoteById.keys
        val merged = mutableListOf<T>()
        for (id in ids) {
            val l = localById[id]
            val r = remoteById[id]
            val winner: T? = when {
                l == null -> r
                r == null -> l
                r.updatedAtEpochMillis >= l.updatedAtEpochMillis -> r
                else -> l
            }
            if (winner != null && !winner.isDeleted) merged.add(winner)
        }
        return merged
    }

    fun <T : Syncable<T>> applyWrite(current: T?, incoming: T): T =
        when {
            current == null -> incoming
            incoming.updatedAtEpochMillis > current.updatedAtEpochMillis -> incoming
            else -> current
        }

    fun <T : Syncable<T>> delete(entity: T, nowMillis: Long): T =
        entity.asDeleted(nowMillis)

    fun <T : Syncable<T>> visible(entities: List<T>): List<T> =
        entities.filter { !it.isDeleted }

    fun <T : Syncable<T>> localOnly(local: List<T>, remote: List<T>): List<String> {
        val remoteIds = remote.map { it.syncId }.toSet()
        return local.filter { it.syncId !in remoteIds && !it.isDeleted }.map { it.syncId }
    }

    fun <T : Syncable<T>> remoteOnly(local: List<T>, remote: List<T>): List<String> {
        val localIds = local.map { it.syncId }.toSet()
        return remote.filter { it.syncId !in localIds && !it.isDeleted }.map { it.syncId }
    }
}
