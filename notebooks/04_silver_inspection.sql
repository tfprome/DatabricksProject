DECLARE OR REPLACE VARIABLE v_batch_id STRING DEFAULT '2026-11-18_001';

-- =====================================================================
-- D. RECONCILIATION: Bronze = accepted + quarantined + duplicate losers
-- =====================================================================
SELECT *, bronze_rows = (accepted + quarantined + duplicate_losers) AS reconciled
FROM (
  SELECT 'orders' AS dataset,
    (SELECT COUNT(*) FROM workspace.ecom_poc.bronze_orders WHERE _batch_id = v_batch_id) AS bronze_rows,
    (SELECT COUNT(*) FROM workspace.ecom_poc.silver_orders)                              AS accepted,
    (SELECT COUNT(*) FROM workspace.ecom_poc.quarantine_orders)                          AS quarantined,
    (SELECT COUNT(*) FROM workspace.ecom_poc.duplicate_losers_orders)                    AS duplicate_losers
  UNION ALL
  SELECT 'transactions',
    (SELECT COUNT(*) FROM workspace.ecom_poc.bronze_transactions WHERE _batch_id = v_batch_id),
    (SELECT COUNT(*) FROM workspace.ecom_poc.silver_transactions),
    (SELECT COUNT(*) FROM workspace.ecom_poc.quarantine_transactions),
    (SELECT COUNT(*) FROM workspace.ecom_poc.duplicate_losers_transactions)
);

-- D2. No overlap, full coverage, unique keys (every number below must be 0)
SELECT 'orders' AS dataset,
  (SELECT COUNT(*) FROM workspace.ecom_poc.silver_orders s
     JOIN workspace.ecom_poc.quarantine_orders q ON s._row_id = q._row_id)               AS accepted_and_quarantined,
  (SELECT COUNT(*) FROM workspace.ecom_poc.silver_orders s
     JOIN workspace.ecom_poc.duplicate_losers_orders d ON s._row_id = d._row_id)         AS accepted_and_loser,
  (SELECT COUNT(*) FROM workspace.ecom_poc.quarantine_orders q
     JOIN workspace.ecom_poc.duplicate_losers_orders d ON q._row_id = d._row_id)         AS quarantined_and_loser,
  (SELECT COUNT(*) FROM (SELECT _row_id FROM workspace.ecom_poc.bronze_orders WHERE _batch_id = v_batch_id) b
     LEFT ANTI JOIN (SELECT _row_id FROM workspace.ecom_poc.silver_orders
                     UNION ALL SELECT _row_id FROM workspace.ecom_poc.quarantine_orders
                     UNION ALL SELECT _row_id FROM workspace.ecom_poc.duplicate_losers_orders) u
       ON b._row_id = u._row_id)                                                         AS bronze_rows_with_no_outcome,
  (SELECT COUNT(*) - COUNT(DISTINCT order_id) FROM workspace.ecom_poc.silver_orders)     AS duplicate_keys_in_silver
UNION ALL
SELECT 'transactions',
  (SELECT COUNT(*) FROM workspace.ecom_poc.silver_transactions s
     JOIN workspace.ecom_poc.quarantine_transactions q ON s._row_id = q._row_id),
  (SELECT COUNT(*) FROM workspace.ecom_poc.silver_transactions s
     JOIN workspace.ecom_poc.duplicate_losers_transactions d ON s._row_id = d._row_id),
  (SELECT COUNT(*) FROM workspace.ecom_poc.quarantine_transactions q
     JOIN workspace.ecom_poc.duplicate_losers_transactions d ON q._row_id = d._row_id),
  (SELECT COUNT(*) FROM (SELECT _row_id FROM workspace.ecom_poc.bronze_transactions WHERE _batch_id = v_batch_id) b
     LEFT ANTI JOIN (SELECT _row_id FROM workspace.ecom_poc.silver_transactions
                     UNION ALL SELECT _row_id FROM workspace.ecom_poc.quarantine_transactions
                     UNION ALL SELECT _row_id FROM workspace.ecom_poc.duplicate_losers_transactions) u
       ON b._row_id = u._row_id),
  (SELECT COUNT(*) - COUNT(DISTINCT txn_id) FROM workspace.ecom_poc.silver_transactions);

-- D3. Relationship check: accepted transactions pointing to a missing order (must be 0)
SELECT COUNT(*) AS accepted_txns_without_order
FROM workspace.ecom_poc.silver_transactions t
LEFT ANTI JOIN workspace.ecom_poc.silver_orders o ON t.order_id = o.order_id;