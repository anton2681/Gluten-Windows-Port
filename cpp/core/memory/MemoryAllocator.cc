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

#include "MemoryAllocator.h"
#include "utils/Macros.h"

#include <limits>

#ifdef _WIN32
#include <malloc.h>
// On Windows, use _aligned_malloc/_aligned_free for ALL allocations (aligned and non-aligned).
// This ensures all memory freed via gluten_std_free or gluten_aligned_free is consistent.
// _aligned_malloc with alignment=1 is effectively the same as malloc but must be freed with _aligned_free.
static inline void* gluten_std_alloc(size_t size) {
  return _aligned_malloc(size, 1);
}
static inline void* gluten_std_calloc(size_t nmemb, size_t size) {
  void* p = _aligned_malloc(nmemb * size, 1);
  if (p) {
    memset(p, 0, nmemb * size);
  }
  return p;
}
static inline void* gluten_std_realloc(void* p, size_t newSize) {
  return _aligned_realloc(p, newSize, 1);
}
static inline void gluten_std_free(void* p) {
  _aligned_free(p);
}
static inline void* gluten_aligned_alloc(size_t alignment, size_t size) {
  return _aligned_malloc(size, alignment);
}
static inline void gluten_aligned_free(void* p) {
  _aligned_free(p);
}
#else
static inline void* gluten_std_alloc(size_t size) {
  return std::malloc(size);
}
static inline void* gluten_std_calloc(size_t nmemb, size_t size) {
  return std::calloc(nmemb, size);
}
static inline void* gluten_std_realloc(void* p, size_t newSize) {
  return std::realloc(p, newSize);
}
static inline void gluten_std_free(void* p) {
  std::free(p);
}
static inline void* gluten_aligned_alloc(size_t alignment, size_t size) {
  return std::aligned_alloc(alignment, size);
}
static inline void gluten_aligned_free(void* p) {
  std::free(p);
}
#endif

namespace gluten {

bool ListenableMemoryAllocator::allocate(int64_t size, void** out) {
  updateUsage(size);
  bool succeed = delegated_->allocate(size, out);
  if (!succeed) {
    updateUsage(-size);
  }
  return succeed;
}

bool ListenableMemoryAllocator::allocateZeroFilled(int64_t nmemb, int64_t size, void** out) {
  updateUsage(size * nmemb);
  bool succeed = delegated_->allocateZeroFilled(nmemb, size, out);
  if (!succeed) {
    updateUsage(-size * nmemb);
  }
  return succeed;
}

bool ListenableMemoryAllocator::allocateAligned(uint64_t alignment, int64_t size, void** out) {
  updateUsage(size);
  bool succeed = delegated_->allocateAligned(alignment, size, out);
  if (!succeed) {
    updateUsage(-size);
  }
  return succeed;
}

bool ListenableMemoryAllocator::reallocate(void* p, int64_t size, int64_t newSize, void** out) {
  int64_t diff = newSize - size;
  if (diff >= 0) {
    updateUsage(diff);
    bool succeed = delegated_->reallocate(p, size, newSize, out);
    if (!succeed) {
      updateUsage(-diff);
    }
    return succeed;
  } else {
    bool succeed = delegated_->reallocate(p, size, newSize, out);
    if (succeed) {
      updateUsage(diff);
    }
    return succeed;
  }
}

bool ListenableMemoryAllocator::reallocateAligned(
    void* p,
    uint64_t alignment,
    int64_t size,
    int64_t newSize,
    void** out) {
  int64_t diff = newSize - size;
  if (diff >= 0) {
    updateUsage(diff);
    bool succeed = delegated_->reallocateAligned(p, alignment, size, newSize, out);
    if (!succeed) {
      updateUsage(-diff);
    }
    return succeed;
  } else {
    bool succeed = delegated_->reallocateAligned(p, alignment, size, newSize, out);
    if (succeed) {
      updateUsage(diff);
    }
    return succeed;
  }
}

bool ListenableMemoryAllocator::free(void* p, int64_t size) {
  bool succeed = delegated_->free(p, size);
  if (succeed) {
    updateUsage(-size);
  }
  return succeed;
}

int64_t ListenableMemoryAllocator::getBytes() const {
  return usedBytes_;
}

int64_t ListenableMemoryAllocator::peakBytes() const {
  return peakBytes_;
}

void ListenableMemoryAllocator::updateUsage(int64_t size) {
  listener_->allocationChanged(size);
  usedBytes_ += size;
  while (true) {
    int64_t savedPeakBytes = peakBytes_;
    int64_t savedUsedBytes = usedBytes_;
    if (savedUsedBytes <= savedPeakBytes) {
      break;
    }
    // usedBytes_ > savedPeakBytes, update peak
    if (peakBytes_.compare_exchange_weak(savedPeakBytes, savedUsedBytes)) {
      break;
    }
  }
}

bool StdMemoryAllocator::allocate(int64_t size, void** out) {
  GLUTEN_CHECK(size >= 0, "size is less than 0");
  *out = gluten_std_alloc(size);
  if (*out == nullptr) {
    return false;
  }
  bytes_ += size;
  return true;
}

bool StdMemoryAllocator::allocateZeroFilled(int64_t nmemb, int64_t size, void** out) {
  GLUTEN_CHECK(nmemb >= 0, "nmemb is less than 0");
  GLUTEN_CHECK(size >= 0, "size is less than 0");
  GLUTEN_CHECK(
      size == 0 || nmemb <= std::numeric_limits<int64_t>::max() / size,
      "nmemb * size overflows int64_t");
  *out = gluten_std_calloc(nmemb, size);
  if (*out == nullptr) {
    return false;
  }
  bytes_ += nmemb * size;
  return true;
}

bool StdMemoryAllocator::allocateAligned(uint64_t alignment, int64_t size, void** out) {
  GLUTEN_CHECK(size >= 0, "size is less than 0");
  *out = gluten_aligned_alloc(alignment, size);
  if (*out == nullptr) {
    return false;
  }
  bytes_ += size;
  return true;
}

bool StdMemoryAllocator::reallocate(void* p, int64_t size, int64_t newSize, void** out) {
  *out = gluten_std_realloc(p, newSize);
  if (*out == nullptr) {
    return false;
  }
  bytes_ += (newSize - size);
  return true;
}

bool StdMemoryAllocator::reallocateAligned(void* p, uint64_t alignment, int64_t size, int64_t newSize, void** out) {
  GLUTEN_CHECK(p != nullptr, "reallocate with nullptr");
  if (newSize <= 0) {
    return false;
  }
  if (newSize <= size) {
    auto aligned = ROUND_TO_LINE(static_cast<uint64_t>(newSize), alignment);
    if (aligned <= size) {
      // shrink-to-fit: must use aligned alloc/free (_aligned_malloc is not compatible with realloc)
      void* reallocatedP = gluten_aligned_alloc(alignment, aligned);
      if (reallocatedP == nullptr) {
        return false;
      }
      memcpy(reallocatedP, p, aligned);
      gluten_aligned_free(p);
      *out = reallocatedP;
      bytes_ += (static_cast<int64_t>(aligned) - size);
      return true;
    }
  }
  void* reallocatedP = gluten_aligned_alloc(alignment, newSize);
  if (reallocatedP == nullptr) {
    return false;
  }
  memcpy(reallocatedP, p, std::min(size, newSize));
  gluten_aligned_free(p);
  *out = reallocatedP;
  bytes_ += (newSize - size);
  return true;
}

bool StdMemoryAllocator::free(void* p, int64_t size) {
  GLUTEN_CHECK(p != nullptr, "free with nullptr");
  gluten_std_free(p);
  bytes_ -= size;
  return true;
}

int64_t StdMemoryAllocator::getBytes() const {
  return bytes_;
}

int64_t StdMemoryAllocator::peakBytes() const {
  return 0;
}

std::shared_ptr<MemoryAllocator> defaultMemoryAllocator() {
  static std::shared_ptr<MemoryAllocator> alloc = std::make_shared<StdMemoryAllocator>();
  return alloc;
}

} // namespace gluten
