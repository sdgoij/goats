"""Add one file to an existing zip, for `build-apk.sh` when neither `zip` nor
`jar` is on the machine.

Usage: add_lib.py <apk> <source> <arcname>

Deflated rather than stored, which the manifest matches: it asks for
`extractNativeLibs="true"`, so the platform unpacks the library at install and
page alignment is not required.
"""

import sys
import zipfile

apk, source, arcname = sys.argv[1], sys.argv[2], sys.argv[3]

with zipfile.ZipFile(apk, "a", zipfile.ZIP_DEFLATED) as archive:
    archive.write(source, arcname)
