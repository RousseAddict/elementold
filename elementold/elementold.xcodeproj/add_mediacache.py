#!/usr/bin/env python3
# Registers MediaCache.swift in the traditional (non-synchronized-group) pbxproj:
# 4 insertion points, mirroring the existing RoomEvent.swift entries. Bails if the
# file is already present.
import sys

PBX = "project.pbxproj"

# (filename, fileRefID, buildFileID)
NEW = [
    ("MediaCache.swift", "BB200024", "BB200025"),
]

with open(PBX) as f:
    src = f.read()

# Anchors: the four RoomEvent.swift lines (unique in the file).
BUILDFILE_ANCHOR = "\t\tBB20000E /* RoomEvent.swift in Sources */ = {isa = PBXBuildFile; fileRef = BB20000D /* RoomEvent.swift */; };\n"
FILEREF_ANCHOR   = "\t\tBB20000D /* RoomEvent.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RoomEvent.swift; sourceTree = \"<group>\"; };\n"
GROUP_ANCHOR     = "\t\t\t\tBB20000D /* RoomEvent.swift */,\n"
SOURCES_ANCHOR   = "\t\t\t\tBB20000E /* RoomEvent.swift in Sources */,\n"

for anchor in (BUILDFILE_ANCHOR, FILEREF_ANCHOR, GROUP_ANCHOR, SOURCES_ANCHOR):
    if anchor not in src:
        sys.exit("ANCHOR NOT FOUND:\n" + anchor)

for name, fref, bfile in NEW:
    if name in src:
        sys.exit("ALREADY PRESENT: " + name)
    buildfile = "\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n" % (bfile, name, fref, name)
    fileref   = "\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = %s; sourceTree = \"<group>\"; };\n" % (fref, name, name)
    group     = "\t\t\t\t%s /* %s */,\n" % (fref, name)
    sources   = "\t\t\t\t%s /* %s in Sources */,\n" % (bfile, name)

    src = src.replace(BUILDFILE_ANCHOR, BUILDFILE_ANCHOR + buildfile, 1)
    src = src.replace(FILEREF_ANCHOR, FILEREF_ANCHOR + fileref, 1)
    src = src.replace(GROUP_ANCHOR, GROUP_ANCHOR + group, 1)
    src = src.replace(SOURCES_ANCHOR, SOURCES_ANCHOR + sources, 1)

with open(PBX, "w") as f:
    f.write(src)

print("OK: added", ", ".join(n for n, _, _ in NEW))
