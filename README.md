# MusicDrop

MusicDrop is a rootless jailbreak tweak that adds an **Import** button to the stock iOS Music app. Pick audio files from Files or iCloud Drive, and MusicDrop copies them, reads their tags and artwork, and hands them to Music's own importer. No computer, SSH session, or desktop sync is needed after installation.

The package and Sileo repository are built and published by GitHub Actions to GitHub Pages. You own the source, the build, and the repo.

## Requirements

- iPhone X (or another arm64 iOS 15/16 device) on a **rootless** jailbreak.
- palera1n rootless is the target setup. Other rootless jailbreaks that provide MobileSubstrate or ElleKit should work.
- iOS **15.0 through 16.7.x**.
- Sileo (or another package manager that supports rootless `iphoneos-arm64` packages).
- DRM-free audio files you have the right to use.

This project does **not** download music, bypass DRM, or upload your files anywhere. It only imports files you select from the system document picker.

## Install from your published repo

After you push this repository and the workflow succeeds, your repo URL is:

```
https://<your-github-username>.github.io/<your-repo-name>/
```

For example, if the repository is `musiccc` under the user `alice`, the URL is `https://alice.github.io/musiccc/`.

On the phone:

1. Open Sileo → **Sources** → **Edit** → **Add Source**.
2. Paste the repo URL and add it.
3. Open the source, install **MusicDrop**, and let Sileo respring or relaunch Music.
4. Open Music. A pink floating button appears near the bottom-right.
5. Tap it, choose one or more audio files, and keep Music open while the import finishes.

You can drag the button anywhere on screen. Its position is remembered.

## First-time GitHub setup

1. Create a **public** GitHub repository (private repositories need a paid plan for Pages). The suggested name is `musiccc`.
2. Push this project to the repository's default branch (`main` or `master`).
3. In the repository, open **Settings → Pages → Build and deployment** and set **Source** to **GitHub Actions**. The workflow also tries to enable Pages automatically, but setting it explicitly avoids surprises.
4. Open the **Actions** tab and run **Build and publish MusicDrop** (or just push a commit).
5. Wait for the build. It will:
   - install Theos and an iOS SDK on the macOS runner;
   - build the rootless `.deb`;
   - generate `docs/Packages`, `docs/Release`, `docs/repo.json`, and compressed indexes;
   - commit the generated index back to `docs/` with `[skip ci]`;
   - deploy `docs/` to GitHub Pages.
6. Open the Pages URL shown by the workflow and use its **Add to Sileo** or **Copy repo URL** button.

No repository URL is hard-coded in the tweak. The workflow derives the Pages URL from `github.repository_owner` and the repository name.

### If the workflow cannot push the generated index

The `GITHUB_TOKEN` needs `contents: write`. The workflow already requests it. A protected branch or an organization policy can still block the push; the Pages deployment will continue with the generated artifact, but the `docs/` index in git will not update until the push is allowed.

### If Pages is not enabled

The `actions/configure-pages` step uses `enablement: true`. If that fails, enable Pages manually as described above and re-run the workflow.

## Usage notes

- Select multiple files at once. They are imported one by one.
- Keep Music in the foreground until the downloads finish. MusicDrop asks iOS for extra background time, but the temporary file server runs inside the Music process, so foreground is the reliable state.
- Files without embedded artwork get a MusicDrop cover, not a blank square.
- Metadata is read with `AVAsset`: title, artist, album, genre, composer, year, track number/count, duration, and artwork.
- Files are copied to `/var/mobile/Media/MusicDrop/inbox/`. Artwork goes to `/var/mobile/Media/MusicDrop/artwork/`. Both are pruned after seven days.
- Imported songs live in your normal Music library. Uninstalling MusicDrop does not remove them.

### Supported formats

Directly supported: **MP3, M4A, AAC, ALAC, WAV, AIFF, CAF, FLAC, M4R, M4B**, plus **MP4, M4V, and MOV** music videos.

OGG, Opus, WMA, APE, and other formats that AVFoundation/iOS Music cannot decode are rejected with a message. Convert them to MP3 or M4A first.

## Troubleshooting

### The button does not appear

- Confirm the package is installed in Sileo.
- Confirm you are on a rootless jailbreak and that MobileSubstrate/ElleKit is working for other tweaks.
- Fully close Music and reopen it. The post-install script runs `killall -9 Music`.
- Check the log:

  ```
  /var/mobile/Media/MusicDrop/musicdrop.log
  ```

  You can read it with Filza or SSH. The first line should say `MusicDrop loaded in pid ...`.

- Confirm the filter targets `com.apple.Music` (it does in `MusicDrop.plist`).

### The import fails or nothing is added

- Keep Music open during the import.
- Try a plain MP3 with embedded title/artist first.
- Read the log for `StoreServices available: yes`, `Server: listening on 127.0.0.1:...`, and `Enqueued ...`.
- Verify the file copied into `/var/mobile/Media/MusicDrop/inbox/`.
- Check free storage. Very large files can fail if the device is nearly full.
- Private StoreServices APIs are not documented and can change between iOS releases. The log is the first place to look.

### The repo does not load in Sileo

- Open `https://<owner>.github.io/<repo>/Packages` in Safari. It should be plain text starting with `Package:`.
- Open `https://<owner>.github.io/<repo>/Release`. It should contain hashes.
- Make sure the Pages source is **GitHub Actions** and the deploy step succeeded.
- Refresh the source in Sileo. If the index was just generated, GitHub Pages can take a minute to serve it.

### GitHub Actions fails during the build

- The Theos clone and SDK download are the slowest steps; the job has a 30-minute timeout.
- `ldid` is installed with Homebrew if it is missing on the runner.
- Package compression is forced to gzip so the pure-Python index generator can read `control.tar.gz` without extra modules.
- If the workflow cannot push generated docs, see the note above. The Pages artifact can still deploy.

## Build locally

You need macOS or Linux with [Theos](https://theos.dev/), an iOS SDK, and `ldid`. Windows users should use GitHub Actions; iOS compilation is not supported natively on Windows.

```sh
export THEOS="$HOME/theos"
export THEOS_PACKAGE_SCHEME=rootless
chmod +x layout/DEBIAN/postinst layout/DEBIAN/postrm
make clean package FINALPACKAGE=1
```

The `.deb` is written to `packages/`. To regenerate the repo locally:

```sh
python3 scripts/make_repo.py \
  --debs packages \
  --out docs \
  --clean \
  --homepage "https://example.github.io/musiccc/"

python3 -m http.server -d docs 8080
```

Open `http://localhost:8080/` to preview the landing page. The Sileo URL in the preview points at localhost, which is useful for checking the page but not for installing on a phone.

To regenerate the repo icon (requires Pillow):

```sh
python3 scripts/make_icon.py
```

## Updating the tweak

1. Edit the source.
2. Bump `Version:` in `control`.
3. Commit and push.

The workflow rebuilds the package, replaces the previous `.deb` in `docs/debs/` (because the generator runs with `--clean`), regenerates the indexes, commits them, and deploys. Sileo users refresh the source and update normally.

If you need to keep older versions available, remove `--clean` from the workflow. The generator will index every `.deb` it finds, and Sileo will choose the newest version.

## How it works

1. A constructor in the injected dylib installs a floating `UIButton` in Music's key window.
2. The button presents a `UIDocumentPickerViewController` configured with audio and movie UTIs and `asCopy:YES`.
3. Each picked file is copied into `/var/mobile/Media/MusicDrop/inbox/` with a random token name.
4. `AVURLAsset` reads duration, tags, and artwork. Artwork is normalized and resized to JPEG; a generated cover is used if the file has none.
5. A small HTTP server binds to `127.0.0.1` on an OS-assigned port and serves only the registered file/artwork tokens. It supports `GET`, `HEAD`, and byte ranges.
6. MusicDrop loads `StoreServices` with `dlopen`, builds an `SSDownloadMetadata` payload, wraps it in an `SSDownload`, and adds it to an `SSDownloadQueue` created with `mediaDownloadKinds`.
7. Music's store daemon fetches the file from the loopback URL and adds it to the library.

The private-API handoff is intentionally isolated in `MDImporter.m`. Everything else is public UIKit, Foundation, and AVFoundation.

## Repository layout

```
Makefile                     Theos tweak build
control                      package metadata (version, arch, dependency)
MusicDrop.plist              MobileSubstrate filter for com.apple.Music
MusicDrop.xm                 tweak constructor
MDImportButton.h/.m          floating button, picker, progress UI
MDImporter.h/.m              copy, metadata, artwork, StoreServices import
MDServer.h/.m                loopback HTTP file server
MDLog.h/.m                   file + console logging
layout/DEBIAN/               postinst / postrm
scripts/make_repo.py         stdlib-only .deb index generator
scripts/make_icon.py         optional repo icon generator
docs/                        GitHub Pages site + generated repo index
.github/workflows/build.yml  build, index, commit, deploy
```

## Limitations and risk

- Rootless only. The package is `iphoneos-arm64` and installs under `/var/jb`.
- iOS 15/16 are the targets. A future iOS release can break the private StoreServices classes.
- Importing depends on Music's internal download queue. This is not an App Store-supported workflow.
- The temporary server uses an unauthenticated loopback port while the import runs. It only serves random-token paths for files you selected, and it is not reachable from other devices.
- Keep backups of anything irreplaceable. This is a jailbreak tweak; use it at your own risk.

## License

MIT. See [LICENSE](LICENSE).

MusicDrop is not affiliated with Apple. Apple, iPhone, and Music are trademarks of Apple Inc.
