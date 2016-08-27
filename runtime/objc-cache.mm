/*
 * Copyright (c) 1999-2007 Apple Inc.  All Rights Reserved.
 * 
 * @APPLE_LICENSE_HEADER_START@
 * 
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 * 
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 * 
 * @APPLE_LICENSE_HEADER_END@
 */

/***********************************************************************
* objc-cache.m
* Method cache management
* Cache flushing
* Cache garbage collection
* Cache instrumentation
* Dedicated allocator for large caches
**********************************************************************/


/***********************************************************************
 * Method cache locking (GrP 2001-1-14)
 *
 * For speed, objc_msgSend does not acquire any locks when it reads 
 * method caches. Instead, all cache changes are performed so that any 
 * objc_msgSend running concurrently with the cache mutator will not 
 * crash or hang or get an incorrect result from the cache. 
 *
 * When cache memory becomes unused (e.g. the old cache after cache 
 * expansion), it is not immediately freed, because a concurrent 
 * objc_msgSend could still be using it. Instead, the memory is 
 * disconnected from the data structures and placed on a garbage list. 
 * The memory is now only accessible to instances of objc_msgSend that 
 * were running when the memory was disconnected; any further calls to 
 * objc_msgSend will not see the garbage memory because the other data 
 * structures don't point to it anymore. The collecting_in_critical
 * function checks the PC of all threads and returns FALSE when all threads 
 * are found to be outside objc_msgSend. This means any call to objc_msgSend 
 * that could have had access to the garbage has finished or moved past the 
 * cache lookup stage, so it is safe to free the memory.
 *
 * All functions that modify cache data or structures must acquire the 
 * cacheUpdateLock to prevent interference from concurrent modifications.
 * The function that frees cache garbage must acquire the cacheUpdateLock 
 * and use collecting_in_critical() to flush out cache readers.
 * The cacheUpdateLock is also used to protect the custom allocator used 
 * for large method cache blocks.
 *
 * Cache readers (PC-checked by collecting_in_critical())
 * objc_msgSend*
 * cache_getImp
 *
 * Cache writers (hold cacheUpdateLock while reading or writing; not PC-checked)
 * cache_fill         (acquires lock)
 * cache_expand       (only called from cache_fill)
 * cache_create       (only called from cache_expand)
 * bcopy               (only called from instrumented cache_expand)
 * flush_caches        (acquires lock)
 * cache_flush        (only called from cache_fill and flush_caches)
 * cache_collect_free (only called from cache_expand and cache_flush)
 *
 * UNPROTECTED cache readers (NOT thread-safe; used for debug info only)
 * cache_print
 * _class_printMethodCaches
 * _class_printDuplicateCacheEntries
 * _class_printMethodCacheStatistics
 *
 ***********************************************************************/

/*
 翻译了一下上面这段极为重要的话。
 
 因为速度的关系，objc_msgSend 在读方法的缓存时，并没有加锁。作为代替，all cache changes are performed（都不知咋翻译）以便所有的 objc_msgSend 并发运行读缓存时都不会崩溃、挂起或者得到错误的结果。
 
 当缓存的内存变成 unused 时（比如扩容后的老的缓存），它不会被立即释放，因为可能一个并发的 objc_msgSend 正在使用它。作为替代，内存与数据结构去掉关联（也就是不在 cache 中存着），而是放在垃圾桶里。那么，当与 cache 失去关联的时候，这块内存就只在当前正在运行的 objc_msgSend 中能被访问；之后任何 objc_msgSend 都不会看到垃圾桶里的这块内存，因为没有其他的数据结构指向它（没有其他的途径可以访问它，指向它的只有垃圾桶）。collecting_in_critical() 函数检查所有的线程的 PC，当所有线程都没有执行 objc_msgSend 时返回 false。这意味着任何所有的objc_msgSend 对垃圾桶里的这块内存的访问都结束了，或者已经不在缓存查找的阶段了（反正就是老缓存彻彻底底的没用了），现在释放老的缓存就是安全的了。
 
 所有的函数更改缓存数据或者数据结构一定要加 cacheUpdateLock 防止并发时的冲突。函数释放垃圾桶里的缓存一定要加 cacheUpdateLock，并且用 collecting_in_critical() 排除 cache readers。
 cacheUpdateLock 也被用来保护自定义的被用作 large method cache blocks 的 allocator
 
 -------------------------------------------------------
 Cache readers (PC-checked by collecting_in_critical())
 objc_msgSend*
 cache_getImp
 
 -------------------------------------------------------
 Cache writers (hold cacheUpdateLock while reading or writing; not PC-checked)
 cache_fill         (acquires lock)
 cache_expand       (only called from cache_fill)
 cache_create       (only called from cache_expand)
 bcopy               (only called from instrumented cache_expand)
 flush_caches        (acquires lock)
 cache_flush        (only called from cache_fill and flush_caches)
 cache_collect_free (only called from cache_expand and cache_flush)
 
 -------------------------------------------------------
 UNPROTECTED cache readers (NOT thread-safe; used for debug info only)
 cache_print
 _class_printMethodCaches
 _class_printDuplicateCacheEntries
 _class_printMethodCacheStatistics
 
 */


#if __OBJC2__

#include "objc-private.h"
#include "objc-cache.h"


/* Initial cache bucket count. INIT_CACHE_SIZE must be a power of two. */
// 初始的 cache 的容量，INIT_CACHE_SIZE 必须是 2 的幂次
// 现在是 1 << 2 也就是 4
enum {
    INIT_CACHE_SIZE_LOG2 = 2,
    INIT_CACHE_SIZE      = (1 << INIT_CACHE_SIZE_LOG2)
};

static void cache_collect_free(struct bucket_t *data, mask_t capacity);
static int _collecting_in_critical(void);
static void _garbage_make_room(void);


/***********************************************************************
* Cache statistics for OBJC_PRINT_CACHE_SETUP
**********************************************************************/
static unsigned int cache_counts[16];
static size_t cache_allocations;
static size_t cache_collections;

static void recordNewCache(mask_t capacity)
{
    size_t bucket = log2u(capacity);
    if (bucket < countof(cache_counts)) {
        cache_counts[bucket]++;
    }
    cache_allocations++;
}

static void recordDeadCache(mask_t capacity)
{
    size_t bucket = log2u(capacity);
    if (bucket < countof(cache_counts)) {
        cache_counts[bucket]--;
    }
}

/***********************************************************************
* Pointers used by compiled class objects
* These use asm to avoid conflicts with the compiler's internal declarations
**********************************************************************/

// EMPTY_BYTES includes space for a cache end marker bucket.
// This end marker doesn't actually have the wrap-around pointer 
// because cache scans always find an empty bucket before they might wrap.
// 1024 buckets is fairly common.
#if DEBUG
    // Use a smaller size to exercise heap-allocated empty caches.
#   define EMPTY_BYTES ((8+1)*16)
#else
#   define EMPTY_BYTES ((1024+1)*16)
#endif

#define stringize(x) #x
#define stringize2(x) stringize(x)

// "cache" is cache->buckets; "vtable" is cache->mask/occupied
// hack to avoid conflicts with compiler's internal declaration
asm("\n .section __TEXT,__const"
    "\n .globl __objc_empty_vtable"
    "\n .set __objc_empty_vtable, 0"
    "\n .globl __objc_empty_cache"
    "\n .align 3"
    "\n __objc_empty_cache: .space " stringize2(EMPTY_BYTES)
    );


#if __arm__  ||  __x86_64__  ||  __i386__
// objc_msgSend has few registers available.
// Cache scan increments and wraps at special end-marking bucket.
#define CACHE_END_MARKER 1

// 返回指定索引与 mask 再做 & 运算后的索引，
// 这是不是相当于在做 “再哈希” 的操作，这样规避了 hash 后值冲突的问题
static inline mask_t cache_next(mask_t i, mask_t mask) {
    return (i+1) & mask;
}

#elif __arm64__ // iphone 真机
// objc_msgSend has lots of registers available.
// Cache scan decrements. No end marker needed.
#define CACHE_END_MARKER 0
// 和上面的 cache_next 情况不一样，这个版本的 cache_next 直接返回前一个索引 i-1 ，
// 没有与 mask 再做 & 运算
static inline mask_t cache_next(mask_t i, mask_t mask) {
    return i ? i-1 : mask;
}

#else
#error unknown architecture
#endif


#if SUPPORT_IGNORED_SELECTOR_CONSTANT
#error sorry not implemented
#endif


// copied from dispatch_atomic_maximally_synchronizing_barrier
// fixme verify that this barrier hack does in fact work here
#if __x86_64__
#define mega_barrier() \
    do { unsigned long _clbr; __asm__ __volatile__( \
        "cpuid" \
        : "=a" (_clbr) : "0" (0) : "rbx", "rcx", "rdx", "cc", "memory" \
                                                    ); } while(0)

#elif __i386__
#define mega_barrier() \
    do { unsigned long _clbr; __asm__ __volatile__( \
        "cpuid" \
        : "=a" (_clbr) : "0" (0) : "ebx", "ecx", "edx", "cc", "memory" \
                                                    ); } while(0)

#elif __arm__  ||  __arm64__
#define mega_barrier() \
    __asm__ __volatile__( \
        "dsb    ish" \
        : : : "memory")

#else
#error unknown architecture
#endif

#if __arm64__

// Use atomic double-word instructions to update cache entries.
// This requires cache buckets not cross cache line boundaries.

// 用汇编同时修改 destp 对象中的 onep 和 twop 两个变量
// 整个过程是原子性的，两个变量要么都是旧的，要么都是新的，不会一新一旧
#define stp(onep, twop, destp)                  \
    __asm__ ("stp %[one], %[two], [%[dest]]"    \
             : "=m" (((uint64_t *)(destp))[0]), \   // ((uint64_t *)(destp))[0] 正好就是 bucket_t 中 _key 的位置
               "=m" (((uint64_t *)(destp))[1])  \   // ((uint64_t *)(destp))[1] 正好就是 bucket_t 中 _imp 的位置
             : [one] "r" (onep),                \
               [two] "r" (twop),                \
               [dest] "r" (destp)               \
             : /* no clobbers */                \
             )
#define ldp(onep, twop, srcp)                   \
    __asm__ ("ldp %[one], %[two], [%[src]]"     \
             : [one] "=r" (onep),               \
               [two] "=r" (twop)                \
             : "m" (((uint64_t *)(srcp))[0]),   \
               "m" (((uint64_t *)(srcp))[1]),   \
               [src] "r" (srcp)                 \
             : /* no clobbers */                \
             )

#endif


// Class points to cache. SEL is key. Cache buckets store SEL+IMP.
// Caches are never built in the dyld shared cache.
// 对 key 进行 Hash，返回的是 key 在 _buckets 中的索引
static inline mask_t cache_hash(cache_key_t key, mask_t mask) 
{
    // 只是简单的位 & 运算
    // 因为 _mask = 容量 - 1; 且值都是 0b11  0b111  0b1111  0b11111 这样的数
    // 所以 & 运算之后，取得的索引绝对不会超过 cache 总的容量
    return (mask_t)(key & mask);
}

// 获得指定的 class 中的缓存 cache
cache_t *getCache(Class cls) 
{
    assert(cls);
    return &cls->cache;
}

// key 只不过是 (cache_key_t)sel 将 sel 强转为 cache_key_t 类型
// 如果 SEL 也就是 objc_select 本质上是一个 char * 字符串
// 都是内存地址，强转没有问题
cache_key_t getKey(SEL sel)
{
    assert(sel);
    return (cache_key_t)sel;
}

#if __arm64__  // iphone 都是 arm64 的

// 同时设置 key 和 imp
void bucket_t::set(cache_key_t newKey, IMP newImp)
{
    assert(_key == 0  ||  _key == newKey);

    // LDP/STP guarantees（保证） that all observers get
    // either key/imp or newKey/newImp
    
    // stp 能保证所有的观察者得到的都是 key/imp 或者 newKey/newImp
    // 也就是说 key - value 键值对应是正确的，而不会新键对应的是旧值
    // stp 的声明在本文件内，上面不远处，仔细找
    stp(newKey, newImp, this);
}

#else  // 这个应该是模拟器用的

void bucket_t::set(cache_key_t newKey, IMP newImp)
{
    assert(_key == 0  ||  _key == newKey);

    // objc_msgSend uses key and imp with no locks.
    // It is safe for objc_msgSend to see new imp but NULL key
    // (It will get a cache miss but not dispatch to the wrong place.)
    // It is unsafe for objc_msgSend to see old imp and new key.
    // Therefore we write new imp, wait a lot, then write new key.
    
    _imp = newImp;
    
    if (_key != newKey) {
        mega_barrier();
        _key = newKey;
    }
}

#endif

// 设置存储的 buckets 和 mask
void cache_t::setBucketsAndMask(struct bucket_t *newBuckets, mask_t newMask)
{
    // objc_msgSend uses mask and buckets with no locks.
    // It is safe for objc_msgSend to see new buckets but old mask.
    // (It will get a cache miss but not overrun the buckets' bounds).
    // It is unsafe for objc_msgSend to see old buckets and new mask.
    // Therefore we write new buckets, wait a lot, then write new mask.
    // objc_msgSend reads mask first, then buckets.

    // ensure other threads see buckets contents before buckets pointer
    mega_barrier();
    
    // mega_barrier 看不懂

    _buckets = newBuckets;
    
    // ensure other threads see new buckets before new mask
    mega_barrier();
    
    _mask = newMask;
    _occupied = 0;
}

// 取得 cache_t 存的所有 buckets
struct bucket_t *cache_t::buckets() 
{
    return _buckets; 
}

// 取得 _mask
mask_t cache_t::mask() 
{
    return _mask; 
}

// 取得 _occupied
mask_t cache_t::occupied() 
{
    return _occupied;
}

// _occupied 加 1
void cache_t::incrementOccupied() 
{
    _occupied++;
}

// 初始化得到一个空的 cache，结构体里所有 bit 都置为 0
void cache_t::initializeToEmpty()
{
    bzero(this, sizeof(*this));
    _buckets = (bucket_t *)&_objc_empty_cache;
}

// 取得容量，因为 _mask = 容量 - 1，所以 容量 = _mask + 1
mask_t cache_t::capacity() 
{
    return mask() ? mask()+1 : 0; 
}


#if CACHE_END_MARKER  // 模拟器

// 取得指定容量所需的内存大小
// 因为有 END_MARKER，所以 cap + 1
size_t cache_t::bytesForCapacity(uint32_t cap) 
{
    // fixme put end marker inline when capacity+1 malloc is inefficient
    return sizeof(bucket_t) * (cap + 1);
}

// 取得 end marker
bucket_t *cache_t::endMarker(struct bucket_t *b, uint32_t cap) 
{
    // bytesForCapacity() chooses whether the end marker is inline or not
    // (uintptr_t)b + bytesForCapacity(cap) 移到 buckets 数组的末尾地址，
    // 然后向前一个单位，就是 end marker 的起始地址
    return (bucket_t *)((uintptr_t)b + bytesForCapacity(cap)) - 1;
}

// 开辟指定容量的 bucket 数组
bucket_t *allocateBuckets(mask_t newCapacity)
{
    // Allocate one extra bucket to mark the end of the list.
    // This can't overflow mask_t because newCapacity is a power of 2.
    // fixme instead put the end mark inline when +1 is malloc-inefficient
    
    // 为新的 bucket 数组在堆中开辟内存，
    // cache_t::bytesForCapacity(newCapacity) 个长度为 1 的连续空间
    bucket_t *newBuckets = (bucket_t *)
        calloc(cache_t::bytesForCapacity(newCapacity), 1);

    // 取得 endMarker，但这时 endMarker 中是空的，没有值
    // 后面会给它赋值
    bucket_t *end = cache_t::endMarker(newBuckets, newCapacity);

#if __arm__
    // End marker's key is 1 and imp points BEFORE the first bucket.
    // This saves an instruction（指令） in objc_msgSend.
    end->setKey((cache_key_t)(uintptr_t)1);
    end->setImp((IMP)(newBuckets - 1));
#else
    // End marker's key is 1 and imp points to the first bucket.
    end->setKey((cache_key_t)(uintptr_t)1);
    end->setImp((IMP)newBuckets);
#endif
    
    if (PrintCaches) recordNewCache(newCapacity);

    return newBuckets;
}

#else  // iphone 真机

// 取得指定容量所需的内存大小
// 因为没有 END_MARKER，所以是 cap
size_t cache_t::bytesForCapacity(uint32_t cap) 
{
    return sizeof(bucket_t) * cap;
}

// 开辟指定容量的 bucket 数组
bucket_t *allocateBuckets(mask_t newCapacity)
{
    if (PrintCaches) recordNewCache(newCapacity);

    // 为新的 bucket 数组在堆中开辟内存，
    // cache_t::bytesForCapacity(newCapacity) 个长度为 1 的连续空间
    return (bucket_t *)calloc(cache_t::bytesForCapacity(newCapacity), 1);
}

#endif

// 取得容量为 capacity 的空 bucket_t 数组
// 这个数组是只读的，真正存数据时，会重新开辟空间
// 这个数组只在比较的时候用，或者在 cache_erase_nolock() 中有用到
bucket_t *emptyBucketsForCapacity(mask_t capacity, bool allocate = true)
{
    // 判断 cacheUpdateLock 有没有被正确地加锁
    cacheUpdateLock.assertLocked();

    // 计算指定的容量所需要的内存大小
    size_t bytes = cache_t::bytesForCapacity(capacity);

    // Use _objc_empty_cache if the buckets is small enough.
    // 如果 bytes 足够小，直接返回 _objc_empty_cache
    if (bytes <= EMPTY_BYTES) {
        return (bucket_t *)&_objc_empty_cache;
    }

    // Use shared empty buckets allocated on the heap.
    // 一个二维数组，数组中的元素是装了空的bucket的数组
    // 并且是全局的，也就是一个全局的、堆上的装了空 bucket 数组的地址的数组
    static bucket_t **emptyBucketsList = nil;
    // emptyBucketsList 数组中元素的个数
    static mask_t emptyBucketsListCount = 0;
    
    // index = log2(capacity) 取下限
    // 为什么这样呢，我猜是 capacity 本身就必须是 2 的幂次
    // capacity 的值是序列  4(INIT_CACHE_SIZE), 8, 16, 32, 64, 128 ...
    // log2(capacity) 的值也只能是  2, 3, 4, 5, 6, 7 ...
    // 那么，只有 cache 进行扩容时，才需要改 emptyBucketsList
    mask_t index = log2u(capacity);

    // 1. 第一次执行到这里的时候，因为 emptyBucketsListCount == 0，所以 if 里一定会走
    // 2. 以后，走到这，如果给的 capacity 太大， index >= emptyBucketsListCount
    //    也就是给的索引超过 emptyBucketsList 的 count，也必须重新给 emptyBucketsList 分配
    //    更大的内存，更大的长度
    if (index >= emptyBucketsListCount) {
        // 如果指定不 allocate，就返回 nil
        if (!allocate) return nil;
        
        // 新的列表的数量，也就是 emptyBucketsList 的新的元素个数
        mask_t newListCount = index + 1;
        
        // 在堆中开辟指定容量 capacity 所需要的内存， bytes 个长度为 1 的连续空间
        bucket_t *newBuckets = (bucket_t *)calloc(bytes, 1);
        
        // 给 emptyBucketsList 在堆中开辟内存，开辟了 newListCount 个 bucket_t *
        // realloc: 先判断当前的指针是否有足够的连续空间，如果有，扩大mem_address指向的地址，并且将mem_address返回，如果空间不够，先按照newsize指定的大小分配空间，将原有数据从头到尾拷贝到新分配的内存区域，而后释放原来mem_address所指内存区域（注意：原来指针是自动释放，不需要使用free），同时返回新分配的内存区域的首地址。即重新分配存储器块的地址。
        // realloc 中会将原来的数据也拷贝过来，所以原来数组中原来保存的 bucket 数组的地址没有丢
        emptyBucketsList = (bucket_t**)
            realloc(emptyBucketsList, newListCount * sizeof(bucket_t *));
        
        // Share newBuckets for every un-allocated size smaller than index.
        // The array is therefore always fully populated.
        // 分享 newBuckets 给每一个比 index 小的 un-allocated size
        // 因此，emptyBucketsList 数组中一直是满的
        
        // emptyBucketsList 数组中自 emptyBucketsListCount 开始到 newListCount 索引中每个元素记录的都用 newBuckets 填充
        // 这样解决了一种情况，就是第一次进入这个函数时，这时 emptyBucketsListCount = 0，而 index 最小等于 2 （原因见上面），那么就需要填充 0、1、2 三个位置
        // 如此，把 0 和 1 索引处的也填上了，保证了所有位置永远都是满的
        for (mask_t i = emptyBucketsListCount; i < newListCount; i++) {
            // 存的只是数组的地址，只是一个地址
            emptyBucketsList[i] = newBuckets;
        }
        
        // 再提一句，因为 emptyBucketsList 数组中的每个元素都不会被改变，进来一个新元素，就会一直保持到进程结束，原来的元素也不会被影响，所以不存在需要释放内存的情况，进程结束时，堆栈会自动被回收
        
        // 记录下新的元素数量
        emptyBucketsListCount = newListCount;

        if (PrintCaches) {
            _objc_inform("CACHES: new empty buckets at %p (capacity %zu)", 
                         newBuckets, (size_t)capacity);
        }
    }
    
    // 返回 index 索引处存的空 bucket 数组
    return emptyBucketsList[index];
}

// 判断 buckets 自从初次创建后是否被用过，
// 被用过的话，占用会 > 0，因为不会从 _buckets 中删除某个 bucket，只增不减的，除非 _buckets 被完全清空
// 被用过的话，会在 cache_fill_nolock() 函数中调用 reallocate 方法重新分配空间
// 所以与 emptyBucketsForCapacity() 取得的同样容量的空的只读的 bucket 数组的 地址 肯定不一样
bool cache_t::isConstantEmptyCache()
{
    return occupied() == 0  &&
           buckets() == emptyBucketsForCapacity(capacity(), false);
}

// 判断是否需要释放旧的 _buckets 内存
bool cache_t::canBeFreed()
{
    // 如果 _buckets 没被用过，就不需要释放，
    // 因为 emptyBucketsForCapacity() 中的空 bucket 数组是只读的，不能存数据，更不能释放
    // 反之需要释放
    return !isConstantEmptyCache();
}

// 为 _buckets 在堆中重新分配适应更大容量的内存区域
// 如果可以的话，将老的 _buckets 放入垃圾桶
void cache_t::reallocate(mask_t oldCapacity, mask_t newCapacity)
{
    // 是否需要释放旧的 buckets
    bool freeOld = canBeFreed();

    // 记录一下旧的 bucket 数组
    bucket_t *oldBuckets = buckets();
    // 创建一个容量为 newCapacity 的 bucket 数组，这块内存是真正拿来放数据的
    bucket_t *newBuckets = allocateBuckets(newCapacity);

    // Cache's old contents are not propagated. 
    // This is thought to save cache memory at the cost of extra cache fills.
    // fixme re-measure this

    assert(newCapacity > 0);
    assert((uintptr_t)(mask_t)(newCapacity-1) == newCapacity-1);

    // 将新的 bucket 数组赋给成员变量 _buckets
    // 新的 _mask 是 newCapacity - 1
    // 占用 _occupied 也重置为 0
    setBucketsAndMask(newBuckets, newCapacity - 1);
    
    // 那问题来了，难道老的 bucket 数组里的 bucket 就全没了？？？
    // 不拷贝到新的 bucket 数组 ？？？
    // 看来看去，好像真的没有做这步，可能是 _mask 变了，即使拷贝了，cache_hash() 函数中，
    // 用新的 _mask 进行 hash 时，拿到的 key 也是错的，索性全都不要了，重新缓存
    
    // 如果需要释放
    if (freeOld) {
        // 将旧的 bucket 数组放进垃圾桶
        cache_collect_free(oldBuckets, oldCapacity);
        // 尝试清空垃圾桶，并不一定会清空，只有在垃圾桶中垃圾足够多的时候，才会一次性清空
        // 参数 false 是不指定强制清空
        cache_collect(false);
    }
}

// cache 出现错误，打印错误信息，然后程序挂掉
// receiver 是 isa 类的一个实例
void cache_t::bad_cache(id receiver, SEL sel, Class isa)
{
    // Log in separate steps in case the logging itself causes a crash.
    _objc_inform_now_and_on_crash
        ("Method cache corrupted. This may be a message to an "
         "invalid object, or a memory error somewhere else.");
    cache_t *cache = &isa->cache;
    _objc_inform_now_and_on_crash
        ("%s %p, SEL %p, isa %p, cache %p, buckets %p, "
         "mask 0x%x, occupied 0x%x", 
         receiver ? "receiver" : "unused", receiver, 
         sel, isa, cache, cache->_buckets, 
         cache->_mask, cache->_occupied);
    _objc_inform_now_and_on_crash
        ("%s %zu bytes, buckets %zu bytes", 
         receiver ? "receiver" : "unused", malloc_size(receiver), 
         malloc_size(cache->_buckets));
    _objc_inform_now_and_on_crash
        ("selector '%s'", sel_getName(sel));
    _objc_inform_now_and_on_crash
        ("isa '%s'", isa->nameForLogging());
    _objc_fatal
        ("Method cache corrupted.");
}

// _buckets 数组中存入新的 bucket 时，寻找第一个没有用过的 bucket (就是空的 bucket，b[i].key() == 0)
// 或者命中 key 的 bucket (b[i].key() == k) 
// 如果没有找到，就调用 bad_cache 打印错误信息，然后程序挂掉
// receiver 是 这个被缓存的方法所在的类或其子类的一个实例，感觉没啥用，是在 bad_cache 中打印错误信息时用过
// 这个方法只在 cache_fill_nolock() 函数中被调用
bucket_t * cache_t::find(cache_key_t k, id receiver)
{
    assert(k != 0);

    // 取得存 bucket 的数组 _buckets
    bucket_t *b = buckets();
    // m = 容量 - 1
    mask_t m = mask();
    // 对传入的键进行 hash，返回的是索引，可能就是这样确定索引的，起到了字典的作用
    // 有意思的是，_mask = 容量 - 1
    // 那么 _mask 的值都是 0b11  0b111  0b1111  0b11111 这样的数
    mask_t begin = cache_hash(k, m);
    mask_t i = begin;
    do {
        // 如果 b[i].key() == 0 也就是找到了一个空的 bucket
        // 或者 如果 b[i].key() == k 也就是命中了
        // 都返回这个 bucket
        if (b[i].key() == 0  ||  b[i].key() == k) {
            return &b[i];
        }
    } while ((i = cache_next(i, m)) != begin); // 再 hash 一次

    // 如果找不到合适的缓存位置，就往下走，bad_cache 会打印出错误信息
    
    // hack
    // 这个吊，根据当前的 cache 对象，减去成员变量 cache 位于所在类 objc_class 的偏移量
    // 就得到了当前 cache 对象所在的 objc_class 类对象
    Class cls = (Class)((uintptr_t)this - offsetof(objc_class, cache));
    cache_t::bad_cache(receiver, (SEL)k, cls);
}

// 扩容
void cache_t::expand()
{
    // 判断 cacheUpdateLock 有没有被正确地加锁
    cacheUpdateLock.assertLocked();
    
    // 取得老的容量
    uint32_t oldCapacity = capacity();
    // 容量加倍，如果原来容量是0，就初始化为 INIT_CACHE_SIZE，就是 4
    uint32_t newCapacity = oldCapacity ? oldCapacity*2 : INIT_CACHE_SIZE;

    // 如果 mask 溢出了，就不能继续扩容了，重置为原来的容量
    if ((uint32_t)(mask_t)newCapacity != newCapacity) {
        // mask overflow - can't grow further
        // fixme this wastes one bit of mask
        newCapacity = oldCapacity;
    }

    // 为 _buckets 在堆中重新分配适应更大容量的内存区域
    reallocate(oldCapacity, newCapacity);
}

#pragma mark - objc-cache.h 中声明的方法

// 静态方法，保证不出现在全局的函数表
// 填充 cache，也就是将 sel(key)/imp 组成 bucket，存入 cache 中的 _buckets 数组
// 因为这个函数没有中没有加 互斥锁 mutex，所以叫 nolock
// 而 cache_fill() 中是加了锁的
// receiver 是 cls 类或者其子类的一个实例
static void cache_fill_nolock(Class cls, SEL sel, IMP imp, id receiver)
{
    // 判断 cacheUpdateLock 有没有被正确地加锁
    cacheUpdateLock.assertLocked();

    // Never cache before +initialize is done
    // 如果类还没有被 initialize 过，就直接返回
    if (!cls->isInitialized()) {
        return;
    }

    // Make sure the entry wasn't added to the cache by some other thread 
    // before we grabbed the cacheUpdateLock.
    // 如果 sel 已经被放进了 cls 类的缓存中，就不必再放了，直接返回
    if (cache_getImp(cls, sel)) {
        return;
    }

    // 取得 cls 中的 cache 成员变量
    cache_t *cache = getCache(cls);
    // 将 sel 转为 key，其实 SEL 本质上就是 char * 字符串，做个强制类型转换就好了
    cache_key_t key = getKey(sel);

    // Use the cache as-is if it is less than 3/4 full
    // 缓存中多了一个 bucket，那么新的占用等于 cache->occupied() + 1
    // newOccupied 只用来比较查看占用量是否超过阈值
    // 并没有存进成员变量 _occupied
    mask_t newOccupied = cache->occupied() + 1;
    // 取得容量，看够不够用
    mask_t capacity = cache->capacity();
    
    // 如果 _buckets 还是 emptyBucketsForCapacity() 那里得到的只读的空 buckets 数组
    // 不能向其中写数据，它只是一个只读的，拿来看看的空数组
    // 所以需要重新开辟一块同样容量的新的 bucket 数组
    if (cache->isConstantEmptyCache()) {
        // Cache is read-only. Replace it.
        cache->reallocate(capacity, capacity ?: INIT_CACHE_SIZE);
    }
    else if (newOccupied <= capacity / 4 * 3) { // 容量还够，就啥事儿都不干
        // Cache is less than 3/4 full. Use it as-is.
    }
    else { // 容量不够了，扩容
        // Cache is too full. Expand it.
        cache->expand();
    }

    // Scan for the first unused slot and insert there.
    // There is guaranteed to be（保证） an empty slot because the
    // minimum size is 4 and we resized at 3/4 full.
    
    // 找到第一个没有用的位置，并将新的 bucket 放在那儿
    // 保证会有一个空位置，因为 cache 最小的容量是 4 ，并且占用不能超过 3/4
    bucket_t *bucket = cache->find(key, receiver);
    
    // 如果这个 bucket 是空的，就将占用 +1
    if (bucket->key() == 0) {
        cache->incrementOccupied();
    }
    // 将 key 和 imp 对存进这个 bucket 中
    bucket->set(key, imp);
}

// 填充 cache，也就是将 sel(key)/imp 组成 bucket，存入 cache 中的 _buckets 数组
// receiver 是 cls 类或者其子类的一个实例
void cache_fill(Class cls, SEL sel, IMP imp, id receiver)
{
#if !DEBUG_TASK_THREADS
    // 互斥锁
    mutex_locker_t lock(cacheUpdateLock);
    // 调用 cache_fill_nolock 做真正填充的工作
    cache_fill_nolock(cls, sel, imp, receiver);
#else
    _collecting_in_critical();
    return;
#endif
}


// Reset this entire cache to the uncached lookup by reallocating it.
// This must not shrink the cache - that breaks the lock-free scheme.
// 清空指定 class 的缓存，但不缩小容量
void cache_erase_nolock(Class cls)
{
    // 判断 cacheUpdateLock 有没有被正确地加锁
    cacheUpdateLock.assertLocked();

    // 取出 cls 的缓存
    cache_t *cache = getCache(cls);

    // 取出缓存的容量
    mask_t capacity = cache->capacity();
    
    // 如果有缓存被占用，也就是说缓存里有东西，才清空，不然都没必要清空
    if (capacity > 0  &&  cache->occupied() > 0) {
        // 先取得老的 buckets，留着后面放入垃圾桶
        auto oldBuckets = cache->buckets();
        // 取得一个指定容量的空的 bucket 数组
        // 它是只读的，在 cache_fill_nolock() 函数中，真正存数据时，会重新在堆中开辟空间
        auto buckets = emptyBucketsForCapacity(capacity);
        // 将 cache 中的 _buckets 替换为新的空的 bucket 数组
        // capacity - 1 是因为 _mask = capacity - 1
        cache->setBucketsAndMask(buckets, capacity - 1); // also clears occupied

        // 将老的 buckets 放入垃圾桶
        cache_collect_free(oldBuckets, capacity);
        // 尝试清空垃圾桶
        cache_collect(false);
    }
}

// 删除指定 class 的缓存，也就是将 _buckets 的内存释放掉
void cache_delete(Class cls)
{
    mutex_locker_t lock(cacheUpdateLock);
    // 只有 _buckets 不是空的，没有占用，才能被释放
    if (cls->cache.canBeFreed()) {
        // 打印用，不用管
        if (PrintCaches) {
            recordDeadCache(cls->cache.capacity());
        }
        // 释放 _buckets 的内存，因为是在堆中分配的，所以需要 free
        free(cls->cache.buckets());
    }
}


/***********************************************************************
* cache collection.
**********************************************************************/

#if !TARGET_OS_WIN32

// A sentinel (magic value) to report bad thread_get_state status.
// Must not be a valid PC.
// Must not be zero - thread_get_state() on a new thread returns PC == 0.
#define PC_SENTINEL  1

static uintptr_t _get_pc_for_thread(thread_t thread)
#if defined(__i386__)
{
    i386_thread_state_t state;
    unsigned int count = i386_THREAD_STATE_COUNT;
    kern_return_t okay = thread_get_state (thread, i386_THREAD_STATE, (thread_state_t)&state, &count);
    return (okay == KERN_SUCCESS) ? state.__eip : PC_SENTINEL;
}
#elif defined(__x86_64__)
{
    x86_thread_state64_t			state;
    unsigned int count = x86_THREAD_STATE64_COUNT;
    kern_return_t okay = thread_get_state (thread, x86_THREAD_STATE64, (thread_state_t)&state, &count);
    return (okay == KERN_SUCCESS) ? state.__rip : PC_SENTINEL;
}
#elif defined(__arm__)
{
    arm_thread_state_t state;
    unsigned int count = ARM_THREAD_STATE_COUNT;
    kern_return_t okay = thread_get_state (thread, ARM_THREAD_STATE, (thread_state_t)&state, &count);
    return (okay == KERN_SUCCESS) ? state.__pc : PC_SENTINEL;
}
#elif defined(__arm64__)
{
    arm_thread_state64_t state;
    unsigned int count = ARM_THREAD_STATE64_COUNT;
    kern_return_t okay = thread_get_state (thread, ARM_THREAD_STATE64, (thread_state_t)&state, &count);
    return (okay == KERN_SUCCESS) ? state.__pc : PC_SENTINEL;
}
#else
{
#error _get_pc_for_thread () not implemented for this architecture
}
#endif

#endif

/***********************************************************************
* _collecting_in_critical.
* Returns TRUE if some thread is currently executing a cache-reading 
* function. Collection of cache garbage is not allowed when a cache-
* reading function is in progress because it might still be using 
* the garbage memory.
**********************************************************************/
OBJC_EXPORT uintptr_t objc_entryPoints[];
OBJC_EXPORT uintptr_t objc_exitPoints[];

// 垃圾桶里的 cache 是否有在临界区
// 如果 _collecting_in_critical 返回 true，
// 就说明某些线程上的 cache-reading 的函数正在执行
// 这个时候不能不能清空垃圾桶，因为可能这些 cache-reading 的函数正在用垃圾桶里的 cache

// 下面这个解释来自顶部 apple 的注释：
// _collecting_in_critical() 检查所有的线程的 PC，当所有线程都没有执行 objc_msgSend 时返回 false。这意味着任何所有的objc_msgSend 对垃圾桶里的这块内存的访问都结束了，或者已经不在缓存查找的阶段了（反正就是老缓存彻彻底底的没用了），现在释放老的缓存就是安全的了
static int _collecting_in_critical(void)
{
#if TARGET_OS_WIN32
    return TRUE;
#else
    thread_act_port_array_t threads;
    unsigned number;
    unsigned count;
    kern_return_t ret;
    int result;

    mach_port_t mythread = pthread_mach_thread_np(pthread_self());

    // Get a list of all the threads in the current task
#if !DEBUG_TASK_THREADS
    ret = task_threads(mach_task_self(), &threads, &number);
#else
    ret = objc_task_threads(mach_task_self(), &threads, &number);
#endif

    if (ret != KERN_SUCCESS) {
        // See DEBUG_TASK_THREADS below to help debug this.
        _objc_fatal("task_threads failed (result 0x%x)\n", ret);
    }

    // Check whether any thread is in the cache lookup code
    result = FALSE;
    for (count = 0; count < number; count++)
    {
        int region;
        uintptr_t pc;

        // Don't bother checking ourselves
        if (threads[count] == mythread)
            continue;

        // Find out where thread is executing
        pc = _get_pc_for_thread (threads[count]);

        // Check for bad status, and if so, assume the worse (can't collect)
        if (pc == PC_SENTINEL)
        {
            result = TRUE;
            goto done;
        }
        
        // Check whether it is in the cache lookup code
        for (region = 0; objc_entryPoints[region] != 0; region++)
        {
            if ((pc >= objc_entryPoints[region]) &&
                (pc <= objc_exitPoints[region])) 
            {
                result = TRUE;
                goto done;
            }
        }
    }

 done:
    // Deallocate the port rights for the threads
    for (count = 0; count < number; count++) {
        mach_port_deallocate(mach_task_self (), threads[count]);
    }

    // Deallocate the thread list
    vm_deallocate (mach_task_self (), (vm_address_t) threads, sizeof(threads[0]) * number);

    // Return our finding
    return result;
#endif
}


/***********************************************************************
* _garbage_make_room.  Ensure that there is enough room for at least
* one more ref in the garbage.
**********************************************************************/

// amount of memory represented by all refs in the garbage
// 垃圾桶中垃圾的内存大小，计算的是 bucket 数组的总的内存大小，不是垃圾桶里存的指针的大小
static size_t garbage_byte_size = 0;

// do not empty the garbage until garbage_byte_size gets at least this big
// 直到垃圾达到至少阈值大小，才清空垃圾
static size_t garbage_threshold = 32*1024;

// table of refs to free
// 垃圾桶，里面存的元素是 buctet 数组的地址
static bucket_t **garbage_refs = 0;

// current number of refs in garbage_refs
// 当前垃圾桶里 bucket 的数量
static size_t garbage_count = 0;

// capacity of current garbage_refs
// 当前垃圾桶的容量
static size_t garbage_max = 0;

// capacity of initial garbage_refs
// 垃圾桶的初始容量
enum {
    INIT_GARBAGE_COUNT = 128
};

// 确保垃圾桶有空间，如果满了就扩容
static void _garbage_make_room(void)
{
    static int first = 1;

    // 是否是第一次用垃圾桶，第一次用的话，就要初始化垃圾桶
    // Create the collection table the first time it is needed
    if (first)
    {
        first = 0;
        // 初始化垃圾桶，在堆中为其分配内存
        // INIT_GARBAGE_COUNT 是初始的垃圾桶的容量
        // 因为垃圾桶里存的都只是 bucket 的地址，所以用 sizeof(void *)
        garbage_refs = (bucket_t**)
            malloc(INIT_GARBAGE_COUNT * sizeof(void *));
        
        // 容量初始化为 INIT_GARBAGE_COUNT
        garbage_max = INIT_GARBAGE_COUNT;
    }

    // Double the table if it is full
    // 如果垃圾桶满了
    else if (garbage_count == garbage_max)
    {
        // 给垃圾桶扩容到原来的 2 倍
        
        // realloc: 先判断当前的指针是否有足够的连续空间，如果有，扩大mem_address指向的地址，并且将mem_address返回，如果空间不够，先按照newsize指定的大小分配空间，将原有数据从头到尾拷贝到新分配的内存区域，而后释放原来mem_address所指内存区域（注意：原来指针是自动释放，不需要使用free），同时返回新分配的内存区域的首地址。即重新分配存储器块的地址。
        
        // 注意：因为会拷贝原有数据，所以垃圾桶里原来的数据没丢
        garbage_refs = (bucket_t**)
            realloc(garbage_refs, garbage_max * 2 * sizeof(void *));
        // 最大容量也扩大为 2 倍
        garbage_max *= 2;
    }
}


/***********************************************************************
* cache_collect_free.  Add the specified malloc'd memory to the list
* of them to free at some later point.
* size is used for the collection threshold. It does not have to be 
* precisely the block's size.
* Cache locks: cacheUpdateLock must be held by the caller.
**********************************************************************/
// 将指定的 bucket 数组放进垃圾桶
static void cache_collect_free(bucket_t *data, mask_t capacity)
{
    // 判断 cacheUpdateLock 有没有被正确地加锁
    cacheUpdateLock.assertLocked();

    if (PrintCaches) {
        recordDeadCache(capacity);
    }

    // 确保垃圾桶有空间
    _garbage_make_room ();
    // 垃圾桶中垃圾的内存大小 加上 data 的内存大小
    garbage_byte_size += cache_t::bytesForCapacity(capacity);
    // 将 data 存进垃圾桶中
    garbage_refs[garbage_count++] = data;
}


/***********************************************************************
* cache_collect.  Try to free accumulated dead caches.
* collectALot tries harder to free memory.
* Cache locks: cacheUpdateLock must be held by the caller.
**********************************************************************/
// 清空垃圾桶，参数 collectALot 是是否强制地释放内存
void cache_collect(bool collectALot)
{
    // 判断 cacheUpdateLock 有没有被正确地加锁
    cacheUpdateLock.assertLocked();

    // Done if the garbage is not full
    // 垃圾桶里垃圾太少了，并且指定没有指定强制清空垃圾桶
    if (garbage_byte_size < garbage_threshold  &&  !collectALot) {
        return;
    }

    // Synchronize collection with objc_msgSend and other cache readers
    // 没有指定强制释放内存
    if (!collectALot) {
        // 如果 _collecting_in_critical 返回 true，
        // 就说明 objc_msgSend 正在进行 或者其他 cache readers 正在读 cache
        // 这个时候不能释放内存，就直接返回了
        if (_collecting_in_critical ()) {
            // objc_msgSend (or other cache reader) is currently looking in
            // the cache and might still be using some garbage.
            if (PrintCaches) {
                _objc_inform ("CACHES: not collecting; "
                              "objc_msgSend in progress");
            }
            return;
        }
    } 
    else {
        // No excuses.
        // 一直循环，直到 _collecting_in_critical 返回 false
        // 就是一直等待到可以释放内存的时候
        while (_collecting_in_critical()) 
            ;
    }

    // No cache readers in progress - garbage is now deletable
  
    // 没有 cache readers 在工作，可以清空垃圾桶了
    
    // Log our progress
    if (PrintCaches) {
        cache_collections++;
        _objc_inform ("CACHES: COLLECTING %zu bytes (%zu allocations, %zu collections)", garbage_byte_size, cache_allocations, cache_collections);
    }
    
    // Dispose all refs now in the garbage
    // 逐个释放垃圾桶里的 bucket 数组
    while (garbage_count--) {
        free(garbage_refs[garbage_count]);
    }
    
    // Clear the garbage count and total size indicator
    garbage_count = 0;  // 垃圾总数清零
    garbage_byte_size = 0;  // 垃圾总大小清零

    // 下面是调试时打印一些信息，完全不用看
    if (PrintCaches) {
        size_t i;
        size_t total_count = 0;
        size_t total_size = 0;

        for (i = 0; i < countof(cache_counts); i++) {
            int count = cache_counts[i];
            int slots = 1 << i;
            size_t size = count * slots * sizeof(bucket_t);

            if (!count) continue;

            _objc_inform("CACHES: %4d slots: %4d caches, %6zu bytes", 
                         slots, count, size);

            total_count += count;
            total_size += size;
        }

        _objc_inform("CACHES:      total: %4zu caches, %6zu bytes", 
                     total_count, total_size);
    }
}


/***********************************************************************
* objc_task_threads
* Replacement for task_threads(). Define DEBUG_TASK_THREADS to debug 
* crashes when task_threads() is failing.
*
* A failure in task_threads() usually means somebody has botched their 
* Mach or MIG traffic. For example, somebody's error handling was wrong 
* and they left a message queued on the MIG reply port for task_threads() 
* to trip over.
*
* The code below is a modified version of task_threads(). It logs 
* the msgh_id of the reply message. The msgh_id can identify the sender 
* of the message, which can help pinpoint the faulty code.
* DEBUG_TASK_THREADS also calls collecting_in_critical() during every 
* message dispatch, which can increase reproducibility of bugs.
*
* This code can be regenerated by running 
* `mig /usr/include/mach/task.defs`.
**********************************************************************/
#if DEBUG_TASK_THREADS

#include <mach/mach.h>
#include <mach/message.h>
#include <mach/mig.h>

#define __MIG_check__Reply__task_subsystem__ 1
#define mig_internal static inline
#define __DeclareSendRpc(a, b)
#define __BeforeSendRpc(a, b)
#define __AfterSendRpc(a, b)
#define msgh_request_port       msgh_remote_port
#define msgh_reply_port         msgh_local_port

#ifndef __MachMsgErrorWithTimeout
#define __MachMsgErrorWithTimeout(_R_) { \
        switch (_R_) { \
        case MACH_SEND_INVALID_DATA: \
        case MACH_SEND_INVALID_DEST: \
        case MACH_SEND_INVALID_HEADER: \
            mig_put_reply_port(InP->Head.msgh_reply_port); \
            break; \
        case MACH_SEND_TIMED_OUT: \
        case MACH_RCV_TIMED_OUT: \
        default: \
            mig_dealloc_reply_port(InP->Head.msgh_reply_port); \
        } \
    }
#endif  /* __MachMsgErrorWithTimeout */

#ifndef __MachMsgErrorWithoutTimeout
#define __MachMsgErrorWithoutTimeout(_R_) { \
        switch (_R_) { \
        case MACH_SEND_INVALID_DATA: \
        case MACH_SEND_INVALID_DEST: \
        case MACH_SEND_INVALID_HEADER: \
            mig_put_reply_port(InP->Head.msgh_reply_port); \
            break; \
        default: \
            mig_dealloc_reply_port(InP->Head.msgh_reply_port); \
        } \
    }
#endif  /* __MachMsgErrorWithoutTimeout */


#if ( __MigTypeCheck )
#if __MIG_check__Reply__task_subsystem__
#if !defined(__MIG_check__Reply__task_threads_t__defined)
#define __MIG_check__Reply__task_threads_t__defined

mig_internal kern_return_t __MIG_check__Reply__task_threads_t(__Reply__task_threads_t *Out0P)
{

	typedef __Reply__task_threads_t __Reply;
	boolean_t msgh_simple;
#if	__MigTypeCheck
	unsigned int msgh_size;
#endif	/* __MigTypeCheck */
	if (Out0P->Head.msgh_id != 3502) {
	    if (Out0P->Head.msgh_id == MACH_NOTIFY_SEND_ONCE)
		{ return MIG_SERVER_DIED; }
	    else
		{ return MIG_REPLY_MISMATCH; }
	}

	msgh_simple = !(Out0P->Head.msgh_bits & MACH_MSGH_BITS_COMPLEX);
#if	__MigTypeCheck
	msgh_size = Out0P->Head.msgh_size;

	if ((msgh_simple || Out0P->msgh_body.msgh_descriptor_count != 1 ||
	    msgh_size != (mach_msg_size_t)sizeof(__Reply)) &&
	    (!msgh_simple || msgh_size != (mach_msg_size_t)sizeof(mig_reply_error_t) ||
	    ((mig_reply_error_t *)Out0P)->RetCode == KERN_SUCCESS))
		{ return MIG_TYPE_ERROR ; }
#endif	/* __MigTypeCheck */

	if (msgh_simple) {
		return ((mig_reply_error_t *)Out0P)->RetCode;
	}

#if	__MigTypeCheck
	if (Out0P->act_list.type != MACH_MSG_OOL_PORTS_DESCRIPTOR ||
	    Out0P->act_list.disposition != 17) {
		return MIG_TYPE_ERROR;
	}
#endif	/* __MigTypeCheck */

	return MACH_MSG_SUCCESS;
}
#endif /* !defined(__MIG_check__Reply__task_threads_t__defined) */
#endif /* __MIG_check__Reply__task_subsystem__ */
#endif /* ( __MigTypeCheck ) */


/* Routine task_threads */
static kern_return_t objc_task_threads
(
	task_t target_task,
	thread_act_array_t *act_list,
	mach_msg_type_number_t *act_listCnt
)
{

#ifdef  __MigPackStructs
#pragma pack(4)
#endif
	typedef struct {
		mach_msg_header_t Head;
	} Request;
#ifdef  __MigPackStructs
#pragma pack()
#endif

#ifdef  __MigPackStructs
#pragma pack(4)
#endif
	typedef struct {
		mach_msg_header_t Head;
		/* start of the kernel processed data */
		mach_msg_body_t msgh_body;
		mach_msg_ool_ports_descriptor_t act_list;
		/* end of the kernel processed data */
		NDR_record_t NDR;
		mach_msg_type_number_t act_listCnt;
		mach_msg_trailer_t trailer;
	} Reply;
#ifdef  __MigPackStructs
#pragma pack()
#endif

#ifdef  __MigPackStructs
#pragma pack(4)
#endif
	typedef struct {
		mach_msg_header_t Head;
		/* start of the kernel processed data */
		mach_msg_body_t msgh_body;
		mach_msg_ool_ports_descriptor_t act_list;
		/* end of the kernel processed data */
		NDR_record_t NDR;
		mach_msg_type_number_t act_listCnt;
	} __Reply;
#ifdef  __MigPackStructs
#pragma pack()
#endif
	/*
	 * typedef struct {
	 * 	mach_msg_header_t Head;
	 * 	NDR_record_t NDR;
	 * 	kern_return_t RetCode;
	 * } mig_reply_error_t;
	 */

	union {
		Request In;
		Reply Out;
	} Mess;

	Request *InP = &Mess.In;
	Reply *Out0P = &Mess.Out;

	mach_msg_return_t msg_result;

#ifdef	__MIG_check__Reply__task_threads_t__defined
	kern_return_t check_result;
#endif	/* __MIG_check__Reply__task_threads_t__defined */

	__DeclareSendRpc(3402, "task_threads")

	InP->Head.msgh_bits =
		MACH_MSGH_BITS(19, MACH_MSG_TYPE_MAKE_SEND_ONCE);
	/* msgh_size passed as argument */
	InP->Head.msgh_request_port = target_task;
	InP->Head.msgh_reply_port = mig_get_reply_port();
	InP->Head.msgh_id = 3402;

	__BeforeSendRpc(3402, "task_threads")
	msg_result = mach_msg(&InP->Head, MACH_SEND_MSG|MACH_RCV_MSG|MACH_MSG_OPTION_NONE, (mach_msg_size_t)sizeof(Request), (mach_msg_size_t)sizeof(Reply), InP->Head.msgh_reply_port, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
	__AfterSendRpc(3402, "task_threads")
	if (msg_result != MACH_MSG_SUCCESS) {
		_objc_inform("task_threads received unexpected reply msgh_id 0x%zx", 
                             (size_t)Out0P->Head.msgh_id);
		__MachMsgErrorWithoutTimeout(msg_result);
		{ return msg_result; }
	}


#if	defined(__MIG_check__Reply__task_threads_t__defined)
	check_result = __MIG_check__Reply__task_threads_t((__Reply__task_threads_t *)Out0P);
	if (check_result != MACH_MSG_SUCCESS)
		{ return check_result; }
#endif	/* defined(__MIG_check__Reply__task_threads_t__defined) */

	*act_list = (thread_act_array_t)(Out0P->act_list.address);
	*act_listCnt = Out0P->act_listCnt;

	return KERN_SUCCESS;
}

// DEBUG_TASK_THREADS
#endif


// __OBJC2__
#endif
