# npmjs-offline-install

Windows 11 batch script for downloading npm packages and their runtime
dependencies into a local offline repository when direct `npm install` access to
the public registry is blocked by an internal proxy.

The downloader uses PowerShell HTTP requests with browser-like headers for
registry metadata and package tarball downloads. It does not call `npm` while
collecting packages.

## Usage

```bat
download-npm-offline.bat package[@version-or-range] [output-dir] [registry-url]
```

Examples:

```bat
download-npm-offline.bat express@4 offline-npm-repo
download-npm-offline.bat @types/node@latest offline-npm-repo https://registry.npmjs.org
```

## Output

The output directory is a simple repo that can be copied to an offline machine:

```text
offline-npm-repo/
  metadata/              registry metadata JSON used for resolution
  tarballs/              downloaded .tgz packages named from package.json dependencies
    express-4.18.3.tgz
    @types/
      node-20.19.9.tgz
  package-list.json      downloaded package manifest
  install-offline.bat    helper that seeds npm cache and installs the root package
```

On the offline machine, run:

```bat
offline-npm-repo\install-offline.bat
```

## Notes

- Runtime `dependencies` and `optionalDependencies` are downloaded recursively.
- `devDependencies` are not downloaded.
- Common npm ranges such as exact versions, dist-tags, `^`, `~`, comparison
  ranges, and wildcards are supported.
- If your environment requires a registry mirror, pass it as the third argument.

## Included Electron package

This repository includes an `npm install electron` result for `electron@43.2.0`
with the Windows x64 Electron runtime already downloaded. The completed archive
is split into Git-friendly parts under `archives/`:

```text
archives/electron-43.2.0-npm-install.tar.gz.part-aa
archives/electron-43.2.0-npm-install.tar.gz.part-ab
archives/electron-43.2.0-npm-install.tar.gz.sha256
```

On Windows, restore the archive and extract it with:

```bat
cd archives
copy /b electron-43.2.0-npm-install.tar.gz.part-aa+electron-43.2.0-npm-install.tar.gz.part-ab electron-43.2.0-npm-install.tar.gz
certutil -hashfile electron-43.2.0-npm-install.tar.gz SHA256
tar -xzf electron-43.2.0-npm-install.tar.gz -C ..
```

Compare the `certutil` hash with
`archives/electron-43.2.0-npm-install.tar.gz.sha256`, then use the restored
`package.json`, `package-lock.json`, and `node_modules` contents offline.
