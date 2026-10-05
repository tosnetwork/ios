#!/usr/bin/env python3
"""Generate the mobile buyer escrow projection vectors from contract output.

The input is the escrow v2 contract vector file that the service protocol
repository produces by running the released stablecoin escrow v2 contract in
the TOS sandbox (pkg/nativecore/testdata/escrow_v2_contract_vectors.json). That
file records the escrow data cell the contract itself wrote after deployment,
acceptance, funding, release and refund.

For each of those five states this script decodes the data cell BOC, checks
that its cell hash is the recorded one, reads the escrow fields from the cell
bits (magic, schema 2, status, Quote commitment, and the runtime cell), checks
them against the runtime the vector file reports and, where present, against
the contract's own get_escrow_state answer, and emits one projection case.
Refusal cases are single-field edits of a contract case and name the case
they were derived from.

    scripts/generate_escrow_projection_v2_vectors.py <contract-vectors.json> \
        <source-label> > mobile_buyer_escrow_projection_v2.json

<source-label> names where the vector file came from (repository and commit);
it is copied into the output's provenance.
"""

import base64
import hashlib
import json
import sys

DATA_MAGIC = 0x4E455331
RUNTIME_MAGIC = 0x4E455231
SCHEMA = 2
STATUS = {
    "pending_acceptance": 0,
    "awaiting_funding": 1,
    "funded": 2,
    "release_pending": 3,
    "refund_pending": 4,
}
CONTRACT_STATES = [
    ("pending_acceptance", "deployed"),
    ("awaiting_funding", "accepted"),
    ("funded", "funded"),
    ("release_pending", "released"),
    ("refund_pending", "refunded"),
]
DIGEST_PREFIX = "tvm-cell-sha256:"


class Cell:
    def __init__(self, data, bit_len, refs):
        self.data = data
        self.bit_len = bit_len
        self.refs = refs

    def bits(self):
        value = int.from_bytes(self.data, "big") if self.data else 0
        total = len(self.data) * 8
        return value, total

    def read(self, offset, width):
        value, total = self.bits()
        if offset + width > self.bit_len:
            raise ValueError("read past end of cell")
        return (value >> (total - offset - width)) & ((1 << width) - 1)


def parse_boc(encoded):
    raw = base64.b64decode(encoded, validate=True)
    if raw[:4] != bytes.fromhex("b5ee9c72"):
        raise ValueError("not a generic BOC")
    flags = raw[4]
    has_idx = bool(flags & 0x80)
    size = flags & 0x07
    off_bytes = raw[5]
    pos = 6

    def take(width):
        nonlocal pos
        value = int.from_bytes(raw[pos:pos + width], "big")
        pos += width
        return value

    cells_count = take(size)
    roots = take(size)
    absent = take(size)
    take(off_bytes)
    if roots != 1 or absent != 0:
        raise ValueError("expected one root and no absent cells")
    root_index = take(size)
    if has_idx:
        pos += cells_count * off_bytes
    parsed = []
    for _ in range(cells_count):
        d1, d2 = raw[pos], raw[pos + 1]
        pos += 2
        if d1 & 0xF8:
            raise ValueError("exotic, levelled or hashed cells are not expected")
        ref_count = d1 & 7
        data_len = (d2 + 1) // 2
        data = raw[pos:pos + data_len]
        pos += data_len
        if d2 & 1:
            last = data[-1]
            padding = (last & -last).bit_length()
            bit_len = data_len * 8 - padding
        else:
            bit_len = data_len * 8
        refs = [take(size) for _ in range(ref_count)]
        parsed.append((data, bit_len, refs, d1, d2))
    cells = [None] * cells_count
    for index in reversed(range(cells_count)):
        data, bit_len, refs, _, _ = parsed[index]
        cells[index] = Cell(data, bit_len, [cells[ref] for ref in refs])
    return cells[root_index]


def depth(cell):
    return 0 if not cell.refs else 1 + max(depth(ref) for ref in cell.refs)


def cell_hash(cell):
    d1 = len(cell.refs)
    d2 = (cell.bit_len // 8) + ((cell.bit_len + 7) // 8)
    data = bytearray(cell.data)
    if cell.bit_len % 8 == 0:
        data = data[: cell.bit_len // 8]
    representation = bytes([d1, d2]) + bytes(data)
    representation += b"".join(depth(ref).to_bytes(2, "big") for ref in cell.refs)
    representation += b"".join(cell_hash(ref) for ref in cell.refs)
    return hashlib.sha256(representation).digest()


def decode_escrow(cell):
    if len(cell.refs) != 4 or cell.bit_len != 32 + 16 + 8 + 3 * 256:
        raise ValueError("escrow data cell does not have the v2 shape")
    if cell.read(0, 32) != DATA_MAGIC or cell.read(32, 16) != SCHEMA:
        raise ValueError("escrow data cell is not schema 2")
    status = cell.read(48, 8)
    quote_hash = cell.read(56, 256)
    if cell_hash(cell.refs[0]) != quote_hash.to_bytes(32, "big"):
        raise ValueError("Quote commitment does not match the Quote cell")
    runtime = cell.refs[3]
    if len(runtime.refs) != 3 or runtime.bit_len != 32 + 16 + 128 + 128 + 256 + 64 + 64:
        raise ValueError("runtime cell does not have the v2 shape")
    if runtime.read(0, 32) != RUNTIME_MAGIC or runtime.read(32, 16) != SCHEMA:
        raise ValueError("runtime cell is not schema 2")
    receipt = runtime.read(304, 256)
    return {
        "status": status,
        "quote_commitment": DIGEST_PREFIX + quote_hash.to_bytes(32, "big").hex(),
        "funded_atomic_amount": str(runtime.read(48, 128)),
        "settled_atomic_amount": str(runtime.read(176, 128)),
        "receipt_commitment": ""
        if receipt == 0
        else DIGEST_PREFIX + receipt.to_bytes(32, "big").hex(),
        "accepted_at_unix": runtime.read(624, 64),
        "pending_query_id": runtime.read(560, 64),
    }


def views(escrow, quoted):
    if escrow is None:
        return (
            {
                "found": False,
                "pending_acceptance": False,
                "awaiting_funding": False,
                "funded_atomic": "0",
                "settled_atomic": "0",
                "receipt_commitment": "",
            },
            {"released": False, "refunded": False, "provider_credit_atomic": "0"},
            False,
        )
    status = escrow["status"]
    released = status == STATUS["release_pending"]
    return (
        {
            "found": True,
            "pending_acceptance": status == STATUS["pending_acceptance"],
            "awaiting_funding": status == STATUS["awaiting_funding"],
            "funded_atomic": escrow["funded_atomic_amount"],
            "settled_atomic": escrow["settled_atomic_amount"],
            "receipt_commitment": escrow["receipt_commitment"],
        },
        {
            "released": released,
            "refunded": status == STATUS["refund_pending"],
            "provider_credit_atomic": escrow["settled_atomic_amount"] if released else "0",
        },
        status == STATUS["funded"] and escrow["funded_atomic_amount"] == quoted,
    )


def main():
    if len(sys.argv) != 3:
        sys.stderr.write(__doc__)
        return 2
    with open(sys.argv[1], "rb") as handle:
        raw = handle.read()
    vectors = json.loads(raw)
    if vectors.get("schema") != "tos.service.escrow-v2-contract-vectors.v1":
        raise ValueError("unexpected contract vector schema")
    provenance = vectors["provenance"]
    quoted = vectors["input"]["amount_atomic"]
    expected_quote = vectors["input"]["quote_commitment"]

    cases = [
        {
            "name": "not_found",
            "origin": "no escrow account: nothing deployed yet",
            "present": False,
        }
    ]
    contract_cases = {}
    for name, section in CONTRACT_STATES:
        state = vectors[section]
        if section != "deployed" and state.get("exit_code") != 0:
            raise ValueError(f"{section}: contract transaction did not succeed")
        root = parse_boc(state["data_boc_base64"])
        if cell_hash(root).hex() != state["data_hash"]:
            raise ValueError(f"{section}: data cell hash mismatch")
        escrow = decode_escrow(root)
        runtime = state["runtime"]
        reported = {
            "status": runtime["status"],
            "funded_atomic_amount": runtime["funded"],
            "settled_atomic_amount": runtime["settled"],
            "receipt_commitment": ""
            if int(runtime["receipt_hash"], 16) == 0
            else DIGEST_PREFIX + runtime["receipt_hash"],
            "accepted_at_unix": runtime["accepted_at"],
            "pending_query_id": runtime["pending_query"],
        }
        for key, value in reported.items():
            if escrow[key] != value:
                raise ValueError(f"{section}: {key} differs from the reported runtime")
        getter = state.get("get_escrow_state")
        if getter is not None:
            answer = [
                str(escrow["status"]),
                escrow["funded_atomic_amount"],
                escrow["settled_atomic_amount"],
                str(int(runtime["receipt_hash"], 16)),
                str(escrow["pending_query_id"]),
                str(escrow["accepted_at_unix"]),
            ]
            if getter != answer:
                raise ValueError(f"{section}: get_escrow_state differs from the data cell")
        if escrow["status"] != STATUS[name] or escrow["quote_commitment"] != expected_quote:
            raise ValueError(f"{section}: status or Quote commitment unexpected")
        contract_cases[name] = escrow
        cases.append(
            {
                "name": name,
                "origin": f"contract data cell after '{section}'",
                "data_hash": DIGEST_PREFIX + state["data_hash"],
                "present": True,
                "escrow": escrow,
            }
        )

    def derived(name, source, error, **changes):
        escrow = dict(contract_cases[source])
        escrow.update(changes)
        edited = ", ".join(sorted(changes))
        cases.append(
            {
                "name": name,
                "origin": f"contract '{source}' state with {edited} edited",
                "present": True,
                "escrow": escrow,
                "expect_error": error,
            }
        )

    derived("status_above_refund_pending", "refund_pending", "unsupported_status", status=5)
    derived("status_max_byte", "funded", "unsupported_status", status=255)
    derived("pending_acceptance_with_accept_time", "pending_acceptance",
            "inconsistent_state", accepted_at_unix=1800000010)
    derived("awaiting_funding_holding_funds", "awaiting_funding", "inconsistent_state",
            funded_atomic_amount=quoted)
    derived("awaiting_funding_without_acceptance", "awaiting_funding", "inconsistent_state",
            accepted_at_unix=0)
    derived("funded_with_settled_amount", "funded", "inconsistent_state",
            settled_atomic_amount=quoted)
    derived("funded_with_receipt", "funded", "inconsistent_state",
            receipt_commitment=contract_cases["release_pending"]["receipt_commitment"])
    derived("funded_with_pending_query", "funded", "inconsistent_state", pending_query_id=7)
    derived("funded_zero_amount", "funded", "inconsistent_state", funded_atomic_amount="0")
    derived("release_pending_without_receipt", "release_pending", "inconsistent_state",
            receipt_commitment="")
    derived("release_pending_partial_settlement", "release_pending", "inconsistent_state",
            settled_atomic_amount="24999999")
    derived("release_pending_without_query", "release_pending", "inconsistent_state",
            pending_query_id=0)
    derived("refund_pending_with_settled_amount", "refund_pending", "inconsistent_state",
            settled_atomic_amount=quoted)
    derived("refund_pending_without_query", "refund_pending", "inconsistent_state",
            pending_query_id=0)
    derived("funded_amount_overflows_uint64", "funded", "malformed_amount",
            funded_atomic_amount="18446744073709551616")
    derived("funded_amount_not_decimal", "funded", "malformed_amount",
            funded_atomic_amount="-25000000")
    derived("quote_commitment_malformed", "funded", "malformed_commitment",
            quote_commitment="sha256:" + expected_quote[len(DIGEST_PREFIX):])
    derived("receipt_commitment_malformed", "release_pending", "malformed_commitment",
            receipt_commitment=contract_cases["release_pending"]["receipt_commitment"][:-2])

    for case in cases:
        if "expect_error" in case:
            continue
        funding, settlement, exact = views(case.get("escrow"), quoted)
        case["funding_view"] = funding
        case["settlement_view"] = settlement
        case["exactly_funded_at_quote"] = exact

    output = {
        "schema": "tos.service.mobile-buyer-escrow-projection.v2",
        "note": (
            "Buyer-facing projection of finalized stablecoin escrow v2 state, shared by "
            "the iOS and Android clients. The five contract cases carry the fields of "
            "the data cell the escrow v2 contract wrote; refusal cases edit one field "
            "of a contract case. 'released' is true only in release_pending and "
            "'refunded' only in refund_pending; funded is never released. A missing "
            "escrow is neither awaiting funding nor funded. Statuses above "
            "refund_pending and states that break the per-status runtime invariants "
            "are refused. Generated by scripts/generate_escrow_projection_v2_vectors.py; "
            "do not edit by hand."
        ),
        "provenance": {
            "contract_vectors": sys.argv[2],
            "contract_vectors_sha256": hashlib.sha256(raw).hexdigest(),
            "tos_commit": provenance["tos_commit"],
            "escrow_source": provenance["escrow_source"],
            "escrow_code_hash": provenance["escrow_code_hash"],
            "executor": provenance["executor"],
        },
        "escrow_status": STATUS,
        "quoted_atomic": quoted,
        "cases": cases,
    }
    json.dump(output, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
