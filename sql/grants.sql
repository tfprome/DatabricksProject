-- sql/grants.sql  -  least-privilege reporting access: Gold only.
-- Replace `report_users` with a real group/user. If it does not exist or you cannot create one,
-- keep this file as the documented grant plan.
GRANT USE CATALOG ON CATALOG workspace TO `report_users`;
GRANT USE SCHEMA  ON SCHEMA  workspace.ecom_poc TO `report_users`;
GRANT SELECT ON TABLE workspace.ecom_poc.gold_daily_sales       TO `report_users`;
GRANT SELECT ON TABLE workspace.ecom_poc.gold_revenue_breakdown TO `report_users`;
GRANT SELECT ON TABLE workspace.ecom_poc.gold_payment_success   TO `report_users`;
GRANT SELECT ON TABLE workspace.ecom_poc.gold_top_customers     TO `report_users`;
-- Deliberately NO grants on bronze_*, stg_*, silver_*, quarantine_*, duplicate_losers_*, or the volume.

-- Evidence
SHOW GRANTS ON TABLE workspace.ecom_poc.gold_daily_sales;

-- How to test: sign in as a member of report_users.
--   SELECT * FROM workspace.ecom_poc.gold_daily_sales LIMIT 5;   -- must work
--   SELECT * FROM workspace.ecom_poc.bronze_orders LIMIT 5;      -- must fail with a permission error
--   SELECT * FROM workspace.ecom_poc.silver_orders LIMIT 5;      -- must fail with a permission error