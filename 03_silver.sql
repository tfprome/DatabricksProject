-- =====================================================================
-- 03_silver.sql  -  Silver layer (typed, validated, deduplicated, reconciled)
-- Catalog: workspace   Schema: ecom_poc
--
-- PROCESSING PRECEDENCE (every Bronze row lands in exactly ONE bucket):
--   1. Safe-cast text to types with try_cast (unparseable -> NULL, never an error)
--   2. Validate business rules. Any failure -> QUARANTINE (with rejection_reason)
--   3. Among VALID rows only, deduplicate on the business key:
--        keep 1 winner  -> ACCEPTED (silver_*)
--        all others     -> DUPLICATE LOSERS
--   4. Transactions are validated AFTER silver_orders exists (orphan check)
--
-- INVARIANT:  bronze rows = accepted + quarantined + duplicate losers (no overlap)
--
-- KEEP-ONE RULE
--   orders:       latest order_date, then latest _ingested_at, then smallest _row_id
--   transactions: latest txn_ts,     then latest _ingested_at, then smallest _row_id
--   (_row_id is unique per row, so the choice is always deterministic)
--
-- Silver is rebuilt from ONE Bronze batch each run (CREATE OR REPLACE) -> safe to re-run.
-- =====================================================================

USE CATALOG workspace;
USE SCHEMA ecom_poc;

-- Must match the batch id you used when loading Bronze
DECLARE OR REPLACE VARIABLE v_batch_id STRING DEFAULT '2026-11-18_001';

-- =====================================================================
-- A. ORDERS: type + validate + rank, all in one staging table
-- =====================================================================
CREATE OR REPLACE TABLE workspace.ecom_poc.stg_orders AS
WITH typed AS (
  SELECT
    b.*,
    nullif(trim(order_id), '')                          AS order_id_c,
    nullif(trim(customer_id), '')                       AS customer_id_c,
    try_cast(trim(order_date) AS DATE)                  AS order_date_d,
    lower(trim(category))                               AS category_c,
    try_cast(trim(quantity) AS INT)                     AS quantity_i,
    try_cast(trim(unit_price) AS DECIMAL(12,2))         AS unit_price_d,
    lower(trim(order_status))                           AS order_status_c,
    upper(trim(country))                                AS country_c
  FROM workspace.ecom_poc.bronze_orders b
  WHERE b._batch_id = v_batch_id
),
validated AS (
  SELECT
    t.*,
    nullif(concat_ws(';',
      CASE WHEN order_id_c IS NULL                                   THEN 'missing_order_id' END,
      CASE WHEN customer_id_c IS NULL                                THEN 'missing_customer_id' END,
      CASE WHEN order_date_d IS NULL                                 THEN 'invalid_order_date' END,
      CASE WHEN order_date_d > current_date()                        THEN 'future_order_date' END,
      CASE WHEN quantity_i IS NULL                                   THEN 'invalid_quantity' END,
      CASE WHEN quantity_i < 1 OR quantity_i > 100                   THEN 'quantity_out_of_range' END,
      CASE WHEN unit_price_d IS NULL                                 THEN 'invalid_unit_price' END,
      CASE WHEN unit_price_d <= 0 OR unit_price_d > 10000            THEN 'unit_price_out_of_range' END,
      CASE WHEN order_status_c IS NULL
             OR order_status_c NOT IN ('completed','shipped','pending','cancelled','refunded')
                                                                     THEN 'invalid_order_status' END,
      CASE WHEN category_c IS NULL
             OR category_c NOT IN ('electronics','fashion','home','beauty','sports','books','toys','grocery')
                                                                     THEN 'invalid_category' END,
      CASE WHEN country_c IS NULL
             OR country_c NOT IN ('US','GB','DE','FR','CA','AU','BD','IN')
                                                                     THEN 'invalid_country' END
    ), '') AS rejection_reason
  FROM typed t
),
ranked AS (
  SELECT
    v.*,
    -- ranking happens among VALID rows only (partitioned by validity flag + business key)
    ROW_NUMBER() OVER (PARTITION BY (rejection_reason IS NULL), order_id_c
                       ORDER BY order_date_d DESC, _ingested_at DESC, _row_id ASC) AS rn,
    FIRST_VALUE(_row_id)   OVER (PARTITION BY (rejection_reason IS NULL), order_id_c
                       ORDER BY order_date_d DESC, _ingested_at DESC, _row_id ASC) AS winner_row_id,
    FIRST_VALUE(_row_hash) OVER (PARTITION BY (rejection_reason IS NULL), order_id_c
                       ORDER BY order_date_d DESC, _ingested_at DESC, _row_id ASC) AS winner_row_hash
  FROM validated v
)
SELECT
  r.*,
  CASE WHEN rejection_reason IS NOT NULL THEN 'quarantined'
       WHEN rn = 1                       THEN 'accepted'
       ELSE                                   'duplicate_loser'
  END AS outcome
FROM ranked r;

-- A1. Accepted orders (typed, clean, unique order_id)
CREATE OR REPLACE TABLE workspace.ecom_poc.silver_orders AS
SELECT
  order_id_c     AS order_id,
  customer_id_c  AS customer_id,
  order_date_d   AS order_date,
  category_c     AS category,
  quantity_i     AS quantity,
  unit_price_d   AS unit_price,
  order_status_c AS order_status,
  country_c      AS country,
  _row_id, _row_hash, _batch_id, _source_file, _ingested_at
FROM workspace.ecom_poc.stg_orders
WHERE outcome = 'accepted';

-- A2. Quarantined orders: ORIGINAL raw text values + every reason (separated by ';')
CREATE OR REPLACE TABLE workspace.ecom_poc.quarantine_orders AS
SELECT
  order_id, customer_id, order_date, category, quantity, unit_price, order_status, country,
  rejection_reason,
  _row_id, _row_hash, _batch_id, _source_file, _ingested_at
FROM workspace.ecom_poc.stg_orders
WHERE outcome = 'quarantined';

-- A3. Duplicate losers: valid rows that lost the keep-one rule
CREATE OR REPLACE TABLE workspace.ecom_poc.duplicate_losers_orders AS
SELECT
  order_id, customer_id, order_date, category, quantity, unit_price, order_status, country,
  winner_row_id,
  CASE WHEN _row_hash = winner_row_hash THEN 'exact_duplicate_row'
       ELSE 'same_key_different_content' END AS duplicate_type,
  _row_id, _row_hash, _batch_id, _source_file, _ingested_at
FROM workspace.ecom_poc.stg_orders
WHERE outcome = 'duplicate_loser';

-- =====================================================================
-- B. TRANSACTIONS (needs silver_orders for the orphan check)
-- =====================================================================
CREATE OR REPLACE TABLE workspace.ecom_poc.stg_transactions AS
WITH typed AS (
  SELECT
    b.*,
    nullif(trim(txn_id), '')                            AS txn_id_c,
    nullif(trim(order_id), '')                          AS order_id_c,
    lower(trim(payment_method))                         AS payment_method_c,
    try_cast(trim(amount) AS DECIMAL(14,2))             AS amount_d,
    upper(trim(currency))                               AS currency_c,
    lower(trim(txn_status))                             AS txn_status_c,
    try_cast(trim(txn_ts) AS TIMESTAMP)                 AS txn_ts_t
  FROM workspace.ecom_poc.bronze_transactions b
  WHERE b._batch_id = v_batch_id
),
validated AS (
  SELECT
    t.*,
    nullif(concat_ws(';',
      CASE WHEN txn_id_c IS NULL                                     THEN 'missing_txn_id' END,
      CASE WHEN order_id_c IS NULL                                   THEN 'missing_order_id' END,
      -- relationship check: order must exist in ACCEPTED silver_orders
      CASE WHEN order_id_c IS NOT NULL AND o.order_id IS NULL        THEN 'orphan_order_id' END,
      CASE WHEN nullif(trim(t.amount), '') IS NULL                   THEN 'missing_amount' END,
      CASE WHEN nullif(trim(t.amount), '') IS NOT NULL
                AND amount_d IS NULL                                 THEN 'invalid_amount' END,
      CASE WHEN amount_d <= 0 OR amount_d > 50000                    THEN 'amount_out_of_range' END,
      CASE WHEN payment_method_c IS NULL
             OR payment_method_c NOT IN ('card','paypal','bank_transfer','wallet','cash_on_delivery')
                                                                     THEN 'invalid_payment_method' END,
      CASE WHEN currency_c IS NULL
             OR currency_c NOT IN ('USD','EUR','GBP')                THEN 'unsupported_currency' END,
      CASE WHEN txn_status_c IS NULL
             OR txn_status_c NOT IN ('success','failed','pending','refunded')
                                                                     THEN 'invalid_txn_status' END,
      CASE WHEN txn_ts_t IS NULL                                     THEN 'invalid_txn_ts' END,
      CASE WHEN txn_ts_t > current_timestamp()                       THEN 'future_txn_ts' END
    ), '') AS rejection_reason
  FROM typed t
  LEFT JOIN workspace.ecom_poc.silver_orders o   -- order_id is unique in silver_orders: no fan-out
         ON t.order_id_c = o.order_id
),
ranked AS (
  SELECT
    v.*,
    ROW_NUMBER() OVER (PARTITION BY (rejection_reason IS NULL), txn_id_c
                       ORDER BY txn_ts_t DESC, _ingested_at DESC, _row_id ASC) AS rn,
    FIRST_VALUE(_row_id)   OVER (PARTITION BY (rejection_reason IS NULL), txn_id_c
                       ORDER BY txn_ts_t DESC, _ingested_at DESC, _row_id ASC) AS winner_row_id,
    FIRST_VALUE(_row_hash) OVER (PARTITION BY (rejection_reason IS NULL), txn_id_c
                       ORDER BY txn_ts_t DESC, _ingested_at DESC, _row_id ASC) AS winner_row_hash
  FROM validated v
)
SELECT
  r.*,
  CASE WHEN rejection_reason IS NOT NULL THEN 'quarantined'
       WHEN rn = 1                       THEN 'accepted'
       ELSE                                   'duplicate_loser'
  END AS outcome
FROM ranked r;

CREATE OR REPLACE TABLE workspace.ecom_poc.silver_transactions AS
SELECT
  txn_id_c           AS txn_id,
  order_id_c         AS order_id,
  payment_method_c   AS payment_method,
  amount_d           AS amount,
  currency_c         AS currency,
  txn_status_c       AS txn_status,
  txn_ts_t           AS txn_ts,
  _row_id, _row_hash, _batch_id, _source_file, _ingested_at
FROM workspace.ecom_poc.stg_transactions
WHERE outcome = 'accepted';

CREATE OR REPLACE TABLE workspace.ecom_poc.quarantine_transactions AS
SELECT
  txn_id, order_id, payment_method, amount, currency, txn_status, txn_ts,
  rejection_reason,
  _row_id, _row_hash, _batch_id, _source_file, _ingested_at
FROM workspace.ecom_poc.stg_transactions
WHERE outcome = 'quarantined';

CREATE OR REPLACE TABLE workspace.ecom_poc.duplicate_losers_transactions AS
SELECT
  txn_id, order_id, payment_method, amount, currency, txn_status, txn_ts,
  winner_row_id,
  CASE WHEN _row_hash = winner_row_hash THEN 'exact_duplicate_row'
       ELSE 'same_key_different_content' END AS duplicate_type,
  _row_id, _row_hash, _batch_id, _source_file, _ingested_at
FROM workspace.ecom_poc.stg_transactions
WHERE outcome = 'duplicate_loser';

-- =====================================================================
-- C. TABLE DESCRIPTIONS
-- =====================================================================
COMMENT ON TABLE workspace.ecom_poc.silver_orders IS
  'Silver: typed, validated orders. Grain: one row per order_id (unique). Rebuilt from one Bronze batch.';
COMMENT ON TABLE workspace.ecom_poc.silver_transactions IS
  'Silver: typed, validated payment transactions. Grain: one row per txn_id (unique). Every order_id exists in silver_orders.';
COMMENT ON TABLE workspace.ecom_poc.quarantine_orders IS
  'Rejected orders: original raw text values plus rejection_reason (multiple reasons separated by semicolon).';
COMMENT ON TABLE workspace.ecom_poc.quarantine_transactions IS
  'Rejected transactions: original raw text values plus rejection_reason (multiple reasons separated by semicolon).';
COMMENT ON TABLE workspace.ecom_poc.duplicate_losers_orders IS
  'Valid orders that lost the keep-one rule for their order_id. duplicate_type shows exact vs same-key-different-content.';
COMMENT ON TABLE workspace.ecom_poc.duplicate_losers_transactions IS
  'Valid transactions that lost the keep-one rule for their txn_id. duplicate_type shows exact vs same-key-different-content.';
COMMENT ON TABLE workspace.ecom_poc.stg_orders IS
  'Staging: every Bronze order with typed columns, rejection_reason, rank and outcome. Used to build the Silver outcome tables.';
COMMENT ON TABLE workspace.ecom_poc.stg_transactions IS
  'Staging: every Bronze transaction with typed columns, rejection_reason, rank and outcome. Used to build the Silver outcome tables.';


-- =====================================================================
-- E. EVIDENCE: row counts by rule, duplicates, samples
-- =====================================================================
-- E1. Quarantined rows per rule (one row can break several rules)
SELECT 'orders' AS dataset, rule, COUNT(*) AS rows_failing
FROM workspace.ecom_poc.quarantine_orders
LATERAL VIEW explode(split(rejection_reason, ';')) x AS rule
GROUP BY rule
UNION ALL
SELECT 'transactions', rule, COUNT(*)
FROM workspace.ecom_poc.quarantine_transactions
LATERAL VIEW explode(split(rejection_reason, ';')) x AS rule
GROUP BY rule
ORDER BY dataset, rows_failing DESC;

-- E2. Exact duplicates vs same-key-different-content
SELECT 'orders' AS dataset, duplicate_type, COUNT(*) AS losers
FROM workspace.ecom_poc.duplicate_losers_orders GROUP BY duplicate_type
UNION ALL
SELECT 'transactions', duplicate_type, COUNT(*)
FROM workspace.ecom_poc.duplicate_losers_transactions GROUP BY duplicate_type;

-- E3. Example winners and losers (orders)
SELECT d.order_id, d.duplicate_type,
       w.quantity AS winner_quantity, d.quantity AS loser_quantity_raw,
       w.unit_price AS winner_price, d.unit_price AS loser_price_raw,
       w._row_id AS winner_row_id, d._row_id AS loser_row_id
FROM workspace.ecom_poc.duplicate_losers_orders d
JOIN workspace.ecom_poc.silver_orders w ON d.winner_row_id = w._row_id
ORDER BY d.duplicate_type DESC
LIMIT 20;

-- E4. Sample quarantined rows
SELECT * FROM workspace.ecom_poc.quarantine_orders LIMIT 20;
SELECT * FROM workspace.ecom_poc.quarantine_transactions LIMIT 20;

-- E5. Before / after type conversion examples (text that could not be parsed becomes NULL)
SELECT quantity AS raw_quantity, quantity_i AS typed_quantity,
       unit_price AS raw_unit_price, unit_price_d AS typed_unit_price,
       order_date AS raw_order_date, order_date_d AS typed_order_date,
       rejection_reason
FROM workspace.ecom_poc.stg_orders
WHERE quantity_i IS NULL OR unit_price_d IS NULL OR order_date_d IS NULL
LIMIT 20;

-- E6. Silver schemas
DESCRIBE TABLE workspace.ecom_poc.silver_orders;
DESCRIBE TABLE workspace.ecom_poc.silver_transactions;

-- =====================================================================
-- F. OPTIONAL QUALITY GATE: fails the run if reconciliation is broken.
--    Useful later in the Lakeflow Job so Gold never runs after a bad Silver.
-- =====================================================================
SELECT assert_true(
  (SELECT COUNT(*) FROM workspace.ecom_poc.bronze_orders WHERE _batch_id = v_batch_id)
    = (SELECT COUNT(*) FROM workspace.ecom_poc.silver_orders)
    + (SELECT COUNT(*) FROM workspace.ecom_poc.quarantine_orders)
    + (SELECT COUNT(*) FROM workspace.ecom_poc.duplicate_losers_orders)
  AND
  (SELECT COUNT(*) FROM workspace.ecom_poc.bronze_transactions WHERE _batch_id = v_batch_id)
    = (SELECT COUNT(*) FROM workspace.ecom_poc.silver_transactions)
    + (SELECT COUNT(*) FROM workspace.ecom_poc.quarantine_transactions)
    + (SELECT COUNT(*) FROM workspace.ecom_poc.duplicate_losers_transactions),
  'Reconciliation failed: Bronze <> accepted + quarantined + duplicate losers'
) AS reconciliation_gate;