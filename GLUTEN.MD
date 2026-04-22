# Deep Dive into Gluten: How Spark Gets Native Execution with Velox

This document provides a comprehensive technical deep dive into Apache Gluten — the plugin that offloads Spark SQL execution to native engines like Meta's Velox. We walk through every layer of the architecture, from how Gluten hooks into Spark, to how queries flow through Substrait IR into Velox pipelines, to how memory, shuffle, and data exchange are handled across the JVM-native boundary.

---

## Table of Contents

1. [Architecture Overview: How Gluten Uses Velox](#1-architecture-overview-how-gluten-uses-velox)
2. [Hooking Into Spark: The Plugin Interface](#2-hooking-into-spark-the-plugin-interface)
3. [Plan Conversion: Spark Physical Plan to Substrait IR](#3-plan-conversion-spark-physical-plan-to-substrait-ir)
4. [Plan Conversion: Substrait IR to Velox Plan](#4-plan-conversion-substrait-ir-to-velox-plan)
5. [Native Execution: How Velox Runs the Plan](#5-native-execution-how-velox-runs-the-plan)
6. [Memory Management: Bridging Spark and Velox](#6-memory-management-bridging-spark-and-velox)
7. [Zero-Copy Data Exchange](#7-zero-copy-data-exchange)
8. [Native Columnar Shuffle](#8-native-columnar-shuffle)
9. [Limitations: What Falls Back to Spark](#9-limitations-what-falls-back-to-spark)
10. [End-to-End: A Spark Job With Gluten](#10-end-to-end-a-spark-job-with-gluten)

---

## 1. Architecture Overview: How Gluten Uses Velox

Gluten is a Spark plugin that offloads SQL query execution from the JVM to native C++ engines. When using the Velox backend, the execution flow is:

```
Spark Physical Plan → Substrait IR → Velox Plan → Native Execution → Columnar Results
```

The system is organized into several layers:

- **JVM Layer**: Spark plans are transformed by Scala "Transformer" classes into Substrait protobuf messages.
- **JNI Bridge**: Protobuf bytes are passed via JNI to the C++ runtime.
- **C++ Layer**: Substrait plans are converted to Velox `PlanNode` trees, then executed by Velox's vectorized engine.
- **Data Flow**: `ColumnarBatch` in Spark maps to Velox `RowVector` via the Arrow C Data Interface.
- **Memory**: Integrated off-heap memory management coordinates Spark's memory accounting with Velox's allocator.
- **Fallback**: Operators and expressions that Velox cannot handle fall back seamlessly to vanilla Spark.

### Key Modules

| Module | Purpose |
|---|---|
| `gluten-core` | Spark plugin entry point, component lifecycle, session extensions |
| `gluten-substrait` | Substrait plan generation, expression conversion, operator transformers |
| `backends-velox` | Velox-specific transformers, backend API implementations |
| `cpp/core` | JNI bridge, memory management, shuffle interfaces |
| `cpp/velox` | Substrait-to-Velox conversion, runtime, shuffle writers/readers |

### Key C++ Files

| File | Purpose |
|---|---|
| `cpp/velox/compute/VeloxBackend.cc` | Backend initialization, connector and cache setup |
| `cpp/velox/compute/VeloxRuntime.cc` | Runtime management per task |
| `cpp/velox/compute/VeloxPlanConverter.cc` | Plan conversion orchestration |
| `cpp/velox/compute/WholeStageResultIterator.cc` | Main iterator driving Velox task execution |
| `cpp/velox/substrait/SubstraitToVeloxPlan.cc` | Converts Substrait relations to Velox operators |
| `cpp/velox/substrait/SubstraitToVeloxExpr.cc` | Converts Substrait expressions to Velox expressions |
| `cpp/velox/shuffle/VeloxHashShuffleWriter.cc` | Hash-based native shuffle |
| `cpp/velox/shuffle/VeloxSortShuffleWriter.cc` | Sort-based native shuffle |
| `cpp/velox/memory/VeloxMemoryManager.h` | Memory pool management bridging Spark and Velox |

---

## 2. Hooking Into Spark: The Plugin Interface

### Spark's Plugin API

Spark provides a `SparkPlugin` interface (since Spark 3.0) that allows external code to hook into both the driver and executors:

```scala
trait SparkPlugin {
  def driverPlugin(): DriverPlugin
  def executorPlugin(): ExecutorPlugin
}
```

Plugins are activated via config:

```
spark.plugins = org.apache.gluten.GlutenPlugin
```

Spark also provides `SparkSessionExtensions` — a callback mechanism that lets plugins inject custom Catalyst rules, strategies, parsers, and columnar rules into the query planning pipeline.

### How Gluten Implements It

#### Entry Point — `GlutenPlugin`

`GlutenPlugin` (`gluten-core/.../GlutenPlugin.scala`) creates two sub-plugins:

```scala
class GlutenPlugin extends SparkPlugin {
  def driverPlugin(): DriverPlugin = new GlutenDriverPlugin()
  def executorPlugin(): ExecutorPlugin = new GlutenExecutorPlugin()
}
```

#### Driver Side — `GlutenDriverPlugin`

On `init()`, the driver plugin does three critical things:

1. **Registers `GlutenSessionExtensions`** into `spark.sql.extensions` — Gluten's hook into Spark SQL query planning.
2. **Discovers all `Component` instances** via `META-INF/gluten-components/` (a custom discovery mechanism). The Velox backend is one such component.
3. **Calls `onDriverStart()`** on each component for initialization.

#### Executor Side — `GlutenExecutorPlugin`

On `init()`, calls `onExecutorStart()` on each component (loads native libraries, initializes the Velox runtime). Also provides task lifecycle hooks: `onTaskStart()`, `onTaskSucceeded()`, `onTaskFailed()`.

### The Critical Hook: `ColumnarRule`

The most important Spark extension point for Gluten is `ColumnarRule`. Spark calls it during physical plan finalization:

```scala
trait ColumnarRule {
  def preColumnarTransitions(plan: SparkPlan): SparkPlan
  def postColumnarTransitions(plan: SparkPlan): SparkPlan
}
```

Gluten injects its `GlutenColumnarRule` via `extensions.injectColumnar()`. This is where the **entire plan transformation** happens.

### Rule Injection Architecture

The flow from plugin init to rule execution:

```
GlutenDriverPlugin.init()
  └─ Registers GlutenSessionExtensions
       └─ GlutenSessionExtensions.apply(extensions)
            ├─ Creates Injector (SparkInjector + GlutenInjector)
            ├─ Sets up enable/disable conditions
            ├─ Each Component.injectRules(injector):
            │     ├─ injector.spark.injectResolutionRule(...)
            │     ├─ injector.spark.injectOptimizerRule(...)
            │     ├─ injector.spark.injectPlannerStrategy(...)
            │     └─ injector.gluten.legacy.injectTransform(...)
            └─ injector.inject() → injects GlutenColumnarRule into Spark
```

The `GlutenInjector` manages the columnar rule pipeline with multiple phases:

| Phase | Purpose | Example Rules |
|---|---|---|
| Pre-transform | Setup | `RemoveTransitions`, `RewriteSubqueryBroadcast` |
| Transform | **Offload operators to native** | `HeuristicTransform` (replaces Spark ops with `GlutenPlan` nodes) |
| Post-transform | Optimize offloaded plan | Cost-based optimizations |
| Fallback | Decide fallback | `ExpandFallbackPolicy` — reverts to Spark if cost too high |
| Post | Cleanup | `RemoveTopmostColumnarToRow` |
| Final | Last pass | Final optimizations |

During the **Transform** phase, `OffloadSingleNode` rules replace Spark physical operators:

```
ShuffledHashJoinExec    → ShuffledHashJoinExecTransformer
BroadcastHashJoinExec   → BroadcastHashJoinExecTransformer
ShuffleExchangeExec     → ColumnarShuffleExchangeExec
HashAggregateExec       → HashAggregateExecTransformer
FilterExec              → FilterExecTransformer
SortExec                → SortExecTransformer
```

Each replacement node extends `GlutenPlan`, which declares its output convention (e.g., Velox columnar) and required child conventions. Since some operators may fall back to vanilla Spark while others run in Velox, Gluten tracks data conventions and automatically inserts `RowToColumnar` / `ColumnarToRow` transitions at boundaries.

---

## 3. Plan Conversion: Spark Physical Plan to Substrait IR

### The Big Picture

The conversion is a **bottom-up recursive traversal**. Each Gluten transformer node has a `doTransform()` method that:

1. Asks its child to transform first (producing a child `RelNode`)
2. Converts its own expressions/logic into Substrait nodes
3. Wraps everything into a new `RelNode` referencing the child
4. Returns a `TransformContext(outputAttributes, root=RelNode)`

At the top, `WholeStageTransformer` collects the final `RelNode` tree, wraps it in a `PlanNode`, and serializes it to protobuf bytes.

### Key Data Structures

**`TransformContext`** — carries the result up the tree:

```scala
case class TransformContext(outputAttributes: Seq[Attribute], root: RelNode)
```

**`SubstraitContext`** — shared mutable state threaded through the conversion:

- **Function registry**: maps function names to unique IDs (`registerFunction()`)
- **Relation IDs**: generates unique IDs per operator (`nextRelId()`)
- **Operator IDs**: tracks Spark operator to Substrait relation mapping
- **Join/Aggregation params**: stores operator-specific metadata

### How Each Operator Converts

**FilterExecTransformerBase** (`BasicPhysicalOperatorTransformer.scala`):

```scala
def doTransform(context: SubstraitContext): TransformContext = {
  val childCtx = child.transform(context)           // recurse into child
  val condExpr = ExpressionConverter
    .replaceWithExpressionTransformer(condition)     // Spark expr → ExpressionTransformer
  val condNode = condExpr.doTransform(context)       // ExpressionTransformer → ExpressionNode
  val filterRel = RelBuilder.makeFilterRel(
    childCtx.root, condNode, context, operatorId)    // build FilterRelNode
  TransformContext(output, filterRel)
}
```

**ProjectExecTransformerBase**: Same pattern — converts each projection expression, calls `RelBuilder.makeProjectRel()`.

**HashAggregateExecTransformer**: Converts grouping expressions, aggregate functions with their mode (Partial/Final/PartialMerge/Complete), and calls `RelBuilder.makeAggregateRel()`.

**HashJoinExecTransformer**: Maps Spark join types to Substrait (`Inner → JOIN_TYPE_INNER`, `LeftOuter → JOIN_TYPE_LEFT`, etc.), handles build/stream side switching, and calls `RelBuilder.makeJoinRel()`.

### Expression Conversion

Expressions go through a two-stage conversion:

**Stage A: Spark Expression → ExpressionTransformer** (`ExpressionConverter.scala`)

`replaceWithExpressionTransformer()` pattern-matches on 100+ Spark expression types (e.g., `Add` → `BinaryExpressionTransformer`, `Cast` → `CastTransformer`, `Literal` → `LiteralTransformer`).

**Stage B: ExpressionTransformer → ExpressionNode** (Substrait protobuf node)

```scala
def doTransform(context: SubstraitContext): ExpressionNode = {
  val functionId = context.registerFunction(substraitExprName)  // e.g., "add"
  val childNodes = children.map(_.doTransform(context))         // recurse
  ExpressionBuilder.makeScalarFunction(functionId, childNodes, outputType)
}
```

### Function Name Mapping

`ExpressionMappings.scala` maps Spark expression classes to Substrait function names:

```scala
Sig[Add]("add"), Sig[Subtract]("subtract"), Sig[Upper]("upper"),
Sig[Sum]("sum"), Sig[Count]("count"), Sig[Rank]("rank"), ...
```

### Serialization and Handoff

At the top of the tree, `WholeStageTransformer`:

1. Calls `PlanBuilder.makePlan(context, [rootRelNode], outputNames, schema)` to create the final `PlanNode`
2. Serializes: `planNode.toProtobuf().toByteArray()` → `byte[]`
3. Packages this into `GlutenPartition` objects in an RDD

The same plan bytes are sent to every executor task — only the split info (which files to read) differs per partition.

### Concrete Example

Given Spark plan:

```
Project [a, b + 1 AS c]
  └─ Filter [b > 10]
       └─ Scan parquet [a, b]
```

The Substrait plan built bottom-up:

```
PlanNode
├─ FunctionMappings: {"gt" → 0, "add" → 1}
└─ ProjectRel
   ├─ expressions: [FieldRef(0), ScalarFunction(1, [FieldRef(1), Literal(1)])]
   └─ input: FilterRel
      ├─ condition: ScalarFunction(0, [FieldRef(1), Literal(10)])
      └─ input: ReadRel
         └─ localFiles: [parquet paths...]
```

---

## 4. Plan Conversion: Substrait IR to Velox Plan

### Entry from JNI

`VeloxRuntime::parsePlan()` (`cpp/velox/compute/VeloxRuntime.cc`) deserializes the protobuf bytes:

```cpp
void VeloxRuntime::parsePlan(const uint8_t* data, int32_t size) {
  parseProtobuf(data, size, &substraitPlan_);  // bytes → ::substrait::Plan
}
```

### Relation Dispatcher

`SubstraitToVeloxPlanConverter::toVeloxPlan(Rel)` is the central dispatch that routes each relation type to a specific converter:

```cpp
if (rel.has_filter())    return toVeloxPlan(rel.filter());
if (rel.has_project())   return toVeloxPlan(rel.project());
if (rel.has_aggregate()) return toVeloxPlan(rel.aggregate());
if (rel.has_join())      return toVeloxPlan(rel.join());
if (rel.has_read())      return toVeloxPlan(rel.read());
if (rel.has_sort())      return toVeloxPlan(rel.sort());
// ... fetch, top_n, window, expand, set, write, etc.
```

Each method recursively converts its child first, then creates the Velox `PlanNode` on top.

### Relation Mapping

| Substrait Relation | Velox PlanNode | Notes |
|---|---|---|
| `ReadRel` | `TableScanNode` / `ValuesNode` | File scan via HiveConnector, or iterator-based input |
| `FilterRel` | `FilterNode` | Condition converted via `SubstraitVeloxExprConverter` |
| `ProjectRel` | `ProjectNode` | Adds projected columns on top of input, uses emit for reordering |
| `AggregateRel` | `AggregationNode` | Step mapping: Partial→`kPartial`, Final→`kFinal`, etc. |
| `JoinRel` | `HashJoinNode` / `MergeJoinNode` | Algorithm selected via AdvancedExtension hints |
| `SortRel` | `OrderByNode` | Sort direction mapping |
| `FetchRel` | `LimitNode` | Offset + count |
| `TopNRel` | `TopNNode` | Combined sort + limit |
| `SetRel` | `UnionNode` | UNION ALL |
| `WindowRel` | `WindowNode` | Window functions |

### Expression Conversion

`SubstraitVeloxExprConverter::toVeloxExpr()` dispatches by expression type:

| Substrait Expression | Velox TypedExpr |
|---|---|
| `FieldReference` | `FieldAccessTypedExpr` — column ref by index→name lookup |
| `ScalarFunction` | `CallTypedExpr` — function ID→name via `functionMap_` |
| `Literal` | `ConstantTypedExpr` — scalar values, arrays, maps, structs, typed nulls |
| `Cast` | `CastTypedExpr` — `FAILURE_BEHAVIOR_RETURN_NULL` → try_cast |
| `IfThen` | `CallTypedExpr("if")` or `CallTypedExpr("switch")` |
| `SingularOrList` | `CallTypedExpr("in")` |

### Function Name Resolution

The function map maps integer IDs to compound names like `"add:i64_i64"`. `SubstraitParser::findVeloxFunction()` extracts the base name (`"add"`), which matches Velox's registered function.

---

## 5. Native Execution: How Velox Runs the Plan

The Velox execution engine source code is not embedded in Gluten — it's downloaded from [facebookincubator/velox](https://github.com/facebookincubator/velox) during build (`ep/build-velox/src/get-velox.sh`). The Gluten integration code reveals exactly how the pieces fit together.

### Task Creation

`WholeStageResultIterator` constructor (`WholeStageResultIterator.cc`):

```cpp
PlanFragment planFragment{planNode, ExecutionStrategy::kUngrouped, 1, emptySet};
QueryCtx queryCtx = createNewVeloxQueryCtx();

task_ = Task::create(
    taskId, planFragment, 0, queryCtx,
    Task::ExecutionMode::kSerial,   // single-threaded, driven by Spark
    Consumer{}, 0, spillDiskOpts, nullptr);
```

Gluten uses **serial execution mode** — Velox runs on Spark's executor thread rather than spawning its own thread pool.

### Pipeline Splitting

When `Task::create()` is called, Velox's **LocalPlanner** splits the `PlanNode` tree into **pipelines** at nodes that accumulate all input before producing output:

```
PlanNode Tree:                      Pipelines Created:

  HashJoinNode                      Pipeline 0 (probe side):
  ├── probe: FilterNode               TableScan → Filter → HashProbe → output
  │   └── TableScanNode
  └── build: ProjectNode            Pipeline 1 (build side):
      └── TableScanNode               TableScan → Project → HashBuild
```

Pipeline breakers include `HashJoinNode` (splits into build + probe), `AggregationNode`, `OrderByNode`, and `WindowNode`.

### PlanNode to Operator Mapping

| PlanNode | Operator(s) |
|---|---|
| `TableScanNode` | `TableScan` |
| `FilterNode` + `ProjectNode` | `FilterProject` (fused for efficiency) |
| `AggregationNode` | `HashAggregation` |
| `HashJoinNode` | `HashProbe` (pipeline 0) + `HashBuild` (pipeline 1) |
| `OrderByNode` | `OrderBy` |
| `TopNNode` | `TopN` |
| `LimitNode` | `Limit` |
| `WindowNode` | `Window` |

### The Execution Loop

`WholeStageResultIterator::next()` drives execution:

```cpp
while (true) {
    auto future = ContinueFuture::makeEmpty();
    auto out = task_->next(&future);     // drive one quantum of execution
    if (!future.valid()) {
        vector = std::move(out);         // got a result or finished
        break;
    }
    future.wait();                       // blocked (I/O, spill), wait
}
return std::make_shared<VeloxColumnarBatch>(vector);
```

In serial mode, `task_->next()` picks the next Driver, runs one operator chain quantum, and returns a batch. Operators use a **pull model**: each operator's `getOutput()` pulls data from the previous operator via `addInput()`.

### Split-Driven Data Feeding

Splits tell `TableScan` operators where to read data:

- **File-based splits**: `HiveConnectorSplit` with file path, format, byte offset, length, partition columns.
- **Iterator-based splits**: `IteratorConnectorSplit` wrapping a `ResultIterator` from a previous Spark stage, flowing through the custom `ValueStreamConnector` → `ValueStreamDataSource` → `RowVectorStream` chain.

---

## 6. Memory Management: Bridging Spark and Velox

### Vanilla Spark Memory Model

Spark's `UnifiedMemoryManager` divides each executor's memory into execution memory (shuffles, joins, sorts), storage memory (cached data), and user memory. Off-heap mode (`spark.memory.offHeap.enabled`) allows allocations outside the JVM heap.

### How Gluten Changes This

With Gluten, Velox operates entirely in **native C++ memory** (off-heap), but Spark is **fully aware** of every byte Velox allocates through a bidirectional callback chain across JNI:

```
Velox operator needs memory
    → Velox MemoryPool::reserve()
    → ListenableArbitrator::growCapacityInternal()     [C++ side]
    → BlockAllocationListener (buffers to 128MB blocks) [C++ side]
    → SparkAllocationListener::allocationChanged()      [JNI crossing]
    → ManagedReservationListener::reserve()             [Java side]
    → TreeMemoryConsumer::borrow()                      [extends Spark's MemoryConsumer]
    → Spark TaskMemoryManager::acquireExecutionMemory()
    → Spark UnifiedMemoryManager (OFF_HEAP mode)
```

### Key Components

**ListenableArbitrator** (`VeloxMemoryManager.cc`) — custom Velox memory arbitrator that calls `listener_->allocationChanged(neededBytes)` on every allocation/deallocation.

**BlockAllocationListener** (`AllocationListener.h`) — performance optimization that buffers small allocations and only crosses JNI when a 128MB block boundary is hit, reducing JNI overhead.

**SparkAllocationListener** (`JniCommon.h`) — crosses the JNI boundary, calling Java's `reserve()` / `unreserve()` methods.

**TreeMemoryConsumer** (`TreeMemoryConsumer.java`) — extends Spark's `MemoryConsumer`, participating in Spark's spill protocol.

### Bidirectional Spilling

Spilling can be triggered from either direction:

- **Spark → Velox**: When another Spark task needs memory, `TreeMemoryConsumer.spill()` is called → JNI → `VeloxMemoryManager::shrink()` → Velox spills operators to disk.
- **Velox → Spark**: When Velox requests memory via the listener chain, Spark may spill other consumers first.

### Key Configuration

| Config | Purpose |
|---|---|
| `spark.memory.offHeap.size` | Total off-heap budget per executor — **this is Velox's memory ceiling** |
| `spark.gluten.memory.reservation.blockSize` | Granularity of JNI reservation callbacks (default 128MB) |
| `spark.gluten.sql.columnar.backend.velox.spillStrategy` | Set to `"auto"` to enable spill-to-disk |

---

## 7. Zero-Copy Data Exchange

Gluten employs several layered techniques to minimize data copying between Spark (JVM) and Velox (native C++).

### The "Light Batch"

Columnar batch data **never lives in the JVM heap**. Gluten replaces Spark's `ColumnarBatch` with a light batch — a JVM object holding only a native pointer (handle):

```
Gluten Light Batch:
┌──────────────────────────┐
│ IndicatorVector          │
│   handle = 0x7f3a...     │──► Native Memory (Velox RowVector)
│   refCnt = AtomicLong(1) │
│ PlaceholderVector × N    │
│   (no data, just schema) │
└──────────────────────────┘
```

When Spark passes a batch to the next operator, only the handle (a `long`) crosses JNI.

### Arrow C Data Interface

When data does need to cross the JVM-native boundary, Gluten uses the Arrow C Data Interface — two flat C structs (`ArrowSchema` + `ArrowArray`) containing only **pointers to existing buffers**:

```cpp
auto arrowArray = std::make_shared<ArrowArray>();
arrow::ExportRecordBatch(*recordBatch, arrowArray.get());
// arrowArray contains POINTERS to existing buffers, not copies
```

`ArrowSchemaMove` / `ArrowArrayMove` are move operations that transfer ownership of buffer pointers, not copy data.

### Velox Import As Owner

When Arrow data becomes a Velox `RowVector`:

```cpp
auto vp = velox::importFromArrowAsOwner(*schema, *array, pool);
```

Velox **adopts the existing Arrow buffers directly** — no data copy.

### Columnar-to-Row: Direct Memory Pointing

When falling back to Spark rows, native code serializes into UnsafeRow format in a native buffer. The JVM then:

```scala
row.pointTo(null, info.memoryAddress + offset, length)
```

`UnsafeRow` references native memory directly — no copy into JVM heap.

### Broadcast Hash Table Sharing

For broadcast joins, the hash table is built **once** in native memory and cached by ID. All executor tasks reference the same native hash table via pointer — no data duplication.

### Summary

| Data Path | Copy? |
|---|---|
| Velox operator → Velox operator | **No** — same RowVector flows through |
| Velox batch → JVM | **No** — handle/pointer via JNI |
| Arrow batch → Velox | **No** — `importFromArrowAsOwner` |
| Velox columnar → Spark UnsafeRow (fallback) | **Minimal** — `UnsafeRow.pointTo()` native buffer |
| Spark UnsafeRow → Velox columnar | **One bulk copy** — batched into contiguous buffer |
| Broadcast hash table | **No duplication** — single table, shared by all tasks |
| Column selection / slicing | **No** — new RowVector with shared_ptr to same children |

---

## 8. Native Columnar Shuffle

### What Vanilla Spark Does

Spark's shuffle serializes rows through Java: `ColumnarBatch → UnsafeRow → serialize → network → deserialize → UnsafeRow → ColumnarBatch`. Every row crosses a serialization boundary with significant GC overhead.

### How Gluten Replaces It

Gluten registers `GlutenShuffleManager` as Spark's shuffle manager. It intercepts `getWriter()`/`getReader()` calls and routes columnar dependencies to native implementations.

The operator replacement chain:

```
Spark: ShuffleExchangeExec → ShuffleDependency[InternalRow]
Gluten: ColumnarShuffleExchangeExec → ColumnarShuffleDependency[ColumnarBatch]
```

### Write Path

`ColumnarShuffleWriter` is a JNI wrapper that passes native batch handles to C++:

```scala
val handle = ColumnarBatches.getNativeHandle(cb)  // just a pointer
shuffleWriterJniWrapper.write(nativeShuffleWriter, handle, memLimit)
```

Three native writer implementations:

**VeloxHashShuffleWriter** — the most common path:

1. Extract partition IDs from the first column of each batch
2. `Partitioner::compute()` → `row2Partition[]` mapping
3. Split columns into per-partition buffers via memcpy
4. Evict to disk when memory pressure hits (compress + write)
5. On `stop()`: merge spills into final data file + index file

**VeloxSortShuffleWriter** — for large partition counts:

1. Convert rows to CompactRow format (packed binary)
2. Record `(partitionId, rowIndex)` pairs
3. On `stop()`: sort by partitionId, write in partition order

**VeloxRssSortShuffleWriter** — for Remote Shuffle Services (Celeborn/Uniffle):

1. Partition rows and serialize using Presto VectorSerde format
2. Send to RSS service via `PartitionWriter::evict()`

### Read Path

`ColumnarShuffleReader` uses Spark's standard `ShuffleBlockFetcherIterator` to fetch blocks (network layer unchanged), then deserializes natively:

```
Fetch blocks (Spark's BlockManager) → JNI → VeloxShuffleReader
  → VeloxHashShuffleReaderDeserializer (Arrow IPC)
  → or VeloxSortShuffleReaderDeserializer (CompactRow → RowVector)
  → or VeloxRssSortShuffleReaderDeserializer (Presto format)
→ Return Iterator[ColumnarBatch]
```

### Performance Comparison

| Aspect | Vanilla Spark | Gluten Native Shuffle |
|---|---|---|
| Data format | Row-by-row (UnsafeRow) | Columnar (RowVector / Arrow IPC) |
| Serialization | Java/Kryo per-row | Native Arrow IPC or CompactRow (bulk) |
| Partitioning | Java HashMap per-row | Native partitioner on columnar batch |
| Memory | JVM heap (GC pressure) | Off-heap native buffers (no GC) |
| Compression | Java codec | Native LZ4/ZSTD (SIMD-optimized) |

---

## 9. Limitations: What Falls Back to Spark

### Unsupported Operators

These always fall back to vanilla Spark:

- **All Pandas UDF operators**: `AggregateInPandasExec`, `ArrowEvalPythonExec`, `FlatMapGroupsInPandasExec`, `MapInPandasExec`, `WindowInPandasExec`
- **ShuffleExchangeExec**: Replaced by `ColumnarShuffleExchangeExec` (separate native path), not offloaded through the Velox pipeline
- **BroadcastNestedLoopJoinExec**: Full outer joins and certain join configurations not supported

### Data Type Limitations

For most supported operators, these types cause fallback:

| Type | Status |
|---|---|
| ARRAY, MAP, STRUCT | Not supported for most operators |
| TIMESTAMP | Only INT96 + dictionary encoding for Parquet reads |
| DECIMAL | Not supported for most operators (supported in some write operators) |
| CALENDAR, UDT | Not supported anywhere |

### Unsupported Functions (Notable)

**Scalar functions** — 90 of 357 are unsupported, including:
- All XML functions (`xpath_*`)
- All CSV functions (`from_csv`, `to_csv`, `schema_of_csv`)
- Many datetime constructors (`make_interval`, `make_timestamp_*`, `to_date`, `to_timestamp`)
- Encryption (`aes_encrypt`, `aes_decrypt`)
- Reflection (`java_method`, `reflect`)
- Several string functions (`format_number`, `format_string`, `sentences`, `decode`, `encode`)

**Aggregate functions** — 9 of 62 unsupported:
- `approx_percentile`, `percentile`, `percentile_approx`, `mode`
- `count_min_sketch`, `histogram_numeric`
- `bitmap_construct_agg`, `bitmap_or_agg`
- `hll_sketch_agg`, `hll_union_agg`

**Partially supported** functions have restrictions:
- `regexp` / `rlike` / `regexp_extract`: Lookaround patterns unsupported (RE2 vs Java regex)
- `from_json` / `to_json`: No case-sensitive mode, no options support
- `contains`, `startswith`, `endswith`, `lpad`, `rpad`: BinaryType unsupported

### Global Fallback Triggers

| Condition | Effect |
|---|---|
| `spark.sql.ansi.enabled = true` | All operators fall back |
| `spark.sql.caseSensitive = true` | May produce incorrect results |
| Non-parquet file formats | Scan falls back (ORC partially supported, CSV limited) |
| Bucket write | Always falls back |

### Behavioral Incompatibilities

These run natively but may produce different results:
- **NaN**: Velox does NOT support NaN — comparisons give unexpected results
- **JSON**: Only double-quoted strings; `get_json_object` doesn't support `[*]` path
- **Parquet datetime rebase**: Ignores Julian/Gregorian calendar differences
- **BloomFilter**: Velox serialization format incompatible with Spark's

---

## 10. End-to-End: A Spark Job With Gluten

Here is the complete lifecycle of a Spark job with Gluten, from application startup to result collection.

### Phase 1: Application Startup (Driver)

```
SparkContext starts
    ↓
GlutenPlugin loaded (spark.plugins config)
    ↓
GlutenDriverPlugin.init():
    1. Register GlutenSessionExtensions into spark.sql.extensions
    2. Discover Components (VeloxBackend, etc.) via META-INF
    3. component.onDriverStart() for each component
    ↓
SparkSession created → GlutenSessionExtensions injects rules:
    - Catalyst resolution/optimizer/strategy rules
    - GlutenColumnarRule (the main columnar transformation hook)
```

### Phase 2: Query Planning (Driver)

```
spark.sql("SELECT a, b+1 FROM t WHERE b > 10")
    ↓
Standard Catalyst: Parse → Analyze → Optimize → Physical Plan
    ↓
GlutenColumnarRule.postColumnarTransitions():
    HeuristicApplier transforms the plan:
      1. TRANSFORM: Replace Spark operators with Transformers
         (each validated via native doNativeValidation)
      2. FALLBACK: Check cost of transitions
      3. POST: Insert ColumnarToRow/RowToColumnar at boundaries
    ↓
WholeStageTransformer wraps contiguous native operators
    ↓
doExecuteColumnar():
    - Generate Substrait plan (bottom-up tree traversal)
    - Serialize to protobuf bytes
    - Create GlutenWholeStageColumnarRDD
      (plan bytes + split info per partition)
    ↓
DAGScheduler submits tasks to executors
```

### Phase 3: Executor Startup (Once Per Executor)

```
Executor JVM starts
    ↓
GlutenExecutorPlugin.init():
    → component.onExecutorStart() for each component
    ↓
VeloxListenerApi.onExecutorStart():
    1. Extract & load libvelox.so via System.load()
    2. JNI → VeloxBackend::init():
       - Register filesystems (local, HDFS, S3, GCS, ABFS)
       - Register Hive connector, Velox functions
       - Initialize async data cache
       - Register ValueStreamConnector for iterator inputs
```

### Phase 4: Task Execution (Per Partition)

```
Spark TaskRunner picks up task
    ↓
GlutenWholeStageColumnarRDD.compute(partition):
    ↓
VeloxIteratorApi.genFirstStageIterator():
    1. Create NativeMemoryManager
       → VeloxMemoryManager + Spark memory bridge

    2. JNI: parsePlan(bytes) → Substrait Plan
       JNI: parseSplitInfo(bytes) → file locations

    3. JNI: createResultIterator()
       → SubstraitToVeloxPlan → PlanNode tree
       → Task::create(kSerial) → pipelines + operators
       → Add splits (files / iterators)

    4. Pull loop:
       while (iter.hasNext()):
         batch = iter.next()
           → JNI → task_->next()
             → Velox runs operator pipeline
               TableScan → FilterProject → output
             → Returns RowVector
           ← JNI ← native handle (no data copy)

    5. If shuffle map task:
       ColumnarShuffleWriter.write(nativeHandle)
         → Native partitioning + serialization + disk write

    6. Collect metrics → update Spark SQL metrics

    7. Release: VeloxMemoryManager destroyed
       → All native memory freed → Spark notified
```

### Phase 5: Shuffle (Between Stages)

```
Map side:
  Velox pipeline → ColumnarBatch → native shuffle writer
  → partition → compress → local disk (data + index files)

  ↕ Spark's BlockManager fetches over network (unchanged) ↕

Reduce side:
  ShuffleBlockFetcherIterator → native shuffle reader
  → decompress → deserialize → ColumnarBatch
  → feed into next WholeStageTransformer pipeline
```

### Phase 6: Result Collection

```
Final stage ResultTask:
  Native pipeline produces final ColumnarBatch results
  → ColumnarToRow if needed (for collect()/show())
  → Results sent back to driver
    ↓
Driver collects results from all partitions
```

### Phase 7: Cleanup

```
Task completion:
  NativeMemoryManager.release()
    → VeloxMemoryManager destroyed
    → Velox memory pools freed
    → Spark memory accounting updated

Executor shutdown:
  GlutenExecutorPlugin.shutdown()
    → component.onExecutorShutdown()
    → Native resources released

Driver shutdown:
  GlutenDriverPlugin.shutdown()
    → component.onDriverShutdown()
```

### Visual Summary

```
╔═══════════════════════════════════════════════════════════════════╗
║                         DRIVER SIDE                              ║
╠═══════════════════════════════════════════════════════════════════╣
║                                                                   ║
║  GlutenPlugin.init() → register extensions + discover components ║
║                              ↓                                    ║
║  SparkSession → inject GlutenColumnarRule                        ║
║                              ↓                                    ║
║  Query → Catalyst planning → GlutenColumnarRule transforms plan  ║
║           ┌─────────────────────────────────────┐                ║
║           │ Spark Operators → Gluten Transformers│                ║
║           │ Scan → ScanTransformer              │                ║
║           │ Filter → FilterTransformer          │                ║
║           │ Join → JoinTransformer              │                ║
║           │ Exchange → ColumnarShuffle          │                ║
║           └─────────────────────────────────────┘                ║
║                              ↓                                    ║
║  WholeStageTransformer generates Substrait plan bytes            ║
║  Creates GlutenWholeStageColumnarRDD → submit tasks              ║
║                                                                   ║
╠═══════════════════════════════════════════════════════════════════╣
║                        EXECUTOR SIDE                              ║
╠═══════════════════════════════════════════════════════════════════╣
║                                                                   ║
║  ONCE: Load libvelox.so → VeloxBackend::init()                   ║
║        Register filesystems, connectors, functions               ║
║                                                                   ║
║  PER TASK:                                                        ║
║  ┌──────────────────────────────────────────────────────────┐    ║
║  │ Create NativeMemoryManager (Velox ↔ Spark memory bridge)│    ║
║  │                      ↓                                    │    ║
║  │ parsePlan() → Substrait → SubstraitToVeloxPlan            │    ║
║  │                      ↓                                    │    ║
║  │ Task::create(kSerial) → pipelines + operators             │    ║
║  │                      ↓                                    │    ║
║  │ Pull loop: task_->next() → Velox executes pipeline        │    ║
║  │   TableScan → FilterProject → HashProbe → output          │    ║
║  │                      ↓                                    │    ║
║  │ RowVector → native handle → JVM (no data copy)            │    ║
║  │                      ↓                                    │    ║
║  │ Collect metrics → cleanup native resources                │    ║
║  └──────────────────────────────────────────────────────────┘    ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
```

---

## Conclusion

Gluten's architecture demonstrates a sophisticated approach to accelerating Spark SQL:

1. **Minimal invasion**: Hooks into Spark via the standard `SparkPlugin` and `ColumnarRule` APIs — no Spark source modifications needed.
2. **Substrait as the interchange format**: Decouples Spark plan representation from native execution, allowing each side to evolve independently.
3. **Zero-copy where possible**: Data stays in native memory; JVM holds only handles.
4. **Unified memory accounting**: Every native byte is tracked through Spark's memory manager via JNI callbacks.
5. **Graceful fallback**: Unsupported operators seamlessly fall back to vanilla Spark with automatic data format transitions at boundaries.
6. **End-to-end native execution**: From scan through filter, join, aggregation, sort, and shuffle — the entire pipeline runs in vectorized C++ with columnar data, achieving significant speedups over JVM-based execution.
