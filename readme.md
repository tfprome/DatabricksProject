# E-commerce Lakehouse on Databricks (Bronze → Silver → Gold)
Messy synthetic order and payment CSVs go in; reconciled, documented analytics come out in Databricks AI/BI and Power BI.
**All data is synthetic. No real customers, credentials or raw CSVs are in this repo.**

## 1. Environment

| Item | Value |
|---|---|
| Account | Databricks free trial, own email, verified (not Free Edition) |
| Cloud / region | AWS (from workspace URL) / `<region>` |
| Trial start / expiry | `<start>` / `<expiry>` |
| Governance | Unity Catalog: catalog `workspace` → schema `ecom_poc` → managed volume `raw_files` |
| Raw path | `/Volumes/workspace/ecom_poc/raw_files/` |
| Compute | Serverless starter SQL warehouse (auto-stop) for ETL and BI |

Setup:
```sql
USE CATALOG workspace;
CREATE SCHEMA IF NOT EXISTS ecom_poc;
USE SCHEMA ecom_poc;
CREATE VOLUME IF NOT EXISTS raw_files;
```
Naming: `bronze_*`, `silver_*`, `quarantine_*`, `duplicate_losers_*`, `gold_*`, `stg_*` (staging).

## 2. Architecture

```
generate.py (seed 42) → CSVs → UC volume → Bronze (all STRING + audit cols)
  → Silver (typed, validated, deduplicated) → Gold (4 marts) → AI/BI dashboard + Power BI
Orchestrated by a Lakeflow Job: bronze → silver → gold
```

## 3. Synthetic data (`generator/generate.py`)

Fixed seed (42), exactly **1,000,000 data rows** per file: `orders.csv` (8 columns), `transactions.csv` (7 columns).
Each injected anomaly uses a **disjoint set of rows**, so the counts in `dirty_data_report.csv` are exact. Rates are 0.3–3% so the data stays realistic and metrics stay meaningful.

| Anomaly | Orders | Transactions |
|---|---|---|
| Null/blank | `customer_id` | `txn_id`, `amount` |
| Text in numeric | `quantity`, `unit_price` | `amount` |
| Negative / out of range | `quantity`, `unit_price` | `amount` |
| Bad / future timestamp | `order_date` | `txn_ts` |
| Case / whitespace | status, category, country | method, status, currency |
| Invalid labels | `order_status` | `currency`, `txn_status` |
| Exact duplicate rows | 0.5% | 0.5% |
| Same key, different content | 0.5% | 0.5% |
| Orphan references | – | 1% unknown `order_id` |

CSVs are excluded from Git (`.gitignore`): raw extracts may hold PII, are large, and are reproducible from the seeded script. Production controls would add: secrets in a vault, least-privilege access, audit logs, retention rules, and PII masking.

## 4. Bronze (lossless)

* Read with `header=true`, **no schema inference**: every field is STRING, so malformed values survive for audit and quarantine. Rejecting early would lose evidence and break count parity.
* Audit columns: `_ingested_at` (load time), `_source_file` (lineage), `_batch_id` (load run), `_row_hash` (SHA-256 of source fields; equal for exact duplicates), `_row_id` (batch + hash + occurrence number; unique per row, used to trace rows through every outcome).
* **Idempotent**: each run deletes its `_batch_id`, then inserts it again, so re-runs do not double the data.
* **Result:** source rows = Bronze rows = 1,000,000 for both tables (independent line count vs table count); a second run left counts unchanged.

## 5. Silver (typed, validated, reconciled)

**Precedence** (each Bronze row lands in exactly one bucket): `try_cast` text safely (unparseable → NULL) → validate rules (failures → quarantine) → deduplicate **valid** rows only (losers → duplicate losers) → remainder is accepted. Transactions are validated after `silver_orders` exists (orphan check).

| Dataset | Rules |
|---|---|
| orders | ids not blank; `order_date` parseable and not future; `quantity` int 1–100; `unit_price` > 0 and ≤ 10,000; status in {completed, shipped, pending, cancelled, refunded}; category and country in allowed lists |
| transactions | `txn_id`, `order_id` not blank; `order_id` exists in accepted `silver_orders`; `amount` > 0 and ≤ 50,000; currency in {USD, EUR, GBP}; method and status in allowed lists; `txn_ts` parseable and not future |

Case and whitespace are cleaned (`trim`, `lower`/`upper`), not rejected. Rejections keep the **original raw text** plus `rejection_reason` (several reasons joined by `;`).

**Keep-one rule:** latest date (`order_date` / `txn_ts`), then latest `_ingested_at`, then smallest `_row_id` (fully deterministic). `duplicate_type` separates `exact_duplicate_row` (same `_row_hash`) from `same_key_different_content`.

**Reconciliation: Bronze = accepted + quarantined + duplicate losers**

| Dataset | Bronze | Accepted | Quarantined | Dup. losers |
|---|---|---|---|---|
| orders | 1,000,000 | 958,000 | 32,000 | 10,000 |
| transactions | 1,000,000 | 918,288 | 72,048 | 9,664 |

Checks all passed: no overlap between outcome tables (joined on `_row_id`), no Bronze row without an outcome, unique keys in Silver, and no accepted transaction without an order.
Transaction quarantine is above the injected 41,000 because transactions of quarantined orders become orphans.

## 6. Gold

**Revenue definition (single source: view `vw_revenue_base`):**
`SUM(amount)` from `silver_transactions` where `txn_status='success'`, `currency='USD'` (no FX; EUR/GBP excluded), joined many-to-one to `silver_orders` where status is not `cancelled`/`refunded`. Each successful transaction counts once (partial and repeat payments included). Revenue is dated by **order date**.
Example: order with payments 40 USD success + 40 USD success + 10 EUR success + 20 USD failed → revenue 80.

| Table | Grain / key | Measures |
|---|---|---|
| `gold_daily_sales` | `order_date` | orders, cancelled, cancellation rate, revenue |
| `gold_revenue_breakdown` | `order_date × category × country` | revenue, paid orders |
| `gold_payment_success` | `order_date × payment_method` | total/success/failed/pending/refunded, success rate |
| `gold_top_customers` | `customer_id` (top 1,000) | revenue, rank |

No fan-out: orders and revenue are aggregated to one row per day **before** joining; verified by a join-free revenue query. Table and column comments in Unity Catalog state grain, key and metric rules (e.g. rates over many rows use `SUM/SUM`, never an average of daily rates), so reports are not misread.

## 7. BI

* **AI/BI dashboard** (built with Genie assistance, then checked): KPI counters, monthly revenue and orders trends, revenue by category and country, shared date filter. Link: `<dashboard link>`
* **Power BI Desktop:** native Databricks connector, **Import** mode (Gold tables only). Calendar table related to the three dated tables; measures: Total Revenue, Total Orders, Cancelled Orders, Cancellation Rate, Payment Success Rate (same definitions as the dashboard). Import vs DirectQuery: Import copies the small Gold tables into the file (fast, warehouse used only on refresh, saves credits); DirectQuery queries Databricks on every interaction (always fresh, slower, consumes credits).
* The country slicer only affects visuals built on `gold_revenue_breakdown`; `gold_top_customers` has no date.

**Revenue reconciliation** (full period, no filters):

| Source | Total revenue |
|---|---|
| Databricks SQL | `<value>` |
| AI/BI dashboard | `<value>` |
| Power BI | `<value>` |

## 8. Genie

`<Genie Agent over Gold tables: 3 questions, answers and verification SQL, OR documented restriction with these prompts>`

| Prompt | Verification SQL |
|---|---|
| Category with the highest revenue? | `SELECT category, SUM(revenue) r FROM workspace.ecom_poc.gold_revenue_breakdown GROUP BY category ORDER BY r DESC LIMIT 1` |
| Overall cancellation rate? | `SELECT SUM(cancelled_orders)/SUM(orders_count) FROM workspace.ecom_poc.gold_daily_sales` |
| Payment method with the best success rate? | `SELECT payment_method, SUM(success_txns)/SUM(total_txns) r FROM workspace.ecom_poc.gold_payment_success GROUP BY payment_method ORDER BY r DESC LIMIT 1` |

## 9. Job, security, cleanup

* **Lakeflow Job** `bronze → silver → gold`, each task depends on the previous one with 1 retry and failure email; no schedule. By default a task runs only if all dependencies succeeded, so Gold is skipped when Silver fails and bad data never reaches reporting. An early run failed at Bronze (empty saved query) and was fixed by switching to a SQL file task: `<successful run reference>`.
* **Least privilege** (`sql/grants.sql`): `USE CATALOG`, `USE SCHEMA` and `SELECT` on the four Gold tables only, nothing on Bronze/Silver/quarantine. Test: query as a `report_users` member; Gold works, Bronze/Silver return permission errors. Status: `<applied / plan only, with reason>`
* **Cleanup:** stop the SQL warehouse, no schedules, check remaining credits, revoke the Power BI token, export notebooks and dashboard, push to Git.

## 10. Limitations and fallbacks

* Batch id `2026-11-18_001` is written in the Bronze/Silver SQL (not passed as a job parameter).
* Silver is rebuilt from one batch per run (`CREATE OR REPLACE`).
* EUR/GBP transactions are excluded from revenue (no FX data).
* `gold_top_customers` holds only the top 1,000 customers.
* Gold task type differs from Bronze/Silver in the job (`<note>`).
* `<any other trial restriction, e.g. sharing, Genie, user creation>`

## 11. Repository layout

```
README.md  generator/  notebooks/  sql/  dashboards/  powerbi/  evidence/  operations/  .gitignore
```
