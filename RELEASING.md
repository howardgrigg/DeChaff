# Release process

## 1. Bump version in Xcode

In the DeChaff target (not the share extension):
- **Version** (`CFBundleShortVersionString`) — e.g. `1.0.2`
- **Build** (`CFBundleVersion`) — increment by 1 each release (Sparkle uses this to detect updates)

## 2. Archive and export

1. Product → Archive
2. Distribute App → Developer ID → Upload (notarizes automatically)
3. Export the notarized `.app` — save to `Releases/<version>/`

## 3. Staple and zip

```bash
cd Releases/<version>
xcrun stapler staple DeChaff.app
ditto -c -k --keepParent DeChaff.app DeChaff.zip
```

> Always use `ditto`, not `zip -r` — `zip` strips the notarization staple.

## 4. Sign for Sparkle

```bash
~/Library/Developer/Xcode/DerivedData/DeChaff-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update DeChaff.zip
```

Note the `sparkle:edSignature` and `length` values.

## 5. Create GitHub release

1. `git tag -a v<version> -m "Release v<version>"` and `git push origin v<version>`
2. Create a release from the tag on GitHub
3. Upload `DeChaff.zip` as the release asset

## 6. Update appcast.xml

In `docs/appcast.xml`, add a new `<item>` above the previous one:

```xml
<item>
  <title>Version X.Y.Z</title>
  <pubDate>DD Mon YYYY 00:00:00 +0000</pubDate>
  <sparkle:version>BUILD_NUMBER</sparkle:version>
  <sparkle:shortVersionString>X.Y.Z</sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
  <sparkle:releaseNotesLink>https://github.com/howardgrigg/DeChaff/releases/tag/vX.Y.Z</sparkle:releaseNotesLink>
  <enclosure
    url="https://github.com/howardgrigg/DeChaff/releases/download/vX.Y.Z/DeChaff.zip"
    sparkle:edSignature="SIGNATURE_FROM_STEP_4"
    length="LENGTH_FROM_STEP_4"
    type="application/octet-stream" />
</item>
```

Keep the previous item in the file below it.

## 7. Commit and push

```bash
git add docs/appcast.xml
git commit -m "Release v<version>"
git push
```

Sparkle polls the appcast automatically — existing installs will be offered the update within 24 hours.
