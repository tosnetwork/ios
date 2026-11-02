#!/usr/bin/env python3
"""Check mobile native self-pay domains against VM-executed public vectors."""

import argparse
import ctypes
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path


def main():
    if not __debug__:
        raise SystemExit("Native tests require enabled Python assertions")
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--source", type=Path)
    p.add_argument("--vectors", type=Path)
    p.add_argument("--output", type=Path, required=True)
    args = p.parse_args()
    root = Path(__file__).resolve().parents[1]
    source = args.source or root / "LocalPackages/core-swift/Sources/TOSPQNative"
    vectors = (
        args.vectors
        or root
        / "LocalPackages/core-swift/Tests/KeeperCoreTests/TestData/tos-quantum-self-pay.json"
    )
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    files = [
        "tos_quantum.c",
        "vendor/mldsa/mldsa_native.c",
        "vendor/slhdsa/slh_dsa.c",
        "vendor/slhdsa/slh_sha2.c",
        "vendor/slhdsa/sha2_256.c",
        "vendor/slhdsa/sha2_512.c",
    ]
    library = out / ("libqsp.dylib" if sys.platform == "darwin" else "libqsp.so")

    def compile_library(destination, wrapper):
        subprocess.run(
            [
                os.environ.get("CC", "cc"),
                "-dynamiclib" if sys.platform == "darwin" else "-shared",
                "-fPIC",
                "-O2",
                "-std=c99",
                '-DMLD_CONFIG_FILE="mldsa-config.h"',
                *[
                    "-I" + str(source / d)
                    for d in (".", "include", "vendor/mldsa", "vendor/slhdsa")
                ],
                str(wrapper),
                *[str(source / f) for f in files[1:]],
                "-o",
                str(destination),
            ],
            check=True,
        )

    compile_library(library, source / files[0])
    lib = ctypes.CDLL(str(library))
    pointer, size, integer = ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int
    lib.tos_quantum_sign.argtypes = [
        integer,
        integer,
        pointer,
        size,
        pointer,
        size,
        pointer,
        size,
        pointer,
        size,
    ]
    lib.tos_quantum_sign.restype = integer
    lib.tos_quantum_verify.argtypes = [
        integer,
        integer,
        pointer,
        size,
        pointer,
        size,
        pointer,
        size,
    ]
    lib.tos_quantum_verify.restype = integer
    v = json.loads(vectors.read_text())

    def verify(role, purpose, key, digest, signature):
        return (
            lib.tos_quantum_verify(
                role, purpose, key, len(key), digest, len(digest), signature, len(signature)
            )
            == 1
        )

    for row in v["cases"]:
        role = row["role"]
        key = bytes.fromhex(v["primary_key" if role == 1 else "rescue_key"])
        digest, signature = bytes.fromhex(row["request_hash"]), bytes.fromhex(row["signature"])
        assert verify(role, 4, key, digest, signature), row["name"]
        for purpose in (1, 2, 3, 5, 0, 6):
            assert not verify(role, purpose, key, digest, signature), (row["name"], purpose)
    for role in (1, 2):
        seed = bytes.fromhex(v["primary_seed" if role == 1 else "rescue_seed"])
        key = bytes.fromhex(v["primary_key" if role == 1 else "rescue_key"])
        entropy = b"\xa5" * (32 if role == 1 else 16)
        digest = bytes.fromhex(v["probe"]["digest"])
        for purpose in (4, 5):
            signature = ctypes.create_string_buffer(2420 if role == 1 else 7856)
            assert (
                lib.tos_quantum_sign(
                    role,
                    purpose,
                    seed,
                    len(seed),
                    entropy,
                    len(entropy),
                    digest,
                    len(digest),
                    signature,
                    len(signature),
                )
                == 0
            )
            assert verify(role, purpose, key, digest, signature.raw)
            for other in (1, 2, 3, 9 - purpose):
                assert not verify(role, other, key, digest, signature.raw)
            corrupted = bytes([signature.raw[0] ^ 1]) + signature.raw[1:]
            assert not verify(role, purpose, key, digest, corrupted)
    # Collapse the two new domains in an isolated translation unit. The same
    # positive vector must still verify, and the wrong-domain assertion must fail.
    wrapper = (source / "tos_quantum.c").read_text()
    marker = "if (purpose == 4)"
    assert wrapper.count(marker) == 1
    mutation = out / "domain-alias.c"
    mutation.write_text(wrapper.replace(marker, "if (purpose == 4 || purpose == 5)"))
    mutant_path = out / ("libqsp-mutant.dylib" if sys.platform == "darwin" else "libqsp-mutant.so")
    compile_library(mutant_path, mutation)
    mutant = ctypes.CDLL(str(mutant_path))
    mutant.tos_quantum_verify.argtypes = lib.tos_quantum_verify.argtypes
    mutant.tos_quantum_verify.restype = integer
    row = next(row for row in v["cases"] if row["role"] == 1)
    key, digest, signature = (
        bytes.fromhex(v["primary_key"]),
        bytes.fromhex(row["request_hash"]),
        bytes.fromhex(row["signature"]),
    )
    assert (
        mutant.tos_quantum_verify(
            1, 4, key, len(key), digest, len(digest), signature, len(signature)
        )
        == 1
    )
    assert (
        mutant.tos_quantum_verify(
            1, 5, key, len(key), digest, len(digest), signature, len(signature)
        )
        == 1
    )
    assert not verify(1, 5, key, digest, signature)
    sources = {
        str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(source.rglob("*"))
        if p.is_file() and p.suffix in (".c", ".h")
    }
    report = dict(
        vm_vectors=len(v["cases"]),
        generated_signatures=4,
        invalid_domains_rejected=True,
        domain_alias_mutation_detected=True,
        sources=sources,
        source_sha256=hashlib.sha256((source / "tos_quantum.c").read_bytes()).hexdigest(),
        library_sha256=hashlib.sha256(library.read_bytes()).hexdigest(),
        vectors_sha256=hashlib.sha256(vectors.read_bytes()).hexdigest(),
    )
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
