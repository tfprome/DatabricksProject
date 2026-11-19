-- =====================================================================
-- 04_gold.sql  -  Gold layer (business-ready marts)
-- Catalog: workspace   Schema: ecom_poc
--
-- REVENUE DEFINITION (used by EVERY Gold table, the AI/BI dashboard and Power BI)
--   revenue = SUM(silver_transactions.amount)
--             WHERE txn_status = 'success'
--               AND currency   = 'USD'                          (no FX conversion: EUR/GBP excluded)
--               AND the order's order_status NOT IN ('cancelled','refunded')
--   * partial and repeat payments: each successful transaction counts once
--   * source of truth: silver_transactions (amount) joined many-to-one to silver_orders
--   * revenue is dated by the ORDER date (order_date), so every Gold table shares one date field
--
-- The definition lives in ONE place: the view vw_revenue_base below.
-- =====================================================================

USE CATALOG workspace;
USE SCHEMA ecom_poc;

-- =====================================================================
-- 0. Shared revenue base (one row per eligible transaction)
--    Many-to-one join (many transactions -> one order), silver_orders.order_id is unique,
--    so amounts are never multiplied.
-- =====================================================================
CREATE OR REPLACE VIEW workspace.ecom_poc.vw_revenue_base AS
SELECT
  t.txn_id,
  t.order_id,
  o.customer_id,
  o.order_date,
  o.category,
  o.country,
  o.order_status,
  t.payment_method,
  t.amount
FROM workspace.ecom_poc.silver_transactions t
JOIN workspace.ecom_poc.silver_orders o
  ON t.order_id = o.order_id
WHERE t.txn_status = 'success'
  AND t.currency   = 'USD'
  AND o.order_status NOT IN ('cancelled', 'refunded');

-- =====================================================================
-- 1. gold_daily_sales   grain: one row per order_date   key: order_date
--    Orders and cancellations come from silver_orders; revenue comes from the revenue base.
--    They are aggregated SEPARATELY to one row per day and then joined (no fan-out).
-- =====================================================================
CREATE OR REPLACE TABLE workspace.ecom_poc.gold_daily_sales AS
WITH orders_daily AS (
  SELECT
    order_date,
    COUNT(*)                                                  AS orders_count,
    SUM(CASE WHEN order_status = 'cancelled' THEN 1 ELSE 0 END) AS cancelled_orders
  FROM workspace.ecom_poc.silver_orders
  GROUP BY order_date
),
revenue_daily AS (
  SELECT
    order_date,
    SUM(amount) AS revenue,
    COUNT(*)    AS paid_transactions
  FROM workspace.ecom_poc.vw_revenue_base
  GROUP BY order_date
)
SELECT
  o.order_date,
  o.orders_count,
  o.cancelled_orders,
  CAST(ROUND(o.cancelled_orders / o.orders_count, 4) AS DECIMAL(6,4)) AS cancellation_rate,
  CAST(COALESCE(r.revenue, 0) AS DECIMAL(18,2))                       AS revenue,
  COALESCE(r.paid_transactions, 0)                                    AS paid_transactions
FROM orders_daily o
LEFT JOIN revenue_daily r
  ON o.order_date = r.order_date;

-- =====================================================================
-- 2. gold_revenue_breakdown   grain: order_date x category x country
--    key: (order_date, category, country)
-- =====================================================================
CREATE OR REPLACE TABLE workspace.ecom_poc.gold_revenue_breakdown AS
SELECT
  order_date,
  category,
  country,
  CAST(SUM(amount) AS DECIMAL(18,2)) AS revenue,
  COUNT(*)                           AS paid_transactions,
  COUNT(DISTINCT order_id)           AS paid_orders
FROM workspace.ecom_poc.vw_revenue_base
GROUP BY order_date, category, country;

-- =====================================================================
-- 3. gold_payment_success   grain: order_date x payment_method
--    key: (order_date, payment_method)
--    Uses ALL accepted transactions (every status and currency): it measures payment
--    performance, not revenue. For a rate over several rows use SUM(success_txns)/SUM(total_txns).
-- =====================================================================
CREATE OR REPLACE TABLE workspace.ecom_poc.gold_payment_success AS
SELECT
  o.order_date,
  t.payment_method,
  COUNT(*)                                                      AS total_txns,
  SUM(CASE WHEN t.txn_status = 'success'  THEN 1 ELSE 0 END)    AS success_txns,
  SUM(CASE WHEN t.txn_status = 'failed'   THEN 1 ELSE 0 END)    AS failed_txns,
  SUM(CASE WHEN t.txn_status = 'pending'  THEN 1 ELSE 0 END)    AS pending_txns,
  SUM(CASE WHEN t.txn_status = 'refunded' THEN 1 ELSE 0 END)    AS refunded_txns,
  CAST(ROUND(SUM(CASE WHEN t.txn_status = 'success' THEN 1 ELSE 0 END) / COUNT(*), 4) AS DECIMAL(6,4)) AS success_rate
FROM workspace.ecom_poc.silver_transactions t
JOIN workspace.ecom_poc.silver_orders o
  ON t.order_id = o.order_id
GROUP BY o.order_date, t.payment_method;

-- =====================================================================
-- 4. gold_top_customers   grain: one row per customer (top 1,000 by revenue)
--    key: customer_id   (spend_rank is also unique)
-- =====================================================================
CREATE OR REPLACE TABLE workspace.ecom_poc.gold_top_customers AS
WITH customer_revenue AS (
  SELECT
    customer_id,
    SUM(amount)              AS total_revenue,
    COUNT(DISTINCT order_id) AS paid_orders,
    COUNT(*)                 AS paid_transactions,
    MIN(order_date)          AS first_order_date,
    MAX(order_date)          AS last_order_date
  FROM workspace.ecom_poc.vw_revenue_base
  GROUP BY customer_id
),
ranked AS (
  SELECT
    *,
    ROW_NUMBER() OVER (ORDER BY total_revenue DESC, customer_id ASC) AS spend_rank
  FROM customer_revenue
)
SELECT
  spend_rank,
  customer_id,
  CAST(total_revenue AS DECIMAL(18,2)) AS total_revenue,
  paid_orders,
  paid_transactions,
  first_order_date,
  last_order_date
FROM ranked
WHERE spend_rank <= 1000;

-- =====================================================================
-- 5. DOCUMENTATION (table + column comments, visible in Catalog Explorer)
-- =====================================================================
COMMENT ON TABLE workspace.ecom_poc.vw_revenue_base IS
  'Eligible revenue transactions. Rule: txn_status=success, currency=USD, order not cancelled/refunded. One row per transaction. Single source of the revenue definition.';

COMMENT ON TABLE workspace.ecom_poc.gold_daily_sales IS
  'Grain: one row per order_date. Key: order_date. Orders, cancellations and revenue per order day. Revenue per the shared definition (USD, successful payments, order not cancelled/refunded).';
ALTER TABLE workspace.ecom_poc.gold_daily_sales ALTER COLUMN order_date COMMENT 'Date the order was placed (key)';
ALTER TABLE workspace.ecom_poc.gold_daily_sales ALTER COLUMN orders_count COMMENT 'Number of accepted orders placed that day, any status';
ALTER TABLE workspace.ecom_poc.gold_daily_sales ALTER COLUMN cancelled_orders COMMENT 'Orders with order_status = cancelled';
ALTER TABLE workspace.ecom_poc.gold_daily_sales ALTER COLUMN cancellation_rate COMMENT 'cancelled_orders / orders_count (0 to 1). For several days use SUM(cancelled_orders)/SUM(orders_count)';
ALTER TABLE workspace.ecom_poc.gold_daily_sales ALTER COLUMN revenue COMMENT 'USD revenue per the shared definition, dated by order_date';
ALTER TABLE workspace.ecom_poc.gold_daily_sales ALTER COLUMN paid_transactions COMMENT 'Number of transactions counted in revenue';

COMMENT ON TABLE workspace.ecom_poc.gold_revenue_breakdown IS
  'Grain: one row per order_date x category x country. Key: (order_date, category, country). Revenue per the shared definition.';
ALTER TABLE workspace.ecom_poc.gold_revenue_breakdown ALTER COLUMN order_date COMMENT 'Date the order was placed';
ALTER TABLE workspace.ecom_poc.gold_revenue_breakdown ALTER COLUMN category COMMENT 'Product category (lowercase, cleaned)';
ALTER TABLE workspace.ecom_poc.gold_revenue_breakdown ALTER COLUMN country COMMENT 'ISO-style country code of the order (uppercase, cleaned)';
ALTER TABLE workspace.ecom_poc.gold_revenue_breakdown ALTER COLUMN revenue COMMENT 'USD revenue per the shared definition';
ALTER TABLE workspace.ecom_poc.gold_revenue_breakdown ALTER COLUMN paid_transactions COMMENT 'Transactions counted in revenue';
ALTER TABLE workspace.ecom_poc.gold_revenue_breakdown ALTER COLUMN paid_orders COMMENT 'Distinct orders with at least one counted transaction';

COMMENT ON TABLE workspace.ecom_poc.gold_payment_success IS
  'Grain: one row per order_date x payment_method. Key: (order_date, payment_method). Counts ALL accepted transactions of any status and currency; measures payment performance, not revenue.';
ALTER TABLE workspace.ecom_poc.gold_payment_success ALTER COLUMN order_date COMMENT 'Date of the order the transaction belongs to';
ALTER TABLE workspace.ecom_poc.gold_payment_success ALTER COLUMN payment_method COMMENT 'Payment method (lowercase, cleaned)';
ALTER TABLE workspace.ecom_poc.gold_payment_success ALTER COLUMN total_txns COMMENT 'All accepted transactions';
ALTER TABLE workspace.ecom_poc.gold_payment_success ALTER COLUMN success_txns COMMENT 'Transactions with txn_status = success';
ALTER TABLE workspace.ecom_poc.gold_payment_success ALTER COLUMN failed_txns COMMENT 'Transactions with txn_status = failed';
ALTER TABLE workspace.ecom_poc.gold_payment_success ALTER COLUMN pending_txns COMMENT 'Transactions with txn_status = pending';
ALTER TABLE workspace.ecom_poc.gold_payment_success ALTER COLUMN refunded_txns COMMENT 'Transactions with txn_status = refunded';
ALTER TABLE workspace.ecom_poc.gold_payment_success ALTER COLUMN success_rate COMMENT 'success_txns / total_txns (0 to 1). For several rows use SUM(success_txns)/SUM(total_txns)';

COMMENT ON TABLE workspace.ecom_poc.gold_top_customers IS
  'Grain: one row per customer, limited to the top 1,000 by revenue. Key: customer_id. Revenue per the shared definition. NOT a complete customer list.';
ALTER TABLE workspace.ecom_poc.gold_top_customers ALTER COLUMN spend_rank COMMENT '1 = highest revenue; ties broken by customer_id';
ALTER TABLE workspace.ecom_poc.gold_top_customers ALTER COLUMN customer_id COMMENT 'Synthetic customer identifier (key)';
ALTER TABLE workspace.ecom_poc.gold_top_customers ALTER COLUMN total_revenue COMMENT 'USD revenue per the shared definition, all dates';
ALTER TABLE workspace.ecom_poc.gold_top_customers ALTER COLUMN paid_orders COMMENT 'Distinct orders with counted revenue';
ALTER TABLE workspace.ecom_poc.gold_top_customers ALTER COLUMN paid_transactions COMMENT 'Transactions counted in revenue';
ALTER TABLE workspace.ecom_poc.gold_top_customers ALTER COLUMN first_order_date COMMENT 'Earliest order date with counted revenue';
ALTER TABLE workspace.ecom_poc.gold_top_customers ALTER COLUMN last_order_date COMMENT 'Latest order date with counted revenue';

-- =====================================================================
-- 6. CHECKS (evidence)
-- =====================================================================
-- 6a. Row counts of every Gold output
SELECT 'gold_daily_sales' AS gold_table, COUNT(*) AS row_count FROM workspace.ecom_poc.gold_daily_sales
UNION ALL SELECT 'gold_revenue_breakdown', COUNT(*) FROM workspace.ecom_poc.gold_revenue_breakdown
UNION ALL SELECT 'gold_payment_success',   COUNT(*) FROM workspace.ecom_poc.gold_payment_success
UNION ALL SELECT 'gold_top_customers',     COUNT(*) FROM workspace.ecom_poc.gold_top_customers;

-- 6b. Unique keys: duplicate_keys must be 0 for every table
SELECT 'gold_daily_sales' AS gold_table,
       COUNT(*) - COUNT(DISTINCT order_date) AS duplicate_keys
FROM workspace.ecom_poc.gold_daily_sales
UNION ALL
SELECT 'gold_revenue_breakdown', COUNT(*) - COUNT(DISTINCT concat_ws('|', order_date, category, country))
FROM workspace.ecom_poc.gold_revenue_breakdown
UNION ALL
SELECT 'gold_payment_success', COUNT(*) - COUNT(DISTINCT concat_ws('|', order_date, payment_method))
FROM workspace.ecom_poc.gold_payment_success
UNION ALL
SELECT 'gold_top_customers', COUNT(*) - COUNT(DISTINCT customer_id)
FROM workspace.ecom_poc.gold_top_customers;

-- 6c. Total revenue must be IDENTICAL from every route (the three numbers + the independent check)
--     independent_no_join computes revenue WITHOUT joining (IN-subquery), to prove there is no fan-out.
SELECT
  (SELECT SUM(amount)  FROM workspace.ecom_poc.vw_revenue_base)                    AS from_revenue_base,
  (SELECT SUM(revenue) FROM workspace.ecom_poc.gold_daily_sales)                   AS from_gold_daily_sales,
  (SELECT SUM(revenue) FROM workspace.ecom_poc.gold_revenue_breakdown)             AS from_gold_revenue_breakdown,
  (SELECT SUM(amount)  FROM workspace.ecom_poc.silver_transactions
     WHERE txn_status = 'success' AND currency = 'USD'
       AND order_id IN (SELECT order_id FROM workspace.ecom_poc.silver_orders
                        WHERE order_status NOT IN ('cancelled','refunded')))        AS independent_no_join;

-- 6d. No fan-out: rows in the revenue base = distinct transactions (difference must be 0)
SELECT COUNT(*) - COUNT(DISTINCT txn_id) AS duplicated_transactions_in_base
FROM workspace.ecom_poc.vw_revenue_base;

-- 6e. Sample output from each Gold table
SELECT * FROM workspace.ecom_poc.gold_daily_sales        ORDER BY order_date DESC LIMIT 10;
SELECT * FROM workspace.ecom_poc.gold_revenue_breakdown  ORDER BY revenue DESC    LIMIT 10;
SELECT * FROM workspace.ecom_poc.gold_payment_success    ORDER BY order_date DESC, payment_method LIMIT 10;
SELECT * FROM workspace.ecom_poc.gold_top_customers      ORDER BY spend_rank      LIMIT 10;

-- 6f. Small worked example for the README: one order and which of its transactions count
SELECT o.order_id, o.order_status, t.txn_id, t.txn_status, t.currency, t.amount,
       CASE WHEN t.txn_status = 'success' AND t.currency = 'USD'
             AND o.order_status NOT IN ('cancelled','refunded') THEN 'COUNTED' ELSE 'not counted' END AS in_revenue
FROM workspace.ecom_poc.silver_orders o
JOIN workspace.ecom_poc.silver_transactions t ON t.order_id = o.order_id
WHERE o.order_id IN (SELECT order_id FROM workspace.ecom_poc.silver_transactions
                     GROUP BY order_id HAVING COUNT(*) > 1 LIMIT 3)
ORDER BY o.order_id, t.txn_id;