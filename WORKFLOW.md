# DansMagazin Working Agreement

## Single Source

- Local working copy: `~/dansmagazin`
- Remote source of truth: `origin/main`
- Production server: deployment target only, not a development workspace

Do not work from `dansmagazin_repo`, `projects/dansmagazin`, copied build
folders, or production directories.

## Start Work

```bash
cd ~/dansmagazin
git checkout main
git pull --ff-only origin main
git status --short --branch
```

The working tree must be clean before starting unrelated work.

## Save Work

```bash
git add <intended-files>
git commit -m "..."
git push origin main
```

Never build a store release from uncommitted application code.

## Android Store Build

```bash
cd ~/dansmagazin/mobile_app_preview
./scripts/build_android_appbundle.sh
```

The script builds from a clean `origin/main` worktree, copies the local
Firebase/signing files, writes the AAB to the Desktop, and removes its temporary
worktree.

## App Store Connect

```bash
cd ~/dansmagazin/mobile_app_preview
./scripts/prepare_ios_archive.sh
```

The script prints and preserves the clean iOS workspace path. Open the printed
`ios/Runner.xcworkspace`, then use Xcode's `Product > Archive`.

After the upload is complete, remove the preserved workspace with:

```bash
git -C ~/dansmagazin worktree remove --force <printed-worktree-root>
```

## Production

- Mobile backend: `/home/ubuntu/mobil_backend`
- Photo backend: `/home/ubuntu/etkinlik_fotograf_projesi`
- SSH alias: `dans-new`

Make source changes locally, push them, then deploy deliberately. Do not keep
VS Code Remote or AI coding extensions connected to production when idle.

Secrets, Firebase configs, signing files, databases, media, and `.env` files
must never be committed.
