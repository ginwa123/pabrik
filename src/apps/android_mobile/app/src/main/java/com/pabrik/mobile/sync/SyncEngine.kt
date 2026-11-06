package com.pabrik.mobile.sync

// Pure LWW merge of two entity lists. Remote wins ties (>=). Deleted entities
// (isDeleted) are dropped from the merged result.
object SyncEngine {
    fun <T : Syncable> merge(local: List<T>, remote: List<T>): List<T> {
        val localById = local.associateBy { it.syncId }
        val remoteById = remote.associateBy { it.syncId }
        val allIds = (localById.keys + remoteById.keys)
        val result = mutableListOf<T>()
        for (id in allIds) {
            val l = localById[id]
            val r = remoteById[id]
            when {
                l == null && r != null -> if (!r.isDeleted) result.add(r)
                r == null && l != null -> if (!l.isDeleted) result.add(l)
                l != null && r != null -> {
                    val winner = if (r.updatedAtEpochMillis >= l.updatedAtEpochMillis) r else l
                    if (!winner.isDeleted) result.add(winner)
                }
            }
        }
        return result
    }

    // Returns ids present locally but missing remotely (candidates to push up).
    fun <T : Syncable> localOnly(local: List<T>, remote: List<T>): List<String> {
        val remoteIds = remote.map { it.syncId }.toSet()
        return local.filter { it.syncId !in remoteIds && !it.isDeleted }.map { it.syncId }
    }

    // Returns ids present remotely but missing locally (candidates to pull down).
    fun <T : Syncable> remoteOnly(local: List<T>, remote: List<T>): List<String> {
        val localIds = local.map { it.syncId }.toSet()
        return remote.filter { it.syncId !in localIds && !it.isDeleted }.map { it.syncId }
    }
}
