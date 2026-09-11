"""Dump the images/textures/materials of a .glb (binary glTF) file."""
import json
import struct
import sys


def read_glb(path):
    with open(path, "rb") as f:
        data = f.read()
    magic, version, length = struct.unpack_from("<4sII", data, 0)
    assert magic == b"glTF", magic
    offset = 12
    chunks = []
    while offset < length:
        clen, ctype = struct.unpack_from("<I4s", data, offset)
        cdata = data[offset + 8 : offset + 8 + clen]
        chunks.append((ctype, cdata))
        offset += 8 + clen
    return version, length, chunks


def extract_images(gltf, chunks, outdir):
    import os
    bin_chunk = next(c for t, c in chunks if t == b"BIN\x00")
    bufviews = gltf.get("bufferViews", [])
    os.makedirs(outdir, exist_ok=True)
    ext = {"image/jpeg": ".jpg", "image/png": ".png"}
    for i, img in enumerate(gltf.get("images", [])):
        bv = bufviews[img["bufferView"]]
        off = bv.get("byteOffset", 0)
        data = bin_chunk[off : off + bv["byteLength"]]
        name = f"{i}_{img.get('name','image')}{ext.get(img.get('mimeType'), '.bin')}"
        with open(os.path.join(outdir, name), "wb") as f:
            f.write(data)
        print(f"wrote {os.path.join(outdir, name)} ({len(data)} bytes)")


def main(path):
    version, length, chunks = read_glb(path)
    print(f"file: {path}")
    print(f"glb version {version}, {length} bytes, {len(chunks)} chunks")
    json_chunk = next(c for t, c in chunks if t == b"JSON")
    gltf = json.loads(json_chunk.decode("utf-8"))

    bin_size = sum(len(c) for t, c in chunks if t == b"BIN\x00")
    print(f"BIN chunk total: {bin_size} bytes")

    for key in ("materials", "textures", "images", "samplers", "meshes", "animations"):
        print(f"{key}: {len(gltf.get(key, []))}")

    print("\n-- extensionsUsed:", gltf.get("extensionsUsed"))
    print("-- extensionsRequired:", gltf.get("extensionsRequired"))

    images = gltf.get("images", [])
    print(f"\n== images ({len(images)}) ==")
    for i, img in enumerate(images):
        print(f"[{i}] name={img.get('name')!r} mime={img.get('mimeType')} "
              f"bufferView={img.get('bufferView')} uri={img.get('uri')}")

    textures = gltf.get("textures", [])
    print(f"\n== textures ({len(textures)}) ==")
    for i, t in enumerate(textures):
        print(f"[{i}] name={t.get('name')!r} source={t.get('source')} sampler={t.get('sampler')}")

    accessors = gltf.get("accessors", [])
    animations = gltf.get("animations", [])
    print(f"\n== animations ({len(animations)}) ==")
    for i, anim in enumerate(animations):
        duration = 0.0
        for s in anim.get("samplers", []):
            acc = accessors[s["input"]]
            if acc.get("max"):
                duration = max(duration, acc["max"][0])
        print(f"[{i}] name={anim.get('name')!r} channels={len(anim.get('channels', []))} "
              f"duration={duration:.4f}s")

    meshes = gltf.get("meshes", [])
    for m in meshes:
        for prim in m.get("primitives", []):
            attrs = prim.get("attributes", {})
            print(f"mesh {m.get('name')!r} attrs={sorted(attrs)} mat={prim.get('material')}")

    materials = gltf.get("materials", [])
    print(f"\n== materials ({len(materials)}) ==")
    for i, m in enumerate(materials):
        pbr = m.get("pbrMetallicRoughness", {})
        print(f"[{i}] name={m.get('name')!r}")
        print(f"     baseColorFactor={pbr.get('baseColorFactor')} "
              f"baseColorTexture={pbr.get('baseColorTexture')}")
        print(f"     metallicFactor={pbr.get('metallicFactor')} "
              f"roughnessFactor={pbr.get('roughnessFactor')} "
              f"metallicRoughnessTexture={pbr.get('metallicRoughnessTexture')}")
        print(f"     normalTexture={m.get('normalTexture')} "
              f"occlusionTexture={m.get('occlusionTexture')} "
              f"emissiveTexture={m.get('emissiveTexture')}")


if __name__ == "__main__":
    argv = sys.argv[1:]
    if argv and argv[0] == "--extract":
        outdir = argv[2] if len(argv) > 2 else "glbtex"
        _v, _l, _chunks = read_glb(argv[1])
        _gltf = json.loads(next(c for t, c in _chunks if t == b"JSON").decode("utf-8"))
        extract_images(_gltf, _chunks, outdir)
    else:
        main(argv[0] if argv else "goat_animated.glb")
