"""NULL-key LEFT JOIN with velox spill DISABLED — does the OOM in ensureInputFits go away?"""
from pyspark.sql import SparkSession

spark = SparkSession.builder \
    .appName("join-no-spill") \
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
    .config("spark.gluten.sql.columnar.backend.velox.spillStrategy", "none") \
    .getOrCreate()

print(f"=== Spark {spark.version} (no velox spill) ===")

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

print("\n[A] LEFT JOIN with NULL keys")
spark.sql("SELECT L.id, name, score FROM L LEFT JOIN R ON L.id = R.id ORDER BY L.id NULLS FIRST").show()

print("=== Done ===")
spark.stop()
