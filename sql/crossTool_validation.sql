-- sql/cross_tool_validation.sql  -  compare Databricks SQL, the AI/BI dashboard and Power BI.
-- Use the SAME date range, currency (USD as defined) and filters in all three tools.

-- A. Total revenue, full period, no filters
SELECT SUM(revenue) AS total_revenue FROM workspace.ecom_poc.gold_daily_sales;

-- B. Independent check without the revenue view or any join. Must equal A.
SELECT SUM(amount) AS independent_total_revenue
FROM workspace.ecom_poc.silver_transactions
WHERE txn_status = 'success' AND currency = 'USD'
  AND order_id IN (SELECT order_id FROM workspace.ecom_poc.silver_orders
                   WHERE order_status NOT IN ('cancelled','refunded'));

-- C. Same total from the breakdown table. Must equal A.
SELECT SUM(revenue) AS breakdown_total FROM workspace.ecom_poc.gold_revenue_breakdown;

-- D. One month for a second comparison (hover over January 2025 in the trend chart)
SELECT SUM(revenue) AS jan_2025_revenue
FROM workspace.ecom_poc.gold_daily_sales
WHERE order_date BETWEEN '2025-01-01' AND '2025-01-31';

-- E. Revenue by category (compare with the category chart in the dashboard and Power BI)
SELECT category, SUM(revenue) AS revenue
FROM workspace.ecom_poc.gold_revenue_breakdown GROUP BY category ORDER BY revenue DESC;

-- RESULT TABLE (fill in from your tools; all rows must match to the cent)
-- source              date range             filters   total revenue
-- Databricks SQL      all                    none      <value from A>
-- AI/BI dashboard     2025-01-01..2026-12-31 none      <value>
-- Power BI            2025-01-01..2026-12-31 none      <value>
-- Diagnose a mismatch: date slicer cutting days, a leftover country/category filter,
-- abbreviated card units (66.56M), stale Power BI data (refresh), or a different source table.