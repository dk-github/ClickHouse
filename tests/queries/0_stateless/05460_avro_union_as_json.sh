#!/usr/bin/env bash
# Tags: no-fasttest
# A stream of messages written as Avro over three releases. Each release has its own writer schema: release 2 adds
# a message type, release 3 adds fields to two messages and a value to an enum. A Variant has one type per message
# shape, so the files cannot be read together. Read into JSON, every file is decoded with its own schema, and one
# query reads them all.

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

prefix="${CLICKHOUSE_DATABASE}_avro_json"
glob="${prefix}_r{1,2,3}.avro"

order_r1="Tuple(order_id Int64, side Enum8('Buy' = 0, 'Sell' = 1))"
trade_r1="Tuple(trade_id Int64, price Float64)"
cancel="Tuple(order_id Int64, reason String)"
order_r3="Tuple(order_id Int64, side Enum8('Buy' = 0, 'Sell' = 1, 'Short' = 2), tags Map(String, String))"
trade_r3="Tuple(trade_id Int64, price Float64, day Date, fills Array(Tuple(qty Int64, venue String)))"

# INSERT INTO FUNCTION file() takes the structure from the SELECT; Variant(...) becomes an Avro union.
v1="Variant($order_r1, $trade_r1)"
v2="Variant($order_r1, $trade_r1, $cancel)"
v3="Variant($order_r3, $trade_r3, $cancel)"
$CLICKHOUSE_CLIENT --allow_suspicious_variant_types 1 -q "
INSERT INTO FUNCTION file('${prefix}_r1.avro', 'Avro')
SELECT 1::Int64 AS seq, CAST((101, 'Buy')::$order_r1 AS $v1) AS payload
UNION ALL
SELECT 2::Int64, CAST((201, 9.5)::$trade_r1 AS $v1)"

$CLICKHOUSE_CLIENT --allow_suspicious_variant_types 1 -q "
INSERT INTO FUNCTION file('${prefix}_r2.avro', 'Avro')
SELECT 3::Int64 AS seq, CAST((101, 'user')::$cancel AS $v2) AS payload
UNION ALL
SELECT 4::Int64, CAST((102, 'Sell')::$order_r1 AS $v2)"

$CLICKHOUSE_CLIENT --allow_suspicious_variant_types 1 -q "
INSERT INTO FUNCTION file('${prefix}_r3.avro', 'Avro')
SELECT 5::Int64 AS seq, CAST((103, 'Short', map('desk', 'fx'))::$order_r3 AS $v3) AS payload
UNION ALL
SELECT 6::Int64, CAST((202, 10.25, '2026-10-28', [(5, 'XETR'), (3, 'LSE')])::$trade_r3 AS $v3)
UNION ALL
SELECT 7::Int64, NULL::$v3"

echo "== Inferred as Variant: a query over all releases fails =="
$CLICKHOUSE_CLIENT -q "SELECT payload FROM file('$glob') FORMAT Null" 2>&1 \
    | grep -m1 -c -E 'are not compatible|does not match the number of types'

echo "== Read into JSON: one query over all releases =="
$CLICKHOUSE_CLIENT -q "
SELECT seq, payload FROM file('$glob', 'Avro', 'seq Int64, payload JSON') ORDER BY seq
SETTINGS output_format_json_quote_64bit_integers = 0"

echo "== Plain SQL over all releases: the new enum value is just another string =="
$CLICKHOUSE_CLIENT -q "
SELECT seq, payload.order_id, payload.side, payload.reason
FROM file('$glob', 'Avro', 'seq Int64, payload JSON')
WHERE payload.order_id IS NOT NULL
ORDER BY seq"
$CLICKHOUSE_CLIENT -q "
SELECT seq, payload.price, payload.day, payload.fills[].venue, arraySum(payload.fills[].qty::Array(Int64))
FROM file('$glob', 'Avro', 'seq Int64, payload JSON')
WHERE payload.trade_id IS NOT NULL
ORDER BY seq"

echo "== Paths and types over all releases =="
$CLICKHOUSE_CLIENT -q "
SELECT arrayJoin(distinctJSONPathsAndTypes(payload)) AS path_and_types
FROM file('$glob', 'Avro', 'seq Int64, payload JSON')
ORDER BY path_and_types"

echo "== input_format_avro_union_as_json = 1: no structure needed =="
$CLICKHOUSE_CLIENT -q "DESC file('$glob') SETTINGS input_format_avro_union_as_json = 1"
$CLICKHOUSE_CLIENT -q "
SELECT seq, payload.order_id, payload.trade_id FROM file('$glob') ORDER BY seq
SETTINGS input_format_avro_union_as_json = 1"

echo "== Records and maps can be read into JSON too =="
$CLICKHOUSE_CLIENT -q "
INSERT INTO FUNCTION file('${prefix}_record.avro', 'Avro')
SELECT ('offload', 14, 0.1)::Tuple(source String, version Int32, ratio Float32) AS meta, map('orders', 3, 'trades', 2)::Map(String, Int64) AS counts"
$CLICKHOUSE_CLIENT -q "
SELECT meta, counts FROM file('${prefix}_record.avro', 'Avro', 'meta JSON, counts JSON')
SETTINGS output_format_json_quote_64bit_integers = 0"

echo "== Binary bytes are kept as they are =="
$CLICKHOUSE_CLIENT -q "
INSERT INTO FUNCTION file('${prefix}_bytes.avro', 'Avro')
SELECT tuple(unhex('C328FF00'))::Tuple(raw String) AS blob"
$CLICKHOUSE_CLIENT -q "SELECT hex(blob.raw::String) FROM file('${prefix}_bytes.avro', 'Avro', 'blob JSON')"

echo "== Scalars and unions of scalars cannot be read into JSON =="
$CLICKHOUSE_CLIENT -q "
INSERT INTO FUNCTION file('${prefix}_scalar.avro', 'Avro')
SELECT 1::Int64 AS n, 1::Variant(Int64, String) AS v"
$CLICKHOUSE_CLIENT -q "SELECT * FROM file('${prefix}_scalar.avro', 'Avro', 'n JSON, v Int64')" 2>&1 \
    | grep -m1 -c 'only records, maps and unions of them can be read into JSON'
$CLICKHOUSE_CLIENT -q "SELECT * FROM file('${prefix}_scalar.avro', 'Avro', 'n Int64, v JSON')" 2>&1 \
    | grep -m1 -c 'only records, maps and unions of them can be read into JSON'
$CLICKHOUSE_CLIENT -q "DESC file('${prefix}_scalar.avro') SETTINGS input_format_avro_union_as_json = 1"

rm -f "$CLICKHOUSE_USER_FILES/${prefix}"_*.avro
