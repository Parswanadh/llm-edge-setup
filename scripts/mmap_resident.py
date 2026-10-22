#!/usr/bin/env python3
"""Page-cache control + residency measurement for model files.

Uses mincore(2) for residency and posix_fadvise(2) for cache eviction/warming.
No root required (works on any file you can open read-only).

Usage:
  mmap_resident.py FILE...                    # report residency
  mmap_resident.py --evict FILE...            # POSIX_FADV_DONTNEED (drop clean page cache)
  mmap_resident.py --warm FILE...             # POSIX_FADV_WILLNEED (readahead into cache)
  mmap_resident.py --evict --warm FILE...     # evict then warm (cold->warm controlled)
"""
import ctypes
import ctypes.util
import os
import sys

libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)

libc.madvise.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
libc.madvise.restype = ctypes.c_int
libc.mincore.argtypes = [ctypes.c_void_p, ctypes.c_size_t,
                          ctypes.POINTER(ctypes.c_ubyte), ctypes.c_void_p]
libc.mincore.restype = ctypes.c_int
libc.mmap.restype = ctypes.c_void_p
libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int,
                      ctypes.c_int, ctypes.c_int, ctypes.c_long]
libc.munmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
libc.munmap.restype = ctypes.c_int
libc.posix_fadvise.argtypes = [ctypes.c_int, ctypes.c_long, ctypes.c_long, ctypes.c_int]
libc.posix_fadvise.restype = ctypes.c_int

MADV_WILLNEED = 3
MADV_DONTNEED = 4
POSIX_FADV_NORMAL = 0
POSIX_FADV_RANDOM = 1
POSIX_FADV_SEQUENTIAL = 2
POSIX_FADV_WILLNEED = 3
POSIX_FADV_DONTNEED = 4

PROT_READ = 1
MAP_PRIVATE = 2


def fadvise(path, advice):
    fd = os.open(path, os.O_RDONLY)
    try:
        rc = libc.posix_fadvise(ctypes.c_int(fd), ctypes.c_long(0),
                                ctypes.c_long(0), ctypes.c_int(advice))
        if rc != 0:
            raise OSError(rc, "posix_fadvise(%d) failed" % advice)
    finally:
        os.close(fd)


def residency(path):
    length = os.path.getsize(path)
    if length == 0:
        return 0, 0
    fd = os.open(path, os.O_RDONLY)
    try:
        addr = libc.mmap(None, ctypes.c_size_t(length), PROT_READ, MAP_PRIVATE,
                         ctypes.c_int(fd), ctypes.c_long(0))
    finally:
        os.close(fd)
    if addr is None or addr == ctypes.c_void_p(-1).value:
        err = ctypes.get_errno()
        raise OSError(err, "mmap failed: %s" % os.strerror(err))
    npages = (length + 4095) // 4096
    vec = (ctypes.c_ubyte * npages)()
    rc = libc.mincore(ctypes.c_void_p(addr), ctypes.c_size_t(length), vec, None)
    if rc != 0:
        err = ctypes.get_errno()
        libc.munmap(ctypes.c_void_p(addr), ctypes.c_size_t(length))
        raise OSError(err, "mincore failed: %s" % os.strerror(err))
    res = sum(1 for b in vec if b & 1)
    libc.munmap(ctypes.c_void_p(addr), ctypes.c_size_t(length))
    return length, res * 4096


def main():
    args = sys.argv[1:]
    evict = "--evict" in args
    warm = "--warm" in args
    args = [a for a in args if a not in ("--evict", "--warm")]
    for p in args:
        if evict:
            fadvise(p, POSIX_FADV_DONTNEED)
        if warm:
            fadvise(p, POSIX_FADV_WILLNEED)
        length, res = residency(p)
        print("%-92s size=%9.1fMiB resident=%9.1fMiB (%5.1f%%) missing=%9.1fMiB"
              % (p, length / 1048576.0, res / 1048576.0,
                 100.0 * res / max(1, length), (length - res) / 1048576.0))


if __name__ == "__main__":
    main()
