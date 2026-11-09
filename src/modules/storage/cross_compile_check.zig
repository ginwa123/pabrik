//! Cross-target compile check for the storage module's per-OS branches.
//! Cross-target compile check for the storage module's per-OS branches.
//! Never executed — only analysed, once per target, by `check:storage-cross`.

const storage = @import("storage.zig");
const fs_backend = @import("fs.zig");
const memory_backend = @import("memory.zig");
const sigv4 = @import("sigv4.zig");
const s3 = @import("s3.zig");
const rustfs = @import("rustfs.zig");
const rustfs_binary = @import("rustfs_binary.zig");

export fn pabrik_storage_cross_compile_check() callconv(.c) void {
    // The bundled-binary lookup: %LOCALAPPDATA% on Windows, XDG/HOME on POSIX.
    _ = &rustfs_binary.dataDir;
    _ = &rustfs_binary.resolveDefault;
    _ = &rustfs_binary.available;

    // The supervisor: the Windows job object and the POSIX pid sweep.
    _ = &rustfs.Supervisor.start;
    _ = &rustfs.Supervisor.deinit;

    // The filesystem backend's path handling (keys use `/` on every host).
    // `asStorage` forces the vtable, and with it put/get/delete/stat.
    _ = &fs_backend.FsStorage.open;
    _ = &fs_backend.FsStorage.asStorage;

    // Key validation and the document key layout.
    _ = &storage.documentKey;
    _ = &storage.invalidKeyReason;
    _ = &storage.sha256Hex;

    // The in-memory fake, the signer and the S3 backend.
    _ = &memory_backend.MemoryStorage.init;
    _ = &sigv4.authorization;
    _ = &s3.S3Storage.init;
}
