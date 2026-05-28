"""Try NULL-key join with sort-based columnar shuffle (instead of hash) — see if bug is hash-shuffle-specific."""
from pyspark.sql import SparkSession

spark = SparkSession.builder \
    .appName("join-sort-shuffle") \
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
    .config("spark.sql.autoBroadcastJoinThreshold", "-1") \
    .config("spark.sql.shuffle.partitions", "8") \
    .config("spark.gluten.sql.columnar.shuffle.sort.partitions.threshold", "4") \
    .getOrCreate()

print(f"=== Spark {spark.version} (sort-based columnar shuffle) ===")

spark.sql("""
    SELECT * FROM VALUES
      (1, 'alice'), (2, 'bob'), (3, 'carol'),
      (CAST(NULL AS INT), 'ghost-left')
    AS t(id, name)
""").createOrReplaceTempView("L")
spark.sql("""
    SELECT * FROM VALUES
      (1, 90), (2, 85), (3, 70),
      (CAST(NULL AS INT), 99)
    AS t(id, score)
""").createOrReplaceTempView("R")

print("\n[A] LEFT JOIN with NULL keys (the previously broken case)")
spark.sql("SELECT L.id, name, score FROM L LEFT JOIN R ON L.id = R.id ORDER BY L.id NULLS FIRST").show()

print("=== Done ===")
spark.stop()
