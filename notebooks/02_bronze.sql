-- Bronze ingestion in pure SQL (Databricks SQL editor or a %sql notebook cell)
-- Batch id used below: 2026-11-18_001   (find & replace it to load a new batch)
-- Rule: every source column is STRING. Nothing is cleaned, cast, filtered or deduplicated here.

USE CATALOG workspace;
USE SCHEMA ecom_poc;

-- =====================================================================
-- 1. ORDERS
-- =====================================================================
CREATE TABLE IF NOT EXISTS workspace.ecom_poc.bronze_orders (
  order_id      STRING,
  customer_id   STRING,
  order_date    STRING,
  category      STRING,
  quantity      STRING,
  unit_price    STRING,
  order_status  STRING,
  country       STRING,
  _row_hash     STRING    COMMENT 'SHA-256 of all source fields; identical for exact duplicate rows',
  _row_id       STRING    COMMENT 'Unique row identifier: batch + row hash + occurrence number',
  _ingested_at  TIMESTAMP COMMENT 'When the row was loaded',
  _source_file  STRING    COMMENT 'Volume path of the file the row came from',
  _batch_id     STRING    COMMENT 'Load run identifier, used for idempotent re-runs'
)
COMMENT 'Bronze: raw orders.csv as STRING, unmodified, plus audit columns. Grain: one row per source line.';

-- Idempotent load: remove this batch if it was loaded before, then insert it again
DELETE FROM workspace.ecom_poc.bronze_orders WHERE _batch_id = '2026-11-18_001';

INSERT INTO workspace.ecom_poc.bronze_orders
SELECT
  order_id, customer_id, order_date, category, quantity, unit_price, order_status, country,
  _row_hash,
  concat_ws('-', '2026-11-18_001', _row_hash,
            CAST(ROW_NUMBER() OVER (PARTITION BY _row_hash ORDER BY _row_hash) AS STRING)) AS _row_id,
  current_timestamp()  AS _ingested_at,
  src_file             AS _source_file,
  '2026-11-18_001'     AS _batch_id
FROM (
  SELECT
    order_id, customer_id, order_date, category, quantity, unit_price, order_status, country,
    sha2(concat_ws('||',
         coalesce(order_id, ''), coalesce(customer_id, ''), coalesce(order_date, ''),
         coalesce(category, ''), coalesce(quantity, ''), coalesce(unit_price, ''),
         coalesce(order_status, ''), coalesce(country, '')), 256) AS _row_hash,
    _metadata.file_path AS src_file
  FROM read_files(
    '/Volumes/workspace/ecom_poc/raw_files/orders.csv',
    format => 'csv',
    header => true,
    inferColumnTypes => false      -- no type inference: every column stays STRING
  )
);

-- =====================================================================
-- 2. TRANSACTIONS
-- =====================================================================
CREATE TABLE IF NOT EXISTS workspace.ecom_poc.bronze_transactions (
  txn_id          STRING,
  order_id        STRING,
  payment_method  STRING,
  amount          STRING,
  currency        STRING,
  txn_status      STRING,
  txn_ts          STRING,
  _row_hash       STRING    COMMENT 'SHA-256 of all source fields; identical for exact duplicate rows',
  _row_id         STRING    COMMENT 'Unique row identifier: batch + row hash + occurrence number',
  _ingested_at    TIMESTAMP COMMENT 'When the row was loaded',
  _source_file    STRING    COMMENT 'Volume path of the file the row came from',
  _batch_id       STRING    COMMENT 'Load run identifier, used for idempotent re-runs'
)
COMMENT 'Bronze: raw transactions.csv as STRING, unmodified, plus audit columns. Grain: one row per source line.';

DELETE FROM workspace.ecom_poc.bronze_transactions WHERE _batch_id = '2026-11-18_001';

INSERT INTO workspace.ecom_poc.bronze_transactions
SELECT
  txn_id, order_id, payment_method, amount, currency, txn_status, txn_ts,
  _row_hash,
  concat_ws('-', '2026-11-18_001', _row_hash,
            CAST(ROW_NUMBER() OVER (PARTITION BY _row_hash ORDER BY _row_hash) AS STRING)) AS _row_id,
  current_timestamp()  AS _ingested_at,
  src_file             AS _source_file,
  '2026-11-18_001'     AS _batch_id
FROM (
  SELECT
    txn_id, order_id, payment_method, amount, currency, txn_status, txn_ts,
    sha2(concat_ws('||',
         coalesce(txn_id, ''), coalesce(order_id, ''), coalesce(payment_method, ''),
         coalesce(amount, ''), coalesce(currency, ''), coalesce(txn_status, ''),
         coalesce(txn_ts, '')), 256) AS _row_hash,
    _metadata.file_path AS src_file
  FROM read_files(
    '/Volumes/workspace/ecom_poc/raw_files/transactions.csv',
    format => 'csv',
    header => true,
    inferColumnTypes => false
  )
);

-- =====================================================================
-- 3. LOSSLESS CHECK: source data rows must equal Bronze rows
--    (source count = text lines minus the header line)
-- =====================================================================
SELECT 'orders' AS dataset,
       (SELECT COUNT(*) - 1 FROM read_files('/Volumes/workspace/ecom_poc/raw_files/orders.csv', format => 'text')) AS source_rows,
       (SELECT COUNT(*) FROM workspace.ecom_poc.bronze_orders WHERE _batch_id = '2026-11-18_001')                  AS bronze_rows
UNION ALL
SELECT 'transactions',
       (SELECT COUNT(*) - 1 FROM read_files('/Volumes/workspace/ecom_poc/raw_files/transactions.csv', format => 'text')),
       (SELECT COUNT(*) FROM workspace.ecom_poc.bronze_transactions WHERE _batch_id = '2026-11-18_001');

-- =====================================================================
-- 4. IDEMPOTENCY CHECK: run this whole script twice; counts must NOT double
-- =====================================================================
SELECT 'orders' AS dataset, _batch_id, COUNT(*) AS row_count, COUNT(DISTINCT _row_id) AS distinct_row_ids
FROM workspace.ecom_poc.bronze_orders GROUP BY _batch_id
UNION ALL
SELECT 'transactions', _batch_id, COUNT(*), COUNT(DISTINCT _row_id)
FROM workspace.ecom_poc.bronze_transactions GROUP BY _batch_id;

-- =====================================================================
-- 5. EVIDENCE: schema and sample rows
-- =====================================================================
DESCRIBE TABLE workspace.ecom_poc.bronze_orders;
DESCRIBE TABLE workspace.ecom_poc.bronze_transactions;
SELECT * FROM workspace.ecom_poc.bronze_orders LIMIT 10;
SELECT * FROM workspace.ecom_poc.bronze_transactions LIMIT 10;