-- sql/silver_rules.sql  -  Silver business-rule matrix and rows failing each rule
-- The rules themselves are enforced in notebooks/03_silver.sql (rejection_reason CASE logic).
-- Precedence: try_cast -> validate (quarantine) -> dedupe valid rows (duplicate losers) -> accepted.
--
-- RULE MATRIX
-- dataset       field                     rule                                              reason code
-- orders        order_id                  not null/blank                                    missing_order_id
-- orders        customer_id               not null/blank                                    missing_customer_id
-- orders        order_date                parseable date                                    invalid_order_date
-- orders        order_date                not in the future                                 future_order_date
-- orders        quantity                  integer                                           invalid_quantity
-- orders        quantity                  1..100                                            quantity_out_of_range
-- orders        unit_price                numeric                                           invalid_unit_price
-- orders        unit_price                >0 and <=10000                                    unit_price_out_of_range
-- orders        order_status              completed|shipped|pending|cancelled|refunded      invalid_order_status
-- orders        category                  8 allowed categories                              invalid_category
-- orders        country                   US|GB|DE|FR|CA|AU|BD|IN                           invalid_country
-- transactions  txn_id                    not null/blank                                    missing_txn_id
-- transactions  order_id                  not null/blank                                    missing_order_id
-- transactions  order_id                  exists in accepted silver_orders                  orphan_order_id
-- transactions  amount                    present                                           missing_amount
-- transactions  amount                    numeric                                           invalid_amount
-- transactions  amount                    >0 and <=50000                                    amount_out_of_range
-- transactions  payment_method            card|paypal|bank_transfer|wallet|cash_on_delivery invalid_payment_method
-- transactions  currency                  USD|EUR|GBP                                       unsupported_currency
-- transactions  txn_status                success|failed|pending|refunded                   invalid_txn_status
-- transactions  txn_ts                    parseable timestamp                               invalid_txn_ts
-- transactions  txn_ts                    not in the future                                 future_txn_ts
-- Dedup keep-one rule: latest date, then latest _ingested_at, then smallest _row_id.

-- Rows failing each rule (one row can fail several rules)
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

-- Duplicates: exact copies vs same key with different content
SELECT 'orders' AS dataset, duplicate_type, COUNT(*) AS losers
FROM workspace.ecom_poc.duplicate_losers_orders GROUP BY duplicate_type
UNION ALL
SELECT 'transactions', duplicate_type, COUNT(*)
FROM workspace.ecom_poc.duplicate_losers_transactions GROUP BY duplicate_type;