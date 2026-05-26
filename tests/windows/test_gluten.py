"""Minimal smoke test - just count rows, no projection."""
from pyspark.sql import SparkSession

spark = SparkSession.builder \
    .appName("gluten-smoke-test") \
    .master("local[2]") \
    .config("spark.plugins", "org.apache.gluten.GlutenPlugin") \
    .config("spark.memory.offHeap.enabled", "true") \
    .config("spark.memory.offHeap.size", "1g") \
    .config("spark.shuffle.manager", "org.apache.spark.shuffle.sort.ColumnarShuffleManager") \
    .config("spark.gluten.sql.columnar.backend.lib", "velox") \
    .config("spark.sql.adaptive.enabled", "false") \
    .config("spark.sql.session.timeZone", "UTC") \
    .config("spark.driver.extraJavaOptions", "-Dio.netty.tryReflectionSetAccessible=true") \
    .config("spark.executor.extraJavaOptions", "-Dio.netty.tryReflectionSetAccessible=true") \
    .getOrCreate()

print(f"=== Spark {spark.version} session created with Gluten plugin ===")
df = spark.range(0, 100).toDF("id").selectExpr("id", "id * 2 AS doubled", "id % 5 AS mod5")
df.createOrReplaceTempView("t")

print("\n=== Plan (look for VeloxColumnar* / RowToVeloxColumnar) ===")
spark.sql("SELECT mod5, SUM(doubled) AS total FROM t GROUP BY mod5 ORDER BY mod5").explain()

print("\n=== Result ===")
result = spark.sql("SELECT mod5, SUM(doubled) AS total FROM t GROUP BY mod5 ORDER BY mod5").collect()
for row in result:
    print(f"  mod5={row['mod5']}, total={row['total']}")

print("\n=== Done ===")
spark.stop()
