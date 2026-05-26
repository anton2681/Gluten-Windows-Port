"""Sanity test - load Gluten plugin but disable offload, run with vanilla Spark."""
from pyspark.sql import SparkSession

spark = SparkSession.builder \
    .appName("gluten-sanity") \
    .master("local[2]") \
    .config("spark.plugins", "org.apache.gluten.GlutenPlugin") \
    .config("spark.gluten.enabled", "false") \
    .config("spark.memory.offHeap.enabled", "true") \
    .config("spark.memory.offHeap.size", "1g") \
    .config("spark.sql.adaptive.enabled", "false") \
    .getOrCreate()

print(f"=== Spark {spark.version}, gluten.enabled=false ===")
n = spark.range(0, 100).count()
print(f"=== Count: {n} (expected 100) ===")
spark.stop()
print("=== Sanity OK ===")
