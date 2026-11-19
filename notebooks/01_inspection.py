for f in ["orders.csv", "transactions.csv"]:
    p = f"/Volumes/workspace/ecom_poc/raw_files/{f}"
    n = spark.read.text(p).count() - 1   # lines minus header
    size = dbutils.fs.ls(p)[0].size
    print(f, f"{n:,} data rows", f"{size:,} bytes")