# URL Downloader Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add direct HTTPS and optional YouTube downloads that feed local files into MusicDrop's existing importer.

**Architecture:** `MDDownloadManager` validates URLs and either downloads a direct media response with `NSURLSession` or runs an installed `yt-dlp`/FFmpeg pair for YouTube. `MDImportButton` owns source selection and progress UI, then hands completed local URLs to `MDImporter`; Spotify URLs return a clear unsupported/DRM message.

**Tech Stack:** Objective-C, UIKit, Foundation/NSURLSession, POSIX `posix_spawn`, Theos/rootless iOS 15–16.

**Spec:** User request and the downloader architecture agreed in this session.

## Global Constraints

- Preserve the existing Files picker and `MDImporter` behavior.
- Accept only HTTPS remote URLs and supported DRM-free media outputs.
- Limit one URL operation to 500 MB and one YouTube item (no playlists).
- Never interpolate a URL into a shell command.
- Do not extract or decrypt Spotify audio.

## Review Focus

- Missing `yt-dlp` or FFmpeg must produce an actionable error instead of a crash.
- HTML/error responses disguised as media must be rejected.
- Oversized and empty downloads must be rejected before import.
- A failed download must restore the floating button and dismiss progress UI.
- Existing multi-file picking and imports must continue to work.

---

### Task 1: Download manager

**Files:**
- Create: `MDDownloadManager.h`
- Create: `MDDownloadManager.m`
- Modify: `Makefile`

**Interfaces:**
- Produces: `-downloadURL:progress:completion:` returning a local file URL on the main queue.

- [ ] Implement URL classification, validation, storage, and direct HTTPS downloading.
- [ ] Implement single-item YouTube execution using argument-array `posix_spawn` and installed `yt-dlp`/FFmpeg.
- [ ] Verify source-level invariants and build when a Theos environment is available.

### Task 2: Import-button integration

**Files:**
- Modify: `MDImportButton.m`

**Interfaces:**
- Consumes: `MDDownloadManager -downloadURL:progress:completion:`.

- [ ] Add an Import Files / Download URL action sheet while preserving the existing picker.
- [ ] Connect download progress, errors, and successful local output to `beginImport:`.
- [ ] Verify all completion paths restore button state.

### Task 3: Packaging and documentation

**Files:**
- Modify: `control`
- Modify: `README.md`
- Modify: `TESTING.md`

- [ ] Bump the package version and document optional YouTube runtime tools.
- [ ] Document direct URL behavior, Spotify limitation, and authorized-use requirement.
- [ ] Add on-device tests for direct, YouTube, Spotify, and failure paths.
