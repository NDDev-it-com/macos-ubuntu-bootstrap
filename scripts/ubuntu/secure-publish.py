#!/usr/bin/env python3
"""Publish one root-owned file without following or replacing path objects."""

from __future__ import annotations

import argparse
import hashlib
import os
import stat
import sys

AUTHORITY_ROOT = "root-production"
AUTHORITY_SANDBOX = "actor-sandbox"


def identity(fd: int) -> tuple[int, int, int, int]:
    value = os.fstat(fd)
    return value.st_dev, value.st_ino, value.st_uid, stat.S_IMODE(value.st_mode)


def open_directory_chain(path: str) -> tuple[int, list[tuple[int, int, int, int]]]:
    if not path.startswith("/") or path == "/" or ".." in path.split("/"):
        raise ValueError("destination parent must be a canonical absolute path")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    identities = [identity(fd)]
    if identities[0][2] != 0 or identities[0][3] & 0o022:
        os.close(fd)
        raise PermissionError("filesystem root is not root-owned and non-writable")
    try:
        for component in filter(None, path.split("/")):
            next_fd = os.open(
                component,
                os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
                dir_fd=fd,
            )
            os.close(fd)
            fd = next_fd
            current = identity(fd)
            if current[2] != 0 or current[3] & 0o022:
                raise PermissionError("destination ancestor is not root-owned and non-writable")
            identities.append(current)
        return fd, identities
    except BaseException:
        os.close(fd)
        raise


def open_actor_sandbox_chain(path: str, sandbox_root: str) -> tuple[int, list[tuple[int, int, int, int]]]:
    """Open an actor-owned private subtree without authorizing outside paths."""
    if not sandbox_root.startswith("/") or sandbox_root == "/" or ".." in sandbox_root.split("/"):
        raise ValueError("sandbox root must be a canonical absolute non-root path")
    if not path.startswith("/") or os.path.commonpath((path, sandbox_root)) != sandbox_root:
        raise PermissionError("actor sandbox cannot authorize a production or escaped path")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for component in filter(None, sandbox_root.split("/")):
            next_fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        actor = os.geteuid()
        anchor = identity(fd)
        if anchor[2] != actor or anchor[3] & 0o077:
            raise PermissionError("sandbox anchor is not effective-actor-owned and private")
        identities = [anchor]
        relative = os.path.relpath(path, sandbox_root)
        if relative == ".":
            return fd, identities
        for component in relative.split("/"):
            if component in ("", ".", ".."):
                raise ValueError("sandbox destination is not canonical")
            next_fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
            current = identity(fd)
            if current[2] != actor or current[3] & 0o022:
                raise PermissionError("sandbox ancestor is not effective-actor-owned and non-writable")
            identities.append(current)
        return fd, identities
    except BaseException:
        os.close(fd)
        raise


def open_authorized_chain(path: str, authority: str, sandbox_root: str | None) -> tuple[int, list[tuple[int, int, int, int]]]:
    if authority == AUTHORITY_ROOT and sandbox_root is None:
        return open_directory_chain(path)
    if authority == AUTHORITY_SANDBOX and sandbox_root is not None:
        return open_actor_sandbox_chain(path, sandbox_root)
    raise PermissionError("authority mode and sandbox root mismatch")


def ensure_directory(path: str, mode: int, authority: str = AUTHORITY_ROOT, sandbox_root: str | None = None) -> None:
    parent, leaf = os.path.split(path)
    parent_fd, _ = open_authorized_chain(parent, authority, sandbox_root)
    owner = 0 if authority == AUTHORITY_ROOT else os.geteuid()
    group = 0 if authority == AUTHORITY_ROOT else os.getegid()
    try:
        try:
            os.mkdir(leaf, mode, dir_fd=parent_fd)
            os.fsync(parent_fd)
        except FileExistsError:
            pass
        fd = os.open(leaf, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=parent_fd)
        try:
            value = os.fstat(fd)
            if value.st_uid != owner or value.st_gid != group or stat.S_IMODE(value.st_mode) != mode:
                raise PermissionError("directory exists with divergent ownership or mode")
        finally:
            os.close(fd)
    finally:
        os.close(parent_fd)


def digest_fd(fd: int) -> str:
    os.lseek(fd, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    while chunk := os.read(fd, 1024 * 1024):
        digest.update(chunk)
    return digest.hexdigest()


def revalidate_chain(path: str, expected: list[tuple[int, int, int, int]]) -> None:
    fd, observed = open_directory_chain(path)
    try:
        if observed != expected:
            raise RuntimeError("destination ancestor identity changed")
    finally:
        os.close(fd)


def revalidate_authorized_chain(path: str, expected: list[tuple[int, int, int, int]], authority: str, sandbox_root: str | None) -> None:
    fd, observed = open_authorized_chain(path, authority, sandbox_root)
    try:
        if observed != expected:
            raise RuntimeError("destination ancestor identity changed")
    finally:
        os.close(fd)


def verify_existing(parent_fd: int, leaf: str, expected: str, mode: int, owner: int = 0, group: int = 0) -> bool:
    try:
        fd = os.open(leaf, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=parent_fd)
    except FileNotFoundError:
        return False
    try:
        value = os.fstat(fd)
        if not stat.S_ISREG(value.st_mode) or value.st_uid != owner or value.st_gid != group:
            raise PermissionError("destination is not a root-owned regular file")
        if stat.S_IMODE(value.st_mode) != mode or digest_fd(fd) != expected:
            raise FileExistsError("destination exists with divergent identity or content")
        return True
    finally:
        os.close(fd)


def publish(source: str, destination: str, expected: str, mode: int, authority: str = AUTHORITY_ROOT, sandbox_root: str | None = None) -> None:
    parent, leaf = os.path.split(destination)
    if not leaf or "/" in leaf:
        raise ValueError("invalid destination leaf")
    parent_fd, chain = open_authorized_chain(parent, authority, sandbox_root)
    owner = 0 if authority == AUTHORITY_ROOT else os.geteuid()
    group = 0 if authority == AUTHORITY_ROOT else os.getegid()
    temp = f".rldyour-publish.{os.getpid()}.{os.urandom(8).hex()}"
    temp_created = False
    try:
        if verify_existing(parent_fd, leaf, expected, mode, owner, group):
            return
        source_fd = os.open(source, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
        try:
            source_stat = os.fstat(source_fd)
            if not stat.S_ISREG(source_stat.st_mode) or digest_fd(source_fd) != expected:
                raise ValueError("source changed or does not match its declared digest")
            target_fd = os.open(
                temp,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
                mode,
                dir_fd=parent_fd,
            )
            temp_created = True
            try:
                os.fchmod(target_fd, mode)
                os.fchown(target_fd, owner, group)
                os.lseek(source_fd, 0, os.SEEK_SET)
                while chunk := os.read(source_fd, 1024 * 1024):
                    view = memoryview(chunk)
                    while view:
                        written = os.write(target_fd, view)
                        view = view[written:]
                os.fsync(target_fd)
            finally:
                os.close(target_fd)
        finally:
            os.close(source_fd)

        # linkat is an atomic no-replace publication: EEXIST preserves the
        # concurrently introduced object. The temporary inode is removed only
        # after the durable destination link exists.
        revalidate_authorized_chain(parent, chain, authority, sandbox_root)
        os.link(temp, leaf, src_dir_fd=parent_fd, dst_dir_fd=parent_fd, follow_symlinks=False)
        os.fsync(parent_fd)
        os.unlink(temp, dir_fd=parent_fd)
        temp_created = False
        os.fsync(parent_fd)
        if not verify_existing(parent_fd, leaf, expected, mode, owner, group):
            raise RuntimeError("published destination failed identity validation")
        revalidate_authorized_chain(parent, chain, authority, sandbox_root)
    finally:
        if temp_created:
            try:
                os.unlink(temp, dir_fd=parent_fd)
                os.fsync(parent_fd)
            except OSError as cleanup_error:
                print(f"secure-publish cleanup failed: {cleanup_error}", file=sys.stderr)
        os.close(parent_fd)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ensure-directory")
    parser.add_argument("--source")
    parser.add_argument("--destination")
    parser.add_argument("--sha256")
    parser.add_argument("--mode", required=True, choices=("0600", "0644", "0755"))
    parser.add_argument("--authority", choices=(AUTHORITY_ROOT, AUTHORITY_SANDBOX), default=AUTHORITY_ROOT)
    parser.add_argument("--sandbox-root")
    args = parser.parse_args()
    if (args.authority == AUTHORITY_ROOT) != (args.sandbox_root is None):
        parser.error("root-production forbids --sandbox-root; actor-sandbox requires it")
    if args.ensure_directory:
        if args.source or args.destination or args.sha256 or args.mode != "0755":
            parser.error("directory mode accepts only --ensure-directory and --mode 0755")
        ensure_directory(args.ensure_directory, 0o755, args.authority, args.sandbox_root)
        return 0
    if not args.source or not args.destination or not args.sha256:
        parser.error("publication requires source, destination, sha256, and mode")
    if len(args.sha256) != 64 or any(c not in "0123456789abcdef" for c in args.sha256):
        parser.error("sha256 must be 64 lowercase hexadecimal characters")
    publish(args.source, args.destination, args.sha256, int(args.mode, 8), args.authority, args.sandbox_root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
