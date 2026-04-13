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

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <utility>

#include "memory/AllocationListener.h"

// On Windows, symbols in a DLL must be explicitly exported/imported.
// See MemoryManager.h for a fuller explanation of this pattern.
#ifndef GLUTEN_EXPORT
#ifdef _WIN32
#ifdef gluten_EXPORTS
#define GLUTEN_EXPORT __declspec(dllexport)
#else
#define GLUTEN_EXPORT __declspec(dllimport)
#endif
#else
#define GLUTEN_EXPORT
#endif
#endif

namespace gluten {

class MemoryAllocator {
 public:
  virtual ~MemoryAllocator() = default;

  virtual bool allocate(int64_t size, void** out) = 0;
  virtual bool allocateZeroFilled(int64_t nmemb, int64_t size, void** out) = 0;
  virtual bool allocateAligned(uint64_t alignment, int64_t size, void** out) = 0;

  virtual bool reallocate(void* p, int64_t size, int64_t newSize, void** out) = 0;
  virtual bool reallocateAligned(void* p, uint64_t alignment, int64_t size, int64_t newSize, void** out) = 0;

  virtual bool free(void* p, int64_t size) = 0;

  virtual int64_t getBytes() const = 0;

  virtual int64_t peakBytes() const = 0;
};

// The class must be thread safe
class ListenableMemoryAllocator final : public MemoryAllocator {
 public:
  explicit ListenableMemoryAllocator(MemoryAllocator* delegated, AllocationListener* listener)
      : delegated_(delegated), listener_(listener) {}

 public:
  GLUTEN_EXPORT bool allocate(int64_t size, void** out) override;

  GLUTEN_EXPORT bool allocateZeroFilled(int64_t nmemb, int64_t size, void** out) override;

  GLUTEN_EXPORT bool allocateAligned(uint64_t alignment, int64_t size, void** out) override;

  GLUTEN_EXPORT bool reallocate(void* p, int64_t size, int64_t newSize, void** out) override;

  GLUTEN_EXPORT bool reallocateAligned(void* p, uint64_t alignment, int64_t size, int64_t newSize, void** out) override;

  GLUTEN_EXPORT bool free(void* p, int64_t size) override;

  GLUTEN_EXPORT int64_t getBytes() const override;

  GLUTEN_EXPORT int64_t peakBytes() const override;

 private:
  GLUTEN_EXPORT void updateUsage(int64_t size);
  MemoryAllocator* const delegated_;
  AllocationListener* const listener_;
  std::atomic_int64_t usedBytes_{0L};
  std::atomic_int64_t peakBytes_{0L};
};

class StdMemoryAllocator final : public MemoryAllocator {
 public:
  GLUTEN_EXPORT bool allocate(int64_t size, void** out) override;

  GLUTEN_EXPORT bool allocateZeroFilled(int64_t nmemb, int64_t size, void** out) override;

  GLUTEN_EXPORT bool allocateAligned(uint64_t alignment, int64_t size, void** out) override;

  GLUTEN_EXPORT bool reallocate(void* p, int64_t size, int64_t newSize, void** out) override;

  GLUTEN_EXPORT bool reallocateAligned(void* p, uint64_t alignment, int64_t size, int64_t newSize, void** out) override;

  GLUTEN_EXPORT bool free(void* p, int64_t size) override;

  GLUTEN_EXPORT int64_t getBytes() const override;

  GLUTEN_EXPORT int64_t peakBytes() const override;

 private:
  std::atomic_int64_t bytes_{0};
};

GLUTEN_EXPORT std::shared_ptr<MemoryAllocator> defaultMemoryAllocator();

} // namespace gluten
