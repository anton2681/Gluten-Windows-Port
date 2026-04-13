/*
 * Licensed to the Apache Software Foundation (ASF) under one or more
 * contributor license agreements.  See the NOTICE file distributed with
 * this work for additional information regarding copyright ownership.
 * The ASF licenses this file to You under the Apache License, Version 2.0
 * (the "License"); you may not use this file except in compliance with
 * the License.  You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#pragma once

#include <cstdint>
#include <memory>

namespace gluten {

struct Metrics {
  unsigned int numMetrics = 0;
  int64_t veloxToArrow = 0;

  // The underlying memory buffer.
  // Use int64_t (not long) so it is 64-bit on every platform, including
  // Windows where sizeof(long)==4. JniWrapper passes these arrays to
  // SetLongArrayRegion which expects jlong (= int64_t) elements.
  std::unique_ptr<int64_t[]> array;

  // Optional stats string.
  std::optional<std::string> stats = std::nullopt;

  enum TYPE {
    // Begin from 0.
    kBegin = 0,

    kInputRows = kBegin,
    kInputVectors,
    kInputBytes,

    kRawInputRows,
    kRawInputBytes,

    kOutputRows,
    kOutputVectors,
    kOutputBytes,

    // CpuWallTiming.
    kCpuCount,
    kWallNanos,

    kPeakMemoryBytes,
    kNumMemoryAllocations,

    // Spill.
    kSpilledInputBytes,
    kSpilledBytes,
    kSpilledRows,
    kSpilledPartitions,
    kSpilledFiles,

    // Runtime metrics.
    kNumDynamicFiltersProduced,
    kNumDynamicFiltersAccepted,
    kNumReplacedWithDynamicFilterRows,
    kNumDynamicFilterInputRows,
    kFlushRowCount,
    kLoadedToValueHook,
    kBloomFilterBlocksByteSize,
    kScanTime,
    kSkippedSplits,
    kProcessedSplits,
    kSkippedStrides,
    kProcessedStrides,
    kRemainingFilterTime,
    kIoWaitTime,
    kStorageReadBytes,
    kLocalReadBytes,
    kRamReadBytes,
    kPreloadSplits,
    kPageLoadTime,
    kDataSourceAddSplitWallNanos,
    kDataSourceReadWallNanos,

    // Write metrics.
    kPhysicalWrittenBytes,
    kWriteIOTime,
    kNumWrittenFiles,

    // Load lazy vector.
    kLoadLazyVectorTime,

    // The end of enum items.
    kEnd,
    kNum = kEnd - kBegin
  };

  Metrics(unsigned int numMetrics) : numMetrics(numMetrics), array(new int64_t[numMetrics * kNum]()) {
  }

  Metrics(const Metrics&) = delete;
  Metrics(Metrics&&) = delete;
  Metrics& operator=(const Metrics&) = delete;
  Metrics& operator=(Metrics&&) = delete;

  int64_t* get(TYPE type) {
    assert(static_cast<int>(type) >= static_cast<int>(kBegin) && static_cast<int>(type) < static_cast<int>(kEnd));
    auto offset = (static_cast<int>(type) - static_cast<int>(kBegin)) * numMetrics;
    return &array.get()[offset];
  }
};

} // namespace gluten
