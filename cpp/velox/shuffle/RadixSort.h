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

// Adapted from Apache Spark's shuffle sort radix sort (LSD radix sort on uint64_t arrays).

#pragma once

#include <cassert>
#include <cstring>
#include <cstdint>

namespace gluten {

/// LSD radix sort for uint64_t arrays.
/// The input array must have capacity for at least 2 * numRecords elements
/// (the second half is used as scratch space during sorting).
/// Returns the starting index (0 or numRecords) of the sorted data.
class RadixSort {
 public:
  // arraySize is the total allocated capacity of array (must be >= 2 * numRecords).
  // The second half (array[numRecords..arraySize-1]) is used as scratch space.
  static int sort(
      uint64_t* array,
      int64_t arraySize,
      int64_t numRecords,
      int startByteIndex,
      int endByteIndex) {
    assert(startByteIndex >= 0);
    assert(endByteIndex <= 7);
    assert(startByteIndex <= endByteIndex);
    assert(numRecords >= 0);
    assert(arraySize >= 2 * numRecords);

    if (numRecords == 0) {
      return 0;
    }

    int64_t counts[8][256] = {};
    getCounts(array, numRecords, startByteIndex, endByteIndex, counts);

    uint64_t* input = array;
    uint64_t* output = array + numRecords;
    int outputOffset = 1; // relative to numRecords blocks

    for (int byteIdx = startByteIndex; byteIdx <= endByteIndex; ++byteIdx) {
      // Check if this byte needs sorting (skip if all counts collapse to one bucket).
      bool skip = true;
      for (int b = 0; b < 256; ++b) {
        if (counts[byteIdx][b] == numRecords) {
          skip = true;
          break;
        }
        if (counts[byteIdx][b] != 0) {
          skip = false;
        }
      }
      if (skip) {
        continue;
      }

      int64_t offsets[256];
      transformCountsToOffsets(counts[byteIdx], numRecords, offsets);
      sortAtByte(input, output, numRecords, byteIdx, offsets);

      // Swap input/output buffers.
      uint64_t* tmp = input;
      input = output;
      output = tmp;
      outputOffset = 1 - outputOffset;
    }

    // Return the offset (0 or numRecords) of the sorted data relative to array.
    return (input == array) ? 0 : static_cast<int>(numRecords);
  }

 private:
  static void getCounts(
      uint64_t* array,
      int64_t numRecords,
      int startByteIndex,
      int endByteIndex,
      int64_t counts[8][256]) {
    for (int64_t i = 0; i < numRecords; ++i) {
      uint64_t val = array[i];
      for (int b = startByteIndex; b <= endByteIndex; ++b) {
        counts[b][(val >> (b * 8)) & 0xFF]++;
      }
    }
  }

  static void transformCountsToOffsets(int64_t* counts, int64_t /*numRecords*/, int64_t* offsets) {
    int64_t pos = 0;
    for (int b = 0; b < 256; ++b) {
      offsets[b] = pos;
      pos += counts[b];
    }
  }

  static void sortAtByte(
      uint64_t* input,
      uint64_t* output,
      int64_t numRecords,
      int byteIdx,
      int64_t* offsets) {
    for (int64_t i = 0; i < numRecords; ++i) {
      uint64_t val = input[i];
      int bucket = (val >> (byteIdx * 8)) & 0xFF;
      output[offsets[bucket]++] = val;
    }
  }
};

} // namespace gluten
