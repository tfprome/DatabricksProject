-- sql/quality_assertions.sql  -  data-quality checks. Replace the batch id if yours differs.
-- Expected results are in the comments.

-- 1. Bronze = source file rows (data rows = text lines minus header). Expect equal, 1,000,000 each.
SELECT 'orders' AS dataset,
  (SELECT COUNT(*) - 1 FROM read_files('/Volumes/workspace/ecom_poc/raw_files/orders.csv', format => 'text')) AS source_rows,
  (SELECT COUNT(*) FROM workspace.ecom_poc.bronze_orders WHERE _batch_id = '2026-11-18_001') AS bronze_rows
UNION ALL
SELECT 'transactions',
  (SELECT COUNT(*) - 1 FROM read_files('/Volumes/workspace/ecom_poc/raw_files/transactions.csv', format => 'text')),
  (SELECT COUNT(*) FROM workspace.ecom_poc.bronze_transactions WHERE _batch_id = '2026-11-18_001');

-- 2. Reconciliation: Bronze = accepted + quarantined + duplicate losers. Expect reconciled = true.
SELECT *, bronze_rows = (accepted + quarantined + duplicate_losers) AS reconciled FROM (
  SELECT 'orders' AS dataset,
    (SELECT COUNT(*) FROM workspace.ecom_poc.bronze_orders WHERE _batch_id = '2026-11-18_001') AS bronze_rows,
    (SELECT COUNT(*) FROM workspace.ecom_poc.silver_orders) AS accepted,
    (SELECT COUNT(*) FROM workspace.ecom_poc.quarantine_orders) AS quarantined,
    (SELECT COUNT(*) FROM workspace.ecom_poc.duplicate_losers_orders) AS duplicate_losers
  UNION ALL
  SELECT 'transactions',
    (SELECT COUNT(*) FROM workspace.ecom_poc.bronze_transactions WHERE _batch_id = '2026-11-18_001'),
    (SELECT COUNT(*) FROM workspace.ecom_poc.silver_transactions),
    (SELECT COUNT(*) FROM workspace.ecom_poc.quarantine_transactions),
    (SELECT COUNT(*) FROM workspace.ecom_poc.duplicate_losers_transactions));

-- 3. No overlap between outcome tables (orders). Expect 0 in every column.
SELECT
  (SELECT COUNT(*) FROM workspace.ecom_poc.silver_orders s JOIN workspace.ecom_poc.quarantine_orders q ON s._row_id = q._row_id) AS accepted_and_quarantined,
  (SELECT COUNT(*) FROM workspace.ecom_poc.silver_orders s JOIN workspace.ecom_poc.duplicate_losers_orders d ON s._row_id = d._row_id) AS accepted_and_loser,
  (SELECT COUNT(*) FROM workspace.ecom_poc.quarantine_orders q JOIN workspace.ecom_poc.duplicate_losers_orders d ON q._row_id = d._row_id) AS quarantined_and_loser,
  (SELECT COUNT(*) FROM (SELECT _row_id FROM workspace.ecom_poc.bronze_orders WHERE _batch_id = '2026-11-18_001') b
     LEFT ANTI JOIN (SELECT _row_id FROM workspace.ecom_poc.silver_orders
                     UNION ALL SELECT _row_id FROM workspace.ecom_poc.quarantine_orders
                     UNION ALL SELECT _row_id FROM workspace.ecom_poc.duplicate_losers_orders) u ON b._row_id = u._row_id) AS bronze_rows_without_outcome;

-- 3b. Same for transactions. Expect 0 in every column.
SELECT
  (SELECT COUNT(*) FROM workspace.ecom_poc.silver_transactions s JOIN workspace.ecom_poc.quarantine_transactions q ON s._row_id = q._row_id) AS accepted_and_quarantined,
  (SELECT COUNT(*) FROM workspace.ecom_poc.silver_transactions s JOIN workspace.ecom_poc.duplicate_losers_transactions d ON s._row_id = d._row_id) AS accepted_and_loser,
  (SELECT COUNT(*) FROM workspace.ecom_poc.quarantine_transactions q JOIN workspace.ecom_poc.duplicate_losers_transactions d ON q._row_id = d._row_id) AS quarantined_and_loser,
  (SELECT COUNT(*) FROM (SELECT _row_id FROM workspace.ecom_poc.bronze_transactions WHERE _batch_id = '2026-11-18_001') b
     LEFT ANTI JOIN (SELECT _row_id FROM workspace.ecom_poc.silver_transactions
                     UNION ALL SELECT _row_id FROM workspace.ecom_poc.quarantine_transactions
                     UNION ALL SELECT _row_id FROM workspace.ecom_poc.duplicate_losers_transactions) u ON b._row_id = u._row_id) AS bronze_rows_without_outcome;

-- 4. Unique business keys in Silver. Expect 0.
SELECT (SELECT COUNT(*) - COUNT(DISTINCT order_id) FROM workspace.ecom_poc.silver_orders) AS duplicate_order_ids,
       (SELECT COUNT(*) - COUNT(DISTINCT txn_id)   FROM workspace.ecom_poc.silver_transactions) AS duplicate_txn_ids;

-- 5. Relationship check: accepted transactions without an accepted order. Expect 0.
SELECT COUNT(*) AS accepted_txns_without_order
FROM workspace.ecom_poc.silver_transactions t
LEFT ANTI JOIN workspace.ecom_poc.silver_orders o ON t.order_id = o.order_id;

-- 6. Idempotency: exactly one batch per Bronze table, rows = distinct _row_id. Expect 1,000,000 each.
SELECT 'orders' AS dataset, _batch_id, COUNT(*) AS row_count, COUNT(DISTINCT _row_id) AS distinct_row_ids
FROM workspace.ecom_poc.bronze_orders GROUP BY _batch_id
UNION ALL
SELECT 'transactions', _batch_id, COUNT(*), COUNT(DISTINCT _row_id)
FROM workspace.ecom_poc.bronze_transactions GROUP BY _batch_id;

-- 7. Gold: unique keys. Expect 0 in every row.
SELECT 'gold_daily_sales' AS gold_table, COUNT(*) - COUNT(DISTINCT order_date) AS duplicate_keys FROM workspace.ecom_poc.gold_daily_sales
UNION ALL SELECT 'gold_revenue_breakdown', COUNT(*) - COUNT(DISTINCT concat_ws('|', order_date, category, country)) FROM workspace.ecom_poc.gold_revenue_breakdown
UNION ALL SELECT 'gold_payment_success', COUNT(*) - COUNT(DISTINCT concat_ws('|', order_date, payment_method)) FROM workspace.ecom_poc.gold_payment_success
UNION ALL SELECT 'gold_top_customers', COUNT(*) - COUNT(DISTINCT customer_id) FROM workspace.ecom_poc.gold_top_customers;

-- 8. Gold: no fan-out. Expect 0.
SELECT COUNT(*) - COUNT(DISTINCT txn_id) AS duplicated_transactions_in_revenue_base
FROM workspace.ecom_poc.vw_revenue_base;