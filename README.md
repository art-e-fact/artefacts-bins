# Artefacts Binaries

Releases of the Artefacts CLI. This repo is a temporary workaround while open-sourcing the code for the CLI tool.

## Install

```sh
./scripts/install.sh            # Linux and macOS: latest release
./scripts/install.sh 0.3.0      # or a specific release tag
PREFIX=$HOME/.local ./scripts/install.sh
```

```powershell
.\scripts\install.ps1           # Windows: latest release
.\scripts\install.ps1 0.3.0
$env:PREFIX = "$HOME\AppData\Local\Programs\artefacts"; .\scripts\install.ps1
```

Package installers are used when available (currently Debian `.deb`). Otherwise the
release binary is installed to `$PREFIX/share/artefacts/artefacts-<version>` and
linked from `$PREFIX/bin/artefacts`. The default prefix is `/usr/local` on Linux and
macOS, and `%ProgramFiles%\artefacts` on Windows. If `$PREFIX/bin` is not on `PATH`,
the installer warns and reports again at the end.

Uninstall with `./scripts/uninstall.sh` or `.\scripts\uninstall.ps1` (same `PREFIX`,
if overridden). The uninstaller checks the native package manager first, then
binaries under `PREFIX`, lists every detected install by version and method, and
asks which to remove (or `all`). A single install only needs a yes/no
confirmation. If nothing is found under the default prefix, it offers to try
another `PREFIX`. Pass `-y` / `--yes` to proceed without confirmation (first
install only), or `--all` / `-All` to remove everything non-interactively.
Use `-h` / `--help` on any script for its full usage.
