#!/usr/bin/env bash
# Tags: no-fasttest
# Files written with different versions of an Avro schema can have unions with different branches.
# A union is read into a Variant that has more types than the union, and schema_inference_mode = 'union'
# merges the unions of all files into one Variant.

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

prefix="${CLICKHOUSE_DATABASE}_union_subset"

$CLICKHOUSE_CLIENT -q "
INSERT INTO FUNCTION file('${prefix}_old.avro', 'Avro', 'id Int32, payload Variant(Tuple(k Int64), Tuple(s String))')
SELECT 1, CAST(tuple(10)::Tuple(k Int64) AS Variant(Tuple(k Int64), Tuple(s String)))
UNION ALL
SELECT 2, CAST(tuple('a')::Tuple(s String) AS Variant(Tuple(k Int64), Tuple(s String)))"

$CLICKHOUSE_CLIENT -q "
INSERT INTO FUNCTION file('${prefix}_new.avro', 'Avro', 'id Int32, payload Variant(Tuple(k Int64), Tuple(s String), Tuple(n Float64, m Int64))')
SELECT 3, CAST(tuple(2.5, 7)::Tuple(n Float64, m Int64) AS Variant(Tuple(k Int64), Tuple(s String), Tuple(n Float64, m Int64)))
UNION ALL
SELECT 4, CAST(tuple(20)::Tuple(k Int64) AS Variant(Tuple(k Int64), Tuple(s String), Tuple(n Float64, m Int64)))"

$CLICKHOUSE_CLIENT -q "
INSERT INTO FUNCTION file('${prefix}_evolved.avro', 'Avro', 'id Int32, payload Variant(Tuple(k Int64, j String), Tuple(s String))')
SELECT 5, CAST(tuple(30, 'x')::Tuple(k Int64, j String) AS Variant(Tuple(k Int64, j String), Tuple(s String)))"

echo "== old file, Variant with more types than the union =="
$CLICKHOUSE_CLIENT -q "SELECT id, payload, variantType(payload) FROM file('${prefix}_old.avro', 'Avro',
  'id Int32, payload Variant(Tuple(k Int64), Tuple(s String), Tuple(n Float64, m Int64))') ORDER BY id"

echo "== old and new files, explicit structure =="
$CLICKHOUSE_CLIENT -q "SELECT id, payload, variantType(payload) FROM file('${prefix}_{old,new}.avro', 'Avro',
  'id Int32, payload Variant(Tuple(k Int64), Tuple(s String), Tuple(n Float64, m Int64))') ORDER BY id"

echo "== old and new files, schema_inference_mode = 'union' =="
$CLICKHOUSE_CLIENT -q "SELECT DISTINCT toTypeName(payload) FROM file('${prefix}_{old,new}.avro') SETTINGS schema_inference_mode = 'union'"
$CLICKHOUSE_CLIENT -q "SELECT id, payload, variantType(payload) FROM file('${prefix}_{old,new}.avro') ORDER BY id SETTINGS schema_inference_mode = 'union'"

echo "== old and evolved files, schema_inference_mode = 'union' =="
$CLICKHOUSE_CLIENT -q "SELECT DISTINCT toTypeName(payload) FROM file('${prefix}_{old,evolved}.avro') SETTINGS schema_inference_mode = 'union'"
$CLICKHOUSE_CLIENT -q "SELECT id, payload, variantType(payload) FROM file('${prefix}_{old,evolved}.avro') ORDER BY id SETTINGS schema_inference_mode = 'union'"

echo "== new file, Variant without one of the union types =="
$CLICKHOUSE_CLIENT -q "SELECT * FROM file('${prefix}_new.avro', 'Avro',
  'id Int32, payload Variant(Tuple(k Int64), Tuple(s String))')" 2>&1 | grep -m1 -c 'are not compatible'

rm -f "$CLICKHOUSE_USER_FILES/${prefix}"_*.avro
