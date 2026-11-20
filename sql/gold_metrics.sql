-- sql/gold_metrics.sql  -  Gold metric definitions (used by SQL, the AI/BI dashboard and Power BI)
--
-- REVENUE = SUM(silver_transactions.amount)
--           WHERE txn_status = 'success' AND currency = 'USD'
--             AND the order's order_status NOT IN ('cancelled','refunded')
--   * no FX conversion: EUR and GBP are excluded
--   * partial and repeat payments: each successful transaction counts once
--   * source of truth: silver_transactions, joined many-to-one to silver_orders (no fan-out)
--   * dated by order_date
--   * the definition lives in ONE place: view vw_revenue_base (created in notebooks/05_gold.sql)
--
-- CANCELLATION RATE  = SUM(cancelled_orders) / SUM(orders_count)       (never average daily rates)
-- PAYMENT SUCCESS RATE = SUM(success_txns) / SUM(total_txns)           (all statuses and currencies)
-- Grain: daily_sales = order_date | revenue_breakdown = order_date x category x country
--        payment_success = order_date x payment_method | top_customers = customer_id (top 1,000)

SELECT SUM(revenue) AS total_revenue         FROM workspace.ecom_poc.gold_daily_sales;
SELECT SUM(cancelled_orders) / SUM(orders_count) AS cancellation_rate FROM workspace.ecom_poc.gold_daily_sales;
SELECT SUM(success_txns) / SUM(total_txns) AS payment_success_rate   FROM workspace.ecom_poc.gold_payment_success;

-- Worked example: which transactions of an order count towards revenue
SELECT o.order_id, o.order_status, t.txn_id, t.txn_status, t.currency, t.amount,
       CASE WHEN t.txn_status = 'success' AND t.currency = 'USD'
             AND o.order_status NOT IN ('cancelled','refunded') THEN 'COUNTED' ELSE 'not counted' END AS in_revenue
FROM workspace.ecom_poc.silver_orders o
JOIN workspace.ecom_poc.silver_transactions t ON t.order_id = o.order_id
WHERE o.order_id IN (SELECT order_id FROM workspace.ecom_poc.silver_transactions
                     GROUP BY order_id HAVING COUNT(*) > 1 LIMIT 3)
ORDER BY o.order_id, t.txn_id;