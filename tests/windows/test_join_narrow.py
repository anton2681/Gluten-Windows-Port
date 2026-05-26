"""Narrow down: is the crash from LEFT JOIN type or from NULL keys?"""
from pyspark.sql import SparkSession

spark = SparkSession.builder \
    .appName("join-narrow") \
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

print(f"=== Spark {spark.version} ===")

# Tables WITHOUT NULL keys
spark.sql("SELECT * FROM VALUES (1, 'alice'), (2, 'bob'), (3, 'carol') AS t(id, name)").createOrReplaceTempView("L")
spark.sql("SELECT * FROM VALUES (1, 90), (2, 85), (5, 60) AS t(id, score)").createOrReplaceTempView("R")

print("\n[A] Inner join, no nulls")
spark.sql("SELECT L.id, name, score FROM L JOIN R ON L.id = R.id ORDER BY L.id").show()

print("[B] LEFT JOIN, no nulls (should show id=3 with NULL score)")
spark.sql("SELECT L.id, name, score FROM L LEFT JOIN R ON L.id = R.id ORDER BY L.id").show()

print("[C] RIGHT JOIN, no nulls (should show id=5 with NULL name)")
spark.sql("SELECT R.id, name, score FROM L RIGHT JOIN R ON L.id = R.id ORDER BY R.id").show()

print("=== Done ===")
spark.stop()
