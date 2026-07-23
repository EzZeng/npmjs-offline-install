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
  tarballs/              downloaded .tgz packages
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
