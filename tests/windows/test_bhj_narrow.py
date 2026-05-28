"""Verify whether BHJ returns correct results (no NULL keys to isolate from Bug #3)."""
from pyspark.sql import SparkSession

spark = SparkSession.builder \
    .appName("bhj-narrow") \
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
    .config("spark.sql.autoBroadcastJoinThreshold", "10485760") \
    .config("spark.gluten.velox.buildHashTableOncePerExecutor.enabled", "false") \
    .getOrCreate()

print(f"=== Spark {spark.version} ===")

spark.sql("SELECT * FROM VALUES (1, 'alice'), (2, 'bob'), (3, 'carol'), (4, 'dave') AS t(id, name)").createOrReplaceTempView("L")
spark.sql("SELECT * FROM VALUES (1, 90), (2, 85), (3, 70) AS t(id, score)").createOrReplaceTempView("R")

print("\n[BHJ-1] Inner BHJ (small R broadcast)")
spark.sql("SELECT /*+ BROADCAST(R) */ L.id, name, score FROM L JOIN R ON L.id = R.id ORDER BY L.id").show()

print("[BHJ-2] Plan should mention VeloxBroadcast / *Transformer")
spark.sql("SELECT /*+ BROADCAST(R) */ L.id, name, score FROM L JOIN R ON L.id = R.id").explain()

print("=== Done ===")
spark.stop()
