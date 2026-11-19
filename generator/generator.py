"""
Synthetic e-commerce data generator (SYNTHETIC DATA ONLY, no real customers).

Creates:
  orders.csv        1,000,000 data rows + header
  transactions.csv  1,000,000 data rows + header
  dirty_data_report.csv   (file, anomaly_type, field, count, percent_of_rows)

Fully reproducible: fixed seed, fixed date range, no dependency on today's date.
Every injected anomaly is drawn from a DISJOINT pool of rows, so the counts in the
report are exact (no row carries two injected problems).

Usage
-----
Local:        python generate.py --out-dir ./output
Databricks:   %run or paste into a notebook, then
              python generate.py --out-dir /Volumes/ws/ecom_poc/raw_files
              (in a notebook just call main(out_dir="/Volumes/ws/ecom_poc/raw_files"))

Requires: numpy, pandas
"""
import argparse
import os
from pathlib import Path

import numpy as np
import pandas as pd

SEED = 42
N_ROWS = 1_000_000

CATEGORIES = ["electronics", "fashion", "home", "beauty", "sports", "books", "toys", "grocery"]
CAT_P = [0.18, 0.22, 0.15, 0.10, 0.10, 0.08, 0.07, 0.10]
ORDER_STATUSES = ["completed", "shipped", "pending", "cancelled", "refunded"]
ORDER_STATUS_P = [0.62, 0.20, 0.06, 0.08, 0.04]
COUNTRIES = ["US", "GB", "DE", "FR", "CA", "AU", "BD", "IN"]
COUNTRY_P = [0.30, 0.12, 0.10, 0.08, 0.08, 0.06, 0.12, 0.14]
PAY_METHODS = ["card", "paypal", "bank_transfer", "wallet", "cash_on_delivery"]
PAY_P = [0.50, 0.20, 0.12, 0.12, 0.06]
TXN_STATUSES = ["success", "failed", "pending", "refunded"]
TXN_STATUS_P = [0.85, 0.08, 0.04, 0.03]
CURRENCIES = ["USD", "EUR", "GBP"]
CURRENCY_P = [0.90, 0.06, 0.04]

DATE_START = np.datetime64("2025-01-01")
DATE_DAYS = 669  # through 2026-10-31

# Injection rates, as a fraction of the final row count (N_ROWS)
ORDER_RATES = {
    "null_blank_customer_id": 0.005,
    "text_in_quantity": 0.005,
    "text_in_unit_price": 0.005,
    "negative_or_out_of_range_quantity": 0.004,
    "negative_or_out_of_range_unit_price": 0.004,
    "invalid_or_future_order_date": 0.006,
    "case_whitespace_order_status": 0.030,
    "case_whitespace_category": 0.020,
    "case_whitespace_country": 0.010,
    "invalid_order_status": 0.003,
    "exact_duplicate_rows": 0.005,
    "duplicate_key_different_content": 0.005,
}
TXN_RATES = {
    "null_blank_txn_id": 0.003,
    "null_blank_amount": 0.005,
    "text_in_amount": 0.005,
    "negative_or_out_of_range_amount": 0.004,
    "invalid_or_future_txn_ts": 0.006,
    "case_whitespace_payment_method": 0.030,
    "case_whitespace_txn_status": 0.030,
    "case_whitespace_currency": 0.010,
    "unsupported_currency": 0.005,
    "invalid_txn_status": 0.003,
    "orphan_order_id": 0.010,
    "exact_duplicate_rows": 0.005,
    "duplicate_key_different_content": 0.005,
}


class Pool:
    """Hands out disjoint random row positions so injected anomalies never overlap."""

    def __init__(self, n, rng):
        self.perm = rng.permutation(n)
        self.pos = 0

    def take(self, k):
        s = self.perm[self.pos:self.pos + k]
        self.pos += k
        return s

    def rest(self):
        return self.perm[self.pos:]


def messy_case(values, rng):
    """Return inconsistent-case / whitespace variants of clean lowercase strings."""
    out = []
    for v, k in zip(values, rng.integers(0, 4, len(values))):
        out.append((v.upper(), " " + v + " ", v.capitalize(), v + "  ")[k])
    return out


def pad_id(prefix, nums, width):
    return np.char.add(prefix, np.char.zfill(nums.astype(str), width))


def cnt(rates, key, total=N_ROWS):
    return int(round(rates[key] * total))


def log(report, file, kind, field, idx_or_n, total):
    n = idx_or_n if isinstance(idx_or_n, int) else len(idx_or_n)
    report.append({"file": file, "anomaly_type": kind, "field": field,
                   "count": n, "percent_of_rows": round(100.0 * n / total, 3)})


# --------------------------------------------------------------------------- orders
def make_orders(rng, total, report):
    n_exact = cnt(ORDER_RATES, "exact_duplicate_rows", total)
    n_key = cnt(ORDER_RATES, "duplicate_key_different_content", total)
    n = total - n_exact - n_key  # unique base rows

    order_num = np.arange(1, n + 1)
    qty = rng.choice([1, 2, 3, 4, 5], n, p=[0.55, 0.25, 0.10, 0.06, 0.04])
    price = np.clip(np.round(rng.lognormal(3.8, 0.8, n), 2), 2.0, 1500.0)
    dates = DATE_START + rng.integers(0, DATE_DAYS, n).astype("timedelta64[D]")

    df = pd.DataFrame({
        "order_id": pad_id("ORD", order_num, 8),
        "customer_id": pad_id("CUST", rng.integers(1, 200_001, n), 6),
        "order_date": dates.astype(str),
        "category": rng.choice(CATEGORIES, n, p=CAT_P),
        "quantity": qty.astype(str),
        "unit_price": np.char.mod("%.2f", price),
        "order_status": rng.choice(ORDER_STATUSES, n, p=ORDER_STATUS_P),
        "country": rng.choice(COUNTRIES, n, p=COUNTRY_P),
    }).astype(object)

    clean = {  # kept for transaction generation
        "order_id": df["order_id"].to_numpy().copy(),
        "amount": qty * price,
        "dates": dates,
    }

    pool = Pool(n, rng)
    F = "orders.csv"

    # 1. null / blank
    idx = pool.take(cnt(ORDER_RATES, "null_blank_customer_id", total))
    df.loc[idx, "customer_id"] = np.where(rng.random(len(idx)) < 0.5, "", "   ")
    log(report, F, "null_blank", "customer_id", idx, total)

    # 2. text inside numeric fields
    idx = pool.take(cnt(ORDER_RATES, "text_in_quantity", total))
    df.loc[idx, "quantity"] = rng.choice(["abc", "two", "N/A", "ten"], len(idx))
    log(report, F, "text_in_numeric", "quantity", idx, total)

    idx = pool.take(cnt(ORDER_RATES, "text_in_unit_price", total))
    df.loc[idx, "unit_price"] = rng.choice(["free", "N/A", "ten dollars", "$$"], len(idx))
    log(report, F, "text_in_numeric", "unit_price", idx, total)

    # 3. negative / out-of-range
    idx = pool.take(cnt(ORDER_RATES, "negative_or_out_of_range_quantity", total))
    df.loc[idx, "quantity"] = rng.choice(["-1", "0", "-5", "9999"], len(idx))
    log(report, F, "negative_or_out_of_range", "quantity", idx, total)

    idx = pool.take(cnt(ORDER_RATES, "negative_or_out_of_range_unit_price", total))
    df.loc[idx, "unit_price"] = rng.choice(["-5.00", "0.00", "-120.50", "999999.99"], len(idx))
    log(report, F, "negative_or_out_of_range", "unit_price", idx, total)

    # 4. invalid / future timestamps
    idx = pool.take(cnt(ORDER_RATES, "invalid_or_future_order_date", total))
    df.loc[idx, "order_date"] = rng.choice(
        ["not-a-date", "2031-01-01", "2026-13-45", "2099-12-31", "00/00/0000"], len(idx))
    log(report, F, "invalid_or_future_timestamp", "order_date", idx, total)

    # 5. inconsistent case / whitespace
    for key, col in (("case_whitespace_order_status", "order_status"),
                     ("case_whitespace_category", "category"),
                     ("case_whitespace_country", "country")):
        idx = pool.take(cnt(ORDER_RATES, key, total))
        vals = df.loc[idx, col].tolist()
        if col == "country":  # country is upper-case by convention, so make lowercase/padded
            df.loc[idx, col] = [(v.lower(), " " + v + " ", v.lower() + " ")[k]
                                for v, k in zip(vals, rng.integers(0, 3, len(vals)))]
        else:
            df.loc[idx, col] = messy_case(vals, rng)
        log(report, F, "inconsistent_case_whitespace", col, idx, total)

    # 6. invalid category value for a status field
    idx = pool.take(cnt(ORDER_RATES, "invalid_order_status", total))
    df.loc[idx, "order_status"] = rng.choice(["unknown", "in_transit_??", "N/A"], len(idx))
    log(report, F, "invalid_label", "order_status", idx, total)

    # 7. duplicates, sourced from rows that are still clean
    rest = pool.rest()
    exact_src, key_src = rest[:n_exact], rest[n_exact:n_exact + n_key]
    exact_dups = df.loc[exact_src].copy()
    key_dups = df.loc[key_src].copy()
    key_dups["quantity"] = [str(int(q) + 1) for q in key_dups["quantity"]]
    key_dups["unit_price"] = [f"{float(p) * 1.1:.2f}" for p in key_dups["unit_price"]]
    log(report, F, "exact_duplicate_row", "all columns", n_exact, total)
    log(report, F, "duplicate_key_different_content", "order_id", n_key, total)

    out = pd.concat([df, exact_dups, key_dups], ignore_index=True)
    out = out.iloc[rng.permutation(len(out))].reset_index(drop=True)
    assert len(out) == total
    return out, clean


# ------------------------------------------------------------------------ transactions
def make_transactions(rng, total, clean, report):
    n_exact = cnt(TXN_RATES, "exact_duplicate_rows", total)
    n_key = cnt(TXN_RATES, "duplicate_key_different_content", total)
    n = total - n_exact - n_key

    m = len(clean["order_id"])
    first = rng.permutation(m)[:min(n, int(m * 0.9))]          # ~90% of orders paid once
    extra = rng.integers(0, m, n - len(first))                  # repeat / partial payments
    oidx = rng.permutation(np.concatenate([first, extra]))

    factor = np.where(rng.random(n) < 0.95, 1.0, rng.uniform(0.2, 0.8, n))  # 5% partial
    amount = np.round(clean["amount"][oidx] * factor, 2)
    secs = rng.integers(0, 2 * 86400, n).astype("timedelta64[s]")
    ts = clean["dates"][oidx].astype("datetime64[s]") + secs

    df = pd.DataFrame({
        "txn_id": pad_id("TXN", np.arange(1, n + 1), 9),
        "order_id": clean["order_id"][oidx],
        "payment_method": rng.choice(PAY_METHODS, n, p=PAY_P),
        "amount": np.char.mod("%.2f", amount),
        "currency": rng.choice(CURRENCIES, n, p=CURRENCY_P),
        "txn_status": rng.choice(TXN_STATUSES, n, p=TXN_STATUS_P),
        "txn_ts": np.char.replace(ts.astype(str), "T", " "),
    }).astype(object)

    pool = Pool(n, rng)
    F = "transactions.csv"

    idx = pool.take(cnt(TXN_RATES, "null_blank_txn_id", total))
    df.loc[idx, "txn_id"] = ""
    log(report, F, "null_blank", "txn_id", idx, total)

    idx = pool.take(cnt(TXN_RATES, "null_blank_amount", total))
    df.loc[idx, "amount"] = np.where(rng.random(len(idx)) < 0.5, "", "  ")
    log(report, F, "null_blank", "amount", idx, total)

    idx = pool.take(cnt(TXN_RATES, "text_in_amount", total))
    df.loc[idx, "amount"] = rng.choice(["abc", "N/A", "fifty", "USD10"], len(idx))
    log(report, F, "text_in_numeric", "amount", idx, total)

    idx = pool.take(cnt(TXN_RATES, "negative_or_out_of_range_amount", total))
    df.loc[idx, "amount"] = rng.choice(["-10.00", "0.00", "-250.75", "99999999.00"], len(idx))
    log(report, F, "negative_or_out_of_range", "amount", idx, total)

    idx = pool.take(cnt(TXN_RATES, "invalid_or_future_txn_ts", total))
    df.loc[idx, "txn_ts"] = rng.choice(
        ["not-a-timestamp", "2031-01-01 10:00:00", "2026-02-30 25:61:00", "2099-12-31 23:59:59"],
        len(idx))
    log(report, F, "invalid_or_future_timestamp", "txn_ts", idx, total)

    for key, col in (("case_whitespace_payment_method", "payment_method"),
                     ("case_whitespace_txn_status", "txn_status")):
        idx = pool.take(cnt(TXN_RATES, key, total))
        df.loc[idx, col] = messy_case(df.loc[idx, col].tolist(), rng)
        log(report, F, "inconsistent_case_whitespace", col, idx, total)

    idx = pool.take(cnt(TXN_RATES, "case_whitespace_currency", total))
    vals = df.loc[idx, "currency"].tolist()
    df.loc[idx, "currency"] = [(v.lower(), " " + v + " ", v.lower() + " ")[k]
                               for v, k in zip(vals, rng.integers(0, 3, len(vals)))]
    log(report, F, "inconsistent_case_whitespace", "currency", idx, total)

    idx = pool.take(cnt(TXN_RATES, "unsupported_currency", total))
    df.loc[idx, "currency"] = rng.choice(["XXX", "BDT", "JPY", "???"], len(idx))
    log(report, F, "invalid_label", "currency", idx, total)

    idx = pool.take(cnt(TXN_RATES, "invalid_txn_status", total))
    df.loc[idx, "txn_status"] = rng.choice(["unknown", "error_??", "N/A"], len(idx))
    log(report, F, "invalid_label", "txn_status", idx, total)

    # orphan order ids: numbers >= 90,000,000 can never exist in orders (max ~1,000,000)
    idx = pool.take(cnt(TXN_RATES, "orphan_order_id", total))
    df.loc[idx, "order_id"] = pad_id("ORD", rng.integers(90_000_000, 99_999_999, len(idx)), 8)
    log(report, F, "orphan_reference", "order_id", idx, total)

    rest = pool.rest()
    exact_src, key_src = rest[:n_exact], rest[n_exact:n_exact + n_key]
    exact_dups = df.loc[exact_src].copy()
    key_dups = df.loc[key_src].copy()
    key_dups["amount"] = [f"{float(a) * 1.15:.2f}" for a in key_dups["amount"]]
    log(report, F, "exact_duplicate_row", "all columns", n_exact, total)
    log(report, F, "duplicate_key_different_content", "txn_id", n_key, total)

    out = pd.concat([df, exact_dups, key_dups], ignore_index=True)
    out = out.iloc[rng.permutation(len(out))].reset_index(drop=True)
    assert len(out) == total
    return out


# ------------------------------------------------------------------------------ main
def main(out_dir="./output", report_dir=None, total=N_ROWS, seed=SEED):
    rng = np.random.default_rng(seed)
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    if report_dir is None:
        try:
            report_dir = Path(__file__).resolve().parent
        except NameError:  # running inside a notebook
            report_dir = Path.cwd()
    report_dir = Path(report_dir)

    report = []
    orders, clean = make_orders(rng, total, report)
    txns = make_transactions(rng, total, clean, report)

    paths = {"orders.csv": orders, "transactions.csv": txns}
    for name, frame in paths.items():
        p = out_dir / name
        frame.to_csv(p, index=False, lineterminator="\n")
        with open(p, "rb") as fh:
            lines = sum(1 for _ in fh) - 1  # minus header
        print(f"{name}: {lines:,} data rows, {os.path.getsize(p):,} bytes -> {p}")

    rep = pd.DataFrame(report)
    rep.to_csv(report_dir / "dirty_data_report.csv", index=False)
    print(f"\nDirty-data report -> {report_dir / 'dirty_data_report.csv'}")
    print(rep.to_string(index=False))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", default="./output")
    ap.add_argument("--report-dir", default=None)
    ap.add_argument("--rows", type=int, default=N_ROWS)
    args, _ = ap.parse_known_args()  # tolerant of notebook kernels
    main(args.out_dir, args.report_dir, args.rows)