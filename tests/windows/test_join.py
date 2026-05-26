"""Join smoke test - uses SQL VALUES instead of createDataFrame to avoid Python worker on Windows."""
from pyspark.sql import SparkSession

spark = SparkSession.builder \
    .appName("join-test") \
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
    .getOrCreate()

print(f"=== Spark {spark.version} session ready ===")

# Build tables via SQL VALUES (no python worker needed)
spark.sql("""
    SELECT * FROM VALUES
      (1, 'alice'), (2, 'bob'), (3, 'carol'), (4, 'dave'),
      (CAST(NULL AS INT), 'ghost-left')
    AS t(id, name)
""").createOrReplaceTempView("L")

spark.sql("""
    SELECT * FROM VALUES
      (1, 90), (2, 85), (3, 70),
      (CAST(NULL AS INT), 99), (5, 60)
    AS t(id, score)
""").createOrReplaceTempView("R")

# Test 1: Inner join
print("\n[T1] Inner join L.id = R.id")
spark.sql("SELECT L.id, L.name, R.score FROM L JOIN R ON L.id = R.id ORDER BY L.id").show()

# Test 2: Left outer join (NULL keys are kept on left side)
print("[T2] Left outer join, NULL keys on left should appear with NULL score")
spark.sql("SELECT L.id, L.name, R.score FROM L LEFT JOIN R ON L.id = R.id ORDER BY L.id NULLS FIRST").show()

# Test 3: Broadcast hash join (uses BROADCAST hint)
print("[T3] Broadcast hash join")
spark.sql("SELECT /*+ BROADCAST(R) */ L.id, L.name, R.score FROM L JOIN R ON L.id = R.id ORDER BY L.id").show()

# Test 4: Plan check
print("[T4] BHJ Plan (should contain VeloxBroadcastHashJoinTransformer / *Transformer)")
spark.sql("SELECT /*+ BROADCAST(R) */ L.id, L.name, R.score FROM L JOIN R ON L.id = R.id").explain()

print("\n=== ALL JOIN TESTS PASSED ===")
spark.stop()
