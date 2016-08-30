/*
 * Copyright (c) 2007 Apple Inc.  All Rights Reserved.
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
* objc-os.h
* OS portability layer.
**********************************************************************/

#ifndef _OBJC_OS_H
#define _OBJC_OS_H

#include <TargetConditionals.h>
#include "objc-config.h"

#ifdef __LP64__ // 64 位系统
#   define WORD_SHIFT 3UL
#   define WORD_MASK 7UL
#   define WORD_BITS 64   // word 是 64 位的
#else
#   define WORD_SHIFT 2UL
#   define WORD_MASK 3UL
#   define WORD_BITS 32   // word 是 32 位的
#endif

// 计算字节对齐后的大小
static inline uint32_t word_align(uint32_t x) {
    return (x + WORD_MASK) & ~WORD_MASK;
}
static inline size_t word_align(size_t x) {
    return (x + WORD_MASK) & ~WORD_MASK;
}


// Mix-in for classes that must not be copied.
// 对象不能被拷贝的类，因为拷贝构造函数和 = 运算符都被删除了（不生成默认版本）
// 函数被删除后，重载该函数也是非法的
class nocopy_t {
  private:
    nocopy_t(const nocopy_t&) = delete;
    const nocopy_t& operator=(const nocopy_t&) = delete;
  protected:
    nocopy_t() { }
    ~nocopy_t() { }
};


#if TARGET_OS_MAC

#   ifndef __STDC_LIMIT_MACROS
#       define __STDC_LIMIT_MACROS
#   endif

#   include <stdio.h>
#   include <stdlib.h>
#   include <stdint.h>
#   include <stdarg.h>
#   include <string.h>
#   include <ctype.h>
#   include <errno.h>
#   include <dlfcn.h>
#   include <fcntl.h>
#   include <assert.h>
#   include <limits.h>
#   include <syslog.h>
#   include <unistd.h>
#   include <pthread.h>
#   include <crt_externs.h>
#   undef check
#   include <Availability.h>
#   include <TargetConditionals.h>
#   include <sys/mman.h>
#   include <sys/time.h>
#   include <sys/stat.h>
#   include <sys/param.h>
#   include <mach/mach.h>
#   include <mach/vm_param.h>
#   include <mach/mach_time.h>
#   include <mach-o/dyld.h>
#   include <mach-o/ldsyms.h>
#   include <mach-o/loader.h>
#   include <mach-o/getsect.h>
#   include <mach-o/dyld_priv.h>
#   include <malloc/malloc.h>
//#   include <os/lock_private.h>
#   include <libkern/OSAtomic.h>
#   include <libkern/OSCacheControl.h>
#   include <System/pthread_machdep.h>
#   include "objc-probes.h"  // generated dtrace probe definitions.

// Some libc functions call objc_msgSend() 
// so we can't use them without deadlocks.
void syslog(int, const char *, ...) UNAVAILABLE_ATTRIBUTE;
void vsyslog(int, const char *, va_list) UNAVAILABLE_ATTRIBUTE;


#define ALWAYS_INLINE inline __attribute__((always_inline))
#define NEVER_INLINE inline __attribute__((noinline))

// 下面这段是后来加的，不是原来就有的 --------------

#include <libkern/OSAtomic.h>

typedef OSSpinLock os_lock_handoff_s;
#define OS_LOCK_HANDOFF_INIT OS_SPINLOCK_INIT

ALWAYS_INLINE void os_lock_lock(volatile os_lock_handoff_s *lock) {
    return OSSpinLockLock(lock);
}

ALWAYS_INLINE void os_lock_unlock(volatile os_lock_handoff_s *lock) {
    return OSSpinLockUnlock(lock);
}

ALWAYS_INLINE bool os_lock_trylock(volatile os_lock_handoff_s *lock) {
    return OSSpinLockTry(lock);
}
// -------------------------------------------

static ALWAYS_INLINE uintptr_t 
addc(uintptr_t lhs, uintptr_t rhs, uintptr_t carryin, uintptr_t *carryout)
{
    return __builtin_addcl(lhs, rhs, carryin, carryout);
}

static ALWAYS_INLINE uintptr_t 
subc(uintptr_t lhs, uintptr_t rhs, uintptr_t carryin, uintptr_t *carryout)
{
    return __builtin_subcl(lhs, rhs, carryin, carryout);
}


#if __arm64__

static ALWAYS_INLINE
uintptr_t 
LoadExclusive(uintptr_t *src)
{
    uintptr_t result;
    asm("ldxr %x0, [%x1]" 
        : "=r" (result) 
        : "r" (src), "m" (*src));
    return result;
}

static ALWAYS_INLINE
bool 
StoreExclusive(uintptr_t *dst, uintptr_t oldvalue __unused, uintptr_t value)
{
    uint32_t result;
    asm("stxr %w0, %x2, [%x3]" 
        : "=r" (result), "=m" (*dst) 
        : "r" (value), "r" (dst));
    return !result;
}


static ALWAYS_INLINE
bool 
StoreReleaseExclusive(uintptr_t *dst, uintptr_t oldvalue __unused, uintptr_t value)
{
    uint32_t result;
    asm("stlxr %w0, %x2, [%x3]" 
        : "=r" (result), "=m" (*dst) 
        : "r" (value), "r" (dst));
    return !result;
}


#elif __arm__  

static ALWAYS_INLINE
uintptr_t 
LoadExclusive(uintptr_t *src)
{
    return *src;
}

static ALWAYS_INLINE
bool 
StoreExclusive(uintptr_t *dst, uintptr_t oldvalue, uintptr_t value)
{
    return OSAtomicCompareAndSwapPtr((void *)oldvalue, (void *)value, 
                                     (void **)dst);
}

static ALWAYS_INLINE
bool 
StoreReleaseExclusive(uintptr_t *dst, uintptr_t oldvalue, uintptr_t value)
{
    return OSAtomicCompareAndSwapPtrBarrier((void *)oldvalue, (void *)value, 
                                            (void **)dst);
}


#elif __x86_64__  ||  __i386__

static ALWAYS_INLINE
uintptr_t 
LoadExclusive(uintptr_t *src)
{
    return *src;
}

static ALWAYS_INLINE
bool 
StoreExclusive(uintptr_t *dst, uintptr_t oldvalue, uintptr_t value)
{
    // __sync_bool_compare_and_swap  是 GCC 内建的原子操作函数， 执行CAS操作，也就是 比较如果相等就swap，并且返回true，否则返回false。所以失败的线程都会进入while循环里去，忙等
    return __sync_bool_compare_and_swap((void **)dst, (void *)oldvalue, (void *)value);
}

static ALWAYS_INLINE
bool 
StoreReleaseExclusive(uintptr_t *dst, uintptr_t oldvalue, uintptr_t value)
{
    return StoreExclusive(dst, oldvalue, value);
}

#else 
#   error unknown architecture
#endif

/*
 自旋锁：
 何谓自旋锁？它是为实现保护共享资源而提出一种锁机制。其实，自旋锁与互斥锁比较类似，它们都是为了解决对某项资源的互斥使用。无论是互斥锁，还是自旋锁，在任何时刻，最多只能有一个保持者，也就说，在任何时刻最多只能有一个执行单元获得锁。但是两者在调度机制上略有不同。对于互斥锁，如果资源已经被占用，资源申请者只能进入睡眠状态。但是自旋锁不会引起调用者睡眠，如果自旋锁已经被别的执行单元保持，调用者就一直循环在那里看是否该自旋锁的保持者已经释放了锁，"自旋"一词就是因此而得名。（所以又叫忙等锁...）
 */
class spinlock_t {
    os_lock_handoff_s mLock;
 public:
    spinlock_t() : mLock(OS_LOCK_HANDOFF_INIT) { }
    
    void lock() { os_lock_lock(&mLock); }
    void unlock() { os_lock_unlock(&mLock); }
    bool trylock() { return os_lock_trylock(&mLock); }


    // Address-ordered lock discipline for a pair of locks.

    static void lockTwo(spinlock_t *lock1, spinlock_t *lock2) {
        if (lock1 > lock2) { // 比较的是地址？？
            lock1->lock();
            lock2->lock();
        } else { // 小于或等于
            lock2->lock();
            if (lock2 != lock1) lock1->lock(); 
        }
    }

    static void unlockTwo(spinlock_t *lock1, spinlock_t *lock2) {
        lock1->unlock();
        if (lock2 != lock1) lock2->unlock();
    }
};


#if !TARGET_OS_IPHONE
#   include <CrashReporterClient.h>
#else
    // CrashReporterClient not yet available on iOS
    __BEGIN_DECLS
    extern const char *CRSetCrashLogMessage(const char *msg);
    extern const char *CRGetCrashLogMessage(void);
    extern const char *CRSetCrashLogMessage2(const char *msg);
    __END_DECLS
#endif

#   if __cplusplus
#       include <vector>
#       include <algorithm>
#       include <functional>
        using namespace std;
#   endif

#   define PRIVATE_EXTERN __attribute__((visibility("hidden")))
#   undef __private_extern__
#   define __private_extern__ use_PRIVATE_EXTERN_instead
#   undef private_extern
#   define private_extern use_PRIVATE_EXTERN_instead

/* Use this for functions that are intended to be breakpoint hooks.
   If you do not, the compiler may optimize them away.
   BREAKPOINT_FUNCTION( void stop_on_error(void) ); */
#   define BREAKPOINT_FUNCTION(prototype)                             \
    OBJC_EXTERN __attribute__((noinline, used, visibility("hidden"))) \
    prototype { asm(""); }

#elif TARGET_OS_WIN32

#   define WINVER 0x0501		// target Windows XP and later
#   define _WIN32_WINNT 0x0501	// target Windows XP and later
#   define WIN32_LEAN_AND_MEAN
    // hack: windef.h typedefs BOOL as int
#   define BOOL WINBOOL
#   include <windows.h>
#   undef BOOL

#   include <stdio.h>
#   include <stdlib.h>
#   include <stdint.h>
#   include <stdarg.h>
#   include <string.h>
#   include <assert.h>
#   include <malloc.h>
#   include <Availability.h>

#   if __cplusplus
#       include <vector>
#       include <algorithm>
#       include <functional>
        using namespace std;
#       define __BEGIN_DECLS extern "C" {
#       define __END_DECLS   }
#   else
#       define __BEGIN_DECLS /*empty*/
#       define __END_DECLS   /*empty*/
#   endif

#   define PRIVATE_EXTERN
#   define __attribute__(x)
#   define inline __inline

/* Use this for functions that are intended to be breakpoint hooks.
   If you do not, the compiler may optimize them away.
   BREAKPOINT_FUNCTION( void MyBreakpointFunction(void) ); */
#   define BREAKPOINT_FUNCTION(prototype) \
    __declspec(noinline) prototype { __asm { } }

/* stub out dtrace probes */
#   define OBJC_RUNTIME_OBJC_EXCEPTION_RETHROW() do {} while(0)  
#   define OBJC_RUNTIME_OBJC_EXCEPTION_THROW(arg0) do {} while(0)

#else
#   error unknown OS
#endif


#include <objc/objc.h>
#include <objc/objc-api.h>

extern void _objc_fatal(const char *fmt, ...) __attribute__((noreturn, format (printf, 1, 2)));

// 初始化一次 var 指针
// 它循环调用 OSAtomicCompareAndSwapPtrBarrier，其中会查看二级指针 var 指向的值是否等于0，如果等于，就将 create 指向的值赋给 var，结束循环，否则继续尝试；
// 结束循环后，调用 delete，将 create 销毁，#疑问：按照这个逻辑，是不可能走到 delete 的呀
// OSAtomicCompareAndSwapPtrBarrier 函数原型：
// bool	OSAtomicCompareAndSwapPtrBarrier( void *__oldValue, void *__newValue, void * volatile *__theValue );
// 它比较并交换指针，用到了 barrier
// 这个函数比较指针 oldValue 指向的旧值 和 指针 theValue 指向的内存中当前的值，如果一致，就将指针 newValue 指向的新值赋给 theValue 指向的内存，注意这里 theValue 是二级指针
// 整个操作是原子性的。
// 如果匹配上就返回 TRUE，否则返回 FALSE
#define INIT_ONCE_PTR(var, create, delete)                              \
    do {                                                                \
        if (var) break;                                                 \
        __typeof__(var) v = create;                                         \
        while (!var) {                                                  \
            if (OSAtomicCompareAndSwapPtrBarrier(0, (void*)v, (void**)&var)){ \
                goto done;                                              \
            }                                                           \
        }                                                               \
        delete;                                                         \
    done:;                                                              \
    } while (0)

#define INIT_ONCE_32(var, create, delete)                               \
    do {                                                                \
        if (var) break;                                                 \
        typeof(var) v = create;                                         \
        while (!var) {                                                  \
            if (OSAtomicCompareAndSwap32Barrier(0, v, (volatile int32_t *)&var)) { \
                goto done;                                              \
            }                                                           \
        }                                                               \
        delete;                                                         \
    done:;                                                              \
    } while (0)


// Thread keys reserved by libc for our use.
#if defined(__PTK_FRAMEWORK_OBJC_KEY0)
#   define SUPPORT_DIRECT_THREAD_KEYS 1
#   define TLS_DIRECT_KEY        ((tls_key_t)__PTK_FRAMEWORK_OBJC_KEY0)
#   define SYNC_DATA_DIRECT_KEY  ((tls_key_t)__PTK_FRAMEWORK_OBJC_KEY1)
#   define SYNC_COUNT_DIRECT_KEY ((tls_key_t)__PTK_FRAMEWORK_OBJC_KEY2)
#   define AUTORELEASE_POOL_KEY  ((tls_key_t)__PTK_FRAMEWORK_OBJC_KEY3)
# if SUPPORT_RETURN_AUTORELEASE
#   define RETURN_DISPOSITION_KEY ((tls_key_t)__PTK_FRAMEWORK_OBJC_KEY4)
# endif
# if SUPPORT_QOS_HACK
#   define QOS_KEY               ((tls_key_t)__PTK_FRAMEWORK_OBJC_KEY5)
# endif
#else
#   define SUPPORT_DIRECT_THREAD_KEYS 0
#endif


#if TARGET_OS_WIN32

// Compiler compatibility

// OS compatibility

#define strdup _strdup

#define issetugid() 0

#define MIN(x, y) ((x) < (y) ? (x) : (y))

static __inline void bcopy(const void *src, void *dst, size_t size) { memcpy(dst, src, size); }
static __inline void bzero(void *dst, size_t size) { memset(dst, 0, size); }

int asprintf(char **dstp, const char *format, ...);

typedef void * malloc_zone_t;

static __inline malloc_zone_t malloc_default_zone(void) { return (malloc_zone_t)-1; }
static __inline void *malloc_zone_malloc(malloc_zone_t z, size_t size) { return malloc(size); }
static __inline void *malloc_zone_calloc(malloc_zone_t z, size_t size, size_t count) { return calloc(size, count); }
static __inline void *malloc_zone_realloc(malloc_zone_t z, void *p, size_t size) { return realloc(p, size); }
static __inline void malloc_zone_free(malloc_zone_t z, void *p) { free(p); }
static __inline malloc_zone_t malloc_zone_from_ptr(const void *p) { return (malloc_zone_t)-1; }
static __inline size_t malloc_size(const void *p) { return _msize((void*)p); /* fixme invalid pointer check? */ }


// OSAtomic

static __inline BOOL OSAtomicCompareAndSwapLong(long oldl, long newl, long volatile *dst) 
{ 
    // fixme barrier is overkill
    long original = InterlockedCompareExchange(dst, newl, oldl);
    return (original == oldl);
}

static __inline BOOL OSAtomicCompareAndSwapPtrBarrier(void *oldp, void *newp, void * volatile *dst) 
{ 
    void *original = InterlockedCompareExchangePointer(dst, newp, oldp);
    return (original == oldp);
}

static __inline BOOL OSAtomicCompareAndSwap32Barrier(int32_t oldl, int32_t newl, int32_t volatile *dst) 
{ 
    long original = InterlockedCompareExchange((volatile long *)dst, newl, oldl);
    return (original == oldl);
}

static __inline int32_t OSAtomicDecrement32Barrier(volatile int32_t *dst)
{
    return InterlockedDecrement((volatile long *)dst);
}

static __inline int32_t OSAtomicIncrement32Barrier(volatile int32_t *dst)
{
    return InterlockedIncrement((volatile long *)dst);
}


// Internal data types

typedef DWORD objc_thread_t;  // thread ID
static __inline int thread_equal(objc_thread_t t1, objc_thread_t t2) { 
    return t1 == t2; 
}
static __inline objc_thread_t thread_self(void) { 
    return GetCurrentThreadId(); 
}

typedef struct {
    DWORD key;
    void (*dtor)(void *);
} tls_key_t;
static __inline tls_key_t tls_create(void (*dtor)(void*)) { 
    // fixme need dtor registry for DllMain to call on thread detach
    tls_key_t k;
    k.key = TlsAlloc();
    k.dtor = dtor;
    return k;
}
static __inline void *tls_get(tls_key_t k) { 
    return TlsGetValue(k.key); 
}
static __inline void tls_set(tls_key_t k, void *value) { 
    TlsSetValue(k.key, value); 
}

typedef struct {
    CRITICAL_SECTION *lock;
} mutex_t;
#define MUTEX_INITIALIZER {0};
extern void mutex_init(mutex_t *m);
static __inline int _mutex_lock_nodebug(mutex_t *m) { 
    // fixme error check
    if (!m->lock) {
        mutex_init(m);
    }
    EnterCriticalSection(m->lock); 
    return 0;
}
static __inline bool _mutex_try_lock_nodebug(mutex_t *m) { 
    // fixme error check
    if (!m->lock) {
        mutex_init(m);
    }
    return TryEnterCriticalSection(m->lock); 
}
static __inline int _mutex_unlock_nodebug(mutex_t *m) { 
    // fixme error check
    LeaveCriticalSection(m->lock); 
    return 0;
}


typedef mutex_t spinlock_t;
#define spinlock_lock(l) mutex_lock(l)
#define spinlock_unlock(l) mutex_unlock(l)
#define SPINLOCK_INITIALIZER MUTEX_INITIALIZER


typedef struct {
    HANDLE mutex;
} recursive_mutex_t;
#define RECURSIVE_MUTEX_INITIALIZER {0};
#define RECURSIVE_MUTEX_NOT_LOCKED 1
extern void recursive_mutex_init(recursive_mutex_t *m);
static __inline int _recursive_mutex_lock_nodebug(recursive_mutex_t *m) { 
    assert(m->mutex);
    return WaitForSingleObject(m->mutex, INFINITE);
}
static __inline bool _recursive_mutex_try_lock_nodebug(recursive_mutex_t *m) { 
    assert(m->mutex);
    return (WAIT_OBJECT_0 == WaitForSingleObject(m->mutex, 0));
}
static __inline int _recursive_mutex_unlock_nodebug(recursive_mutex_t *m) { 
    assert(m->mutex);
    return ReleaseMutex(m->mutex) ? 0 : RECURSIVE_MUTEX_NOT_LOCKED;
}


/*
typedef HANDLE mutex_t;
static inline void mutex_init(HANDLE *m) { *m = CreateMutex(NULL, FALSE, NULL); }
static inline void _mutex_lock(mutex_t *m) { WaitForSingleObject(*m, INFINITE); }
static inline bool mutex_try_lock(mutex_t *m) { return WaitForSingleObject(*m, 0) == WAIT_OBJECT_0; }
static inline void _mutex_unlock(mutex_t *m) { ReleaseMutex(*m); }
*/

// based on http://www.cs.wustl.edu/~schmidt/win32-cv-1.html
// Vista-only CONDITION_VARIABLE would be better
typedef struct {
    HANDLE mutex;
    HANDLE waiters;      // semaphore for those in cond_wait()
    HANDLE waitersDone;  // auto-reset event after everyone gets a broadcast
    CRITICAL_SECTION waitCountLock;  // guards waitCount and didBroadcast
    unsigned int waitCount;
    int didBroadcast; 
} monitor_t;
#define MONITOR_INITIALIZER { 0 }
#define MONITOR_NOT_ENTERED 1
extern int monitor_init(monitor_t *c);

static inline int _monitor_enter_nodebug(monitor_t *c) {
    if (!c->mutex) {
        int err = monitor_init(c);
        if (err) return err;
    }
    return WaitForSingleObject(c->mutex, INFINITE);
}
static inline int _monitor_leave_nodebug(monitor_t *c) {
    if (!ReleaseMutex(c->mutex)) return MONITOR_NOT_ENTERED;
    else return 0;
}
static inline int _monitor_wait_nodebug(monitor_t *c) { 
    int last;
    EnterCriticalSection(&c->waitCountLock);
    c->waitCount++;
    LeaveCriticalSection(&c->waitCountLock);

    SignalObjectAndWait(c->mutex, c->waiters, INFINITE, FALSE);

    EnterCriticalSection(&c->waitCountLock);
    c->waitCount--;
    last = c->didBroadcast  &&  c->waitCount == 0;
    LeaveCriticalSection(&c->waitCountLock);

    if (last) {
        // tell broadcaster that all waiters have awoken
        SignalObjectAndWait(c->waitersDone, c->mutex, INFINITE, FALSE);
    } else {
        WaitForSingleObject(c->mutex, INFINITE);
    }

    // fixme error checking
    return 0;
}
static inline int monitor_notify(monitor_t *c) { 
    int haveWaiters;

    EnterCriticalSection(&c->waitCountLock);
    haveWaiters = c->waitCount > 0;
    LeaveCriticalSection(&c->waitCountLock);

    if (haveWaiters) {
        ReleaseSemaphore(c->waiters, 1, 0);
    }

    // fixme error checking
    return 0;
}
static inline int monitor_notifyAll(monitor_t *c) { 
    EnterCriticalSection(&c->waitCountLock);
    if (c->waitCount == 0) {
        LeaveCriticalSection(&c->waitCountLock);
        return 0;
    }
    c->didBroadcast = 1;
    ReleaseSemaphore(c->waiters, c->waitCount, 0);
    LeaveCriticalSection(&c->waitCountLock);

    // fairness: wait for everyone to move from waiters to mutex
    WaitForSingleObject(c->waitersDone, INFINITE);
    // not under waitCountLock, but still under mutex
    c->didBroadcast = 0;

    // fixme error checking
    return 0;
}


// fixme no rwlock yet


typedef IMAGE_DOS_HEADER headerType;
// fixme YES bundle? NO bundle? sometimes?
#define headerIsBundle(hi) YES
OBJC_EXTERN IMAGE_DOS_HEADER __ImageBase;
#define libobjc_header ((headerType *)&__ImageBase)

// Prototypes


#elif TARGET_OS_MAC


// OS headers
#include <mach-o/loader.h>
#ifndef __LP64__
#   define SEGMENT_CMD LC_SEGMENT
#else
#   define SEGMENT_CMD LC_SEGMENT_64
#endif

#ifndef VM_MEMORY_OBJC_DISPATCHERS
#   define VM_MEMORY_OBJC_DISPATCHERS 0
#endif


// Compiler compatibility

// OS compatibility

static inline uint64_t nanoseconds() {
    return mach_absolute_time();
}

// Internal data types

typedef pthread_t objc_thread_t;

static __inline int thread_equal(objc_thread_t t1, objc_thread_t t2) { 
    return pthread_equal(t1, t2); 
}
static __inline objc_thread_t thread_self(void) { 
    return pthread_self(); 
}


typedef pthread_key_t tls_key_t;

static inline tls_key_t tls_create(void (*dtor)(void*)) { 
    tls_key_t k;
    pthread_key_create(&k, dtor); 
    return k;
}
static inline void *tls_get(tls_key_t k) { 
    return pthread_getspecific(k); 
}
static inline void tls_set(tls_key_t k, void *value) { 
    pthread_setspecific(k, value); 
}

#if SUPPORT_DIRECT_THREAD_KEYS

#if DEBUG
static bool is_valid_direct_key(tls_key_t k) {
    return (   k == SYNC_DATA_DIRECT_KEY
            || k == SYNC_COUNT_DIRECT_KEY
            || k == AUTORELEASE_POOL_KEY
#   if SUPPORT_RETURN_AUTORELEASE
            || k == RETURN_DISPOSITION_KEY
#   endif
#   if SUPPORT_QOS_HACK
            || k == QOS_KEY
#   endif
               );
}
#endif

#if __arm__

// rdar://9162780  _pthread_get/setspecific_direct are inefficient
// copied from libdispatch

__attribute__((const))
static ALWAYS_INLINE void**
tls_base(void)
{
    uintptr_t p;
#if defined(__arm__) && defined(_ARM_ARCH_6)
    __asm__("mrc	p15, 0, %[p], c13, c0, 3" : [p] "=&r" (p));
    return (void**)(p & ~0x3ul);
#else
#error tls_base not implemented
#endif
}

// Thread Local Storage（TLS）线程局部存储，目的很简单，将一块内存作为某个线程专有的存储，以key-value的形式进行读写
// 绑定key 和 对象
static ALWAYS_INLINE void
tls_set_direct(void **tsdb, tls_key_t k, void *v)
{
    assert(is_valid_direct_key(k));

    tsdb[k] = v;
}
#define tls_set_direct(k, v)                    \
        tls_set_direct(tls_base(), (k), (v))


// 取得指定key绑定的对象
static ALWAYS_INLINE void *
tls_get_direct(void **tsdb, tls_key_t k)
{
    assert(is_valid_direct_key(k));

    return tsdb[k];
}
#define tls_get_direct(k)                       \
        tls_get_direct(tls_base(), (k))

// arm
#else
// not arm

static inline void *tls_get_direct(tls_key_t k) 
{ 
    assert(is_valid_direct_key(k));

    if (_pthread_has_direct_tsd()) {
        return _pthread_getspecific_direct(k);
    } else {
        return pthread_getspecific(k);
    }
}
static inline void tls_set_direct(tls_key_t k, void *value) 
{ 
    assert(is_valid_direct_key(k));

    if (_pthread_has_direct_tsd()) {
        _pthread_setspecific_direct(k, value);
    } else {
        pthread_setspecific(k, value);
    }
}

// not arm
#endif

// SUPPORT_DIRECT_THREAD_KEYS
#endif


static inline pthread_t pthread_self_direct()
{
    return (pthread_t)
        _pthread_getspecific_direct(_PTHREAD_TSD_SLOT_PTHREAD_SELF);
}

static inline mach_port_t mach_thread_self_direct() 
{
    return (mach_port_t)(uintptr_t)
        _pthread_getspecific_direct(_PTHREAD_TSD_SLOT_MACH_THREAD_SELF);
}

typedef unsigned long pthread_priority_t;
#include <pthread/tsd_private.h>

#if SUPPORT_QOS_HACK

#include <pthread/qos_private.h>

static inline pthread_priority_t pthread_self_priority_direct() 
{
    pthread_priority_t pri = (pthread_priority_t)
        _pthread_getspecific_direct(_PTHREAD_TSD_SLOT_PTHREAD_QOS_CLASS);
    return pri & ~_PTHREAD_PRIORITY_FLAGS_MASK;
}
#endif


template <bool Debug> class mutex_tt;
template <bool Debug> class monitor_tt;
template <bool Debug> class rwlock_tt;
template <bool Debug> class recursive_mutex_tt;

#include "objc-lockdebug.h"

// 互斥量，也继承自 nocopy_t ，没有拷贝构造
template <bool Debug>
class mutex_tt : nocopy_t {
    pthread_mutex_t mLock;  // 原理还是利用 pthread_mutex_t 来完成互斥量的操作

  public:
    mutex_tt() : mLock((pthread_mutex_t)PTHREAD_MUTEX_INITIALIZER) { }

    void lock()
    {
        lockdebug_mutex_lock(this);

        int err = pthread_mutex_lock(&mLock);
        if (err) _objc_fatal("pthread_mutex_lock failed (%d)", err);
    }

    bool tryLock()
    {
        int err = pthread_mutex_trylock(&mLock);
        if (err == 0) {
            lockdebug_mutex_try_lock_success(this);
            return true;
        } else if (err == EBUSY) {
            return false;
        } else {
            _objc_fatal("pthread_mutex_trylock failed (%d)", err);
        }
    }

    void unlock()
    {
        lockdebug_mutex_unlock(this);

        int err = pthread_mutex_unlock(&mLock);
        if (err) _objc_fatal("pthread_mutex_unlock failed (%d)", err);
    }


    void assertLocked() {
        lockdebug_mutex_assert_locked(this);
    }

    void assertUnlocked() {
        lockdebug_mutex_assert_unlocked(this);
    }
};

using mutex_t = mutex_tt<DEBUG>;


template <bool Debug>
class recursive_mutex_tt : nocopy_t {
    pthread_mutex_t mLock;

  public:
    recursive_mutex_tt() : mLock((pthread_mutex_t)PTHREAD_RECURSIVE_MUTEX_INITIALIZER) { }

    void lock()
    {
        lockdebug_recursive_mutex_lock(this);

        int err = pthread_mutex_lock(&mLock);
        if (err) _objc_fatal("pthread_mutex_lock failed (%d)", err);
    }

    bool tryLock()
    {
        int err = pthread_mutex_trylock(&mLock);
        if (err == 0) {
            lockdebug_recursive_mutex_lock(this);
            return true;
        } else if (err == EBUSY) {
            return false;
        } else {
            _objc_fatal("pthread_mutex_trylock failed (%d)", err);
        }
    }


    void unlock()
    {
        lockdebug_recursive_mutex_unlock(this);

        int err = pthread_mutex_unlock(&mLock);
        if (err) _objc_fatal("pthread_mutex_unlock failed (%d)", err);
    }

    bool tryUnlock()
    {
        int err = pthread_mutex_unlock(&mLock);
        if (err == 0) {
            lockdebug_recursive_mutex_unlock(this);
            return true;
        } else if (err == EPERM) {
            return false;
        } else {
            _objc_fatal("pthread_mutex_unlock failed (%d)", err);
        }
    }


    void assertLocked() {
        lockdebug_recursive_mutex_assert_locked(this);
    }

    void assertUnlocked() {
        lockdebug_recursive_mutex_assert_unlocked(this);
    }
};

using recursive_mutex_t = recursive_mutex_tt<DEBUG>;

/*
 互斥锁：
 顾名思义，锁是用来锁住某种东西的，锁住之后只有有钥匙的人才能对锁住的东西拥有控制权(把锁砸了，把东西偷走的小偷不在我们的讨论范围了)。所谓互斥， 从字面上理解就是互相排斥。因此互斥锁从字面上理解就是一点进程拥有了这个锁，它将排斥其它所有的进程访问被锁住的东西，其它的进程如果需要锁就只能等待，等待拥有锁的进程把锁打开后才能继续运行。 在实现中，锁并不是与某个具体的变量进行关联，它本身是一个独立的对象。进(线)程在有需要的时候获得此对象，用完不需要时就释放掉。
 互斥锁的主要特点是互斥锁的释放必须由上锁的进(线)程释放，如果拥有锁的进(线)程不释放，那么其它的进(线)程永远也没有机会获得所需要的互斥锁。
 互斥锁主要用于线程之间的同步。
 
 条件变量：
 上文中提到，对于互斥锁而言，如果拥有锁的进(线)程不释放锁，其它进(线)程永远没机会获得锁，也就永远没有机会继续执行后续的逻辑。在实际环境下，一 个线程A需要改变一个共享变量X的值，为了保证在修改的过程中X不会被其它的线程修改，线程A必须首先获得对X的锁。现在假如A已经获得锁了，由于业务逻 辑的需要，只有当X的值小于0时，线程A才能执行后续的逻辑，于是线程A必须把互斥锁释放掉，然后继续“忙等”。如下面的伪代码所示：
 1.// get x lock
 2.while(x <= 0){
 3. // unlock x ;
 4. // wait some time
 5. // get x lock
 6.}
 7.// unlock x
 这种方式是比较消耗系统的资源的，因为进程必须不停的主动获得锁、检查X条件、释放锁、再获得锁、再检查、再释放，一直到满足运行的条件的时候才可以（而此过程中其他线程一直在等待该线程的结束）。因此我们需要另外一种不同的同步方式，当线程X发现被锁定的变量不满足条件时会自动的释放锁并把自身置于等待状态，让出CPU的控制权给其它线程。其它线程 此时就有机会去修改X的值，当修改完成后再通知那些由于条件不满足而陷入等待状态的线程。这是一种通知模型的同步方式，大大的节省了CPU的计算资源，减少了线程之间的竞争，而且提高了线程之间的系统工作的效率。这种同步方式就是条件变量。 坦率的说，从字面意思上来将，“条件变量”这四个字是不太容易理解的。我们可以把“条件变量”看做是一个对象，一个会响的铃铛。当一个线程在获 得互斥锁之后，由于被锁定的变量不满足继续运行的条件时，该线程就释放互斥锁并把自己挂到这个“铃铛”上。其它的线程在修改完变量后， 就摇摇“铃铛”， 告诉那些挂着的线程：“你们等待的东西已经变化了，都醒醒看看现在的它是否满足你们的要求。”于是那些挂着的线程就知道自己醒来看自己是否能继续跑下去 了。
 同样换一种方式解释：
 
 互斥锁，我要对一块共享数据操作，但是我怕同时你也操作，那就乱套了，所以我要加锁，这个时候我就开始操作这块共享数据，而你进不了临界区，等我操作完了，把锁丢掉，你就可以拿到锁进去操作了。条件变量，我要看一块共享数据里某一个条件是否达成，我很关心这个，如果我用互斥锁，不停的进入临界区看条件是否达成，这简直太悲剧了，这样一来， 我醒的时候会占CPU资源，但是却干不了什么时，只是频繁的看条件是否达成，而且这对别人来说也是一种损失，我每次加上锁，别人就进不了临界区干不了事 了。好吧，轮询总是痛苦的，咱等别人通知吧，于是条件变量出现了，我依旧要拿个锁，进了临界区，看到了共享数据，发现，咦，条件还不到，于是我就调用 pthread_cond_wait(),先把锁丢了，好让别人可以去对共享数据做操作，然后呢？然后我就睡了，直到特定的条件发生，别人修改完了共享数 据，给我发了个消息，我又重新拿到了锁，继续干俺要干的事情了……
 */

/*
 一篇极好的文章：http://m.blog.csdn.net/article/details?id=2195350
 这篇专业得多
 
 1. 相关函数
 #include <pthread.h>
 pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
 int    pthread_cond_init(pthread_cond_t    *cond,    pthread_condattr_t
 *cond_attr);
 int pthread_cond_signal(pthread_cond_t *cond);
 int pthread_cond_broadcast(pthread_cond_t *cond);
 int pthread_cond_wait(pthread_cond_t *cond, pthread_mutex_t *mutex);
 int   pthread_cond_timedwait(pthread_cond_t   *cond,    pthread_mutex_t
 *mutex, const struct timespec *abstime);
 int pthread_cond_destroy(pthread_cond_t *cond);
 
 2. 说明
 条件变量是一种同步机制，允许线程挂起，直到共享数据上的某些条件得到满足。条件变量上的基本操作有：触发条件(当条件变为 true 时)；等待条件，挂起线程直到其他线程触发条件。
 -----------------------      重点       -----------------------------
 条件变量要和互斥量相联结，以避免出现条件竞争－－一个线程预备等待一个条件变量，当它在真正进入等待之前，另一个线程恰好触发了该条件。
 -------------------------------------------------------------------------
 pthread_cond_init 使用 cond_attr 指定的属性初始化条件变量 cond，当 cond_attr 为 NULL 时，使用缺省的属性。LinuxThreads 实现条件变量不支持属性，因此 cond_attr 参数实际被忽略。
 pthread_cond_t 类型的变量也可以用 PTHREAD_COND_INITIALIZER 常量进行静态初始化。
 pthread_cond_signal 使在条件变量上等待的线程中的一个线程重新开始。如果没有等待的线程，则什么也不做。如果有多个线程在等待该条件，只有一个能重启动，但不能指定哪一个。
 pthread_cond_broadcast 重启动等待该条件变量的所有线程。如果没有等待的线程，则什么也不做。
 pthread_cond_wait 自动解锁互斥量(如同执行了 pthread_unlock_mutex)，并等待条件变量触发。这时线程挂起，不占用 CPU 时间，直到条件变量被触发。在调用 pthread_cond_wait 之前，应用程序必须加锁互斥量。pthread_cond_wait 函数返回前，自动重新对互斥量加锁(如同执行了 pthread_lock_mutex)。
 ----------------------------------
 互斥量的解锁和在条件变量上挂起都是自动进行的。因此，在条件变量被触发前，如果所有的线程都要对互斥量加锁，这种机制可保证在线程加锁互斥量和进入等待条件变量期间，条件变量不被触发。
 ----------------------------------
 pthread_cond_timedwait 和 pthread_cond_wait 一样，自动解锁互斥量及等待条件变量，但它还限定了等待时间。如果在 abstime 指定的时间内 cond 未触发，互斥量 mutex 被重新加锁，且 pthread_cond_timedwait 返回错误 ETIMEDOUT。abstime 参数指定一个绝对时间，时间原点与 time 和 gettimeofday 相同：abstime = 0 表示 1970 年 1 月 1 日 00:00:00 GMT。
 pthread_cond_destroy 销毁一个条件变量，释放它拥有的资源。进入 pthread_cond_destroy 之前，必须没有在该条件变量上等待的线程。在 LinuxThreads 的实现中，条件变量不联结资源，除检查有没有等待的线程外，pthread_cond_destroy 实际上什么也不做。
 
 3. 取消
 pthread_cond_wait 和 pthread_cond_timedwait 是取消点。如果一个线程在这些函数上挂起时被取消，线程立即继续执行，然后再次对 pthread_cond_wait 和 pthread_cond_timedwait 在 mutex 参数加锁，最后执行取消。因此，当调用清除处理程序时，可确保，mutex 是加锁的。
 
 4. 异步信号安全(Async-signal Safety)
 条件变量函数不是异步信号安全的，不应当在信号处理程序中进行调用。特别要注意，如果在信号处理程序中调用 pthread_cond_signal 或 pthread_cond_boardcast 函数，可能导致调用线程死锁。
 
 5. 返回值
 在执行成功时，所有条件变量函数都返回 0，错误时返回非零的错误代码。
 
 6. 错误代码
 pthread_cond_init,   pthread_cond_signal,  pthread_cond_broadcast, 和 pthread_cond_wait    从不返回错误代码。
 pthread_cond_timedwait   函数出错时返回下列错误代码：
 ETIMEDOUT   abstime      指定的时间超时时，条件变量未触发
 EINTR       pthread_cond_timedwait 被触发中断
 pthread_cond_destroy     函数出错时返回下列错误代码：
 EBUSY                    某些线程正在等待该条件变量
 
 7. 举例
 设有两个共享的变量 x 和 y，通过互斥量 mut 保护，当 x > y 时，条件变量 cond 被触发。
 int x,y;
 int x,y;
 pthread_mutex_t mut = PTHREAD_MUTEX_INITIALIZER;
 pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
 
 
 I 等待直到 x > y 的执行流程：
    pthread_mutex_lock(&mut); // 互斥量上锁
    while (x <= y) {          // while 判断条件中是：如果满足条件，就进行 wait
        pthread_cond_wait(&cond, &mut); // 进入 wait 后自动解锁，然后挂起，
                                        //    直到接收到 signal
                                        // 返回时自动上锁
    }
    // 对 x、y 进行操作
    pthread_mutex_unlock(&mut); // 互斥量解锁

 
 II 对 x 和 y 的修改可能导致 x > y，应当触发条件变量：
    pthread_mutex_lock(&mut);  // 互斥量上锁
    // 修改 x、y
    if (x > y) {               // 当满足条件后
        pthread_cond_broadcast(&cond);  // 重启动等待该条件变量的所有线程。
                                        //    如果没有等待的线程，则什么也不做
    }
    pthread_mutex_unlock(&mut); // 互斥量解锁

 如果能够确定最多只有一个等待线程需要被唤醒(例如，如果只有两个线程通过 x、y 通信)，则使用 pthread_cond_signal 比 pthread_cond_broadcast 效率稍高一些。如果不能确定，应当用 pthread_cond_broadcast。
 要等待在 5 秒内 x > y，这样处理：

    struct timeval now;
    struct timespec timeout;
    int retcode;

    pthread_mutex_lock(&mut);
    gettimeofday(&now);
    timeout.tv_sec = now.tv_sec + 5;
    timeout.tv_nsec = now.tv_usec * 1000;
    retcode = 0;
    while (x <= y && retcode != ETIMEDOUT) {
        retcode = pthread_cond_timedwait(&cond, &mut, &timeout);
    }
    if (retcode == ETIMEDOUT) {
        // 发生超时
    } else {
        // 操作 x 和  y
    }
    pthread_mutex_unlock(&mut);
 */

// 模板中 bool Debug 表示是否是在 DEBUG 模式
template <bool Debug>
class monitor_tt {
    pthread_mutex_t mutex;  // 互斥量，玩法就是 加锁、解锁
    pthread_cond_t cond;    // 条件变量
    
  public:
    
    /* 条件变量和互斥锁一样，都有静态和动态两种创建方式，
       静态方式使用PTHREAD_COND_INITIALIZER常量进行初始化，如下：
            pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
       动态方式调用pthread_cond_init()函数，API定义如下：
          int pthread_cond_init(pthread_cond_t *cond, pthread_condattr_t *cond_attr)
     */
    monitor_tt()
        : mutex((pthread_mutex_t)PTHREAD_MUTEX_INITIALIZER), cond((pthread_cond_t)PTHREAD_COND_INITIALIZER) { }

    void enter()
    {
        lockdebug_monitor_enter(this);

        // 互斥量加锁
        int err = pthread_mutex_lock(&mutex);
        if (err) _objc_fatal("pthread_mutex_lock failed (%d)", err);
    }

    void leave()
    {
        lockdebug_monitor_leave(this);

        // 互斥量解锁
        int err = pthread_mutex_unlock(&mutex);
        if (err) _objc_fatal("pthread_mutex_unlock failed (%d)", err);
    }

    void wait()
    {
        lockdebug_monitor_wait(this);

        // 自动解锁互斥量(如同执行了 pthread_unlock_mutex)，并等待条件变量触发。这时线程挂起，不占用 CPU 时间，直到条件变量被触发。在调用 pthread_cond_wait 之前，应用程序必须加锁互斥量。pthread_cond_wait 函数返回前，自动重新对互斥量加锁(如同执行了 pthread_lock_mutex)。
        int err = pthread_cond_wait(&cond, &mutex);
        if (err) _objc_fatal("pthread_cond_wait failed (%d)", err);
    }

    void notify() 
    {
        // 使在条件变量上等待的线程中的一个线程重新开始。如果没有等待的线程，则什么也不做。如果有多个线程在等待该条件，只有一个能重启动，但不能指定哪一个。
        int err = pthread_cond_signal(&cond);
        if (err) _objc_fatal("pthread_cond_signal failed (%d)", err);        
    }

    void notifyAll() 
    {
        // 重启动等待该条件变量的所有线程。如果没有等待的线程，则什么也不做
        int err = pthread_cond_broadcast(&cond);
        if (err) _objc_fatal("pthread_cond_broadcast failed (%d)", err);        
    }

    void assertLocked()
    {
        lockdebug_monitor_assert_locked(this);
    }

    void assertUnlocked()
    {
        lockdebug_monitor_assert_unlocked(this);
    }
};

// 我靠，还能这么玩，6 啊，这样相当于给 monitor_tt<DEBUG> 起了个别名
// 有相当于套用 monitor_tt 类模板，重新定义了一个新的普通类 monitor_t
using monitor_t = monitor_tt<DEBUG>;


// semaphore_create formatted for INIT_ONCE use
static inline semaphore_t create_semaphore(void)
{
    semaphore_t sem;
    kern_return_t k;
    k = semaphore_create(mach_task_self(), &sem, SYNC_POLICY_FIFO, 0);
    if (k) _objc_fatal("semaphore_create failed (0x%x)", k);
    return sem;
}


#if SUPPORT_QOS_HACK
// Override QOS class to avoid priority inversion in rwlocks
// <rdar://17697862> do a qos override before taking rw lock in objc

#include <pthread/workqueue_private.h>
extern pthread_priority_t BackgroundPriority;
extern pthread_priority_t MainPriority;

static inline void qosStartOverride()
{
    uintptr_t overrideRefCount = (uintptr_t)tls_get_direct(QOS_KEY);
    if (overrideRefCount > 0) {
        // If there is a qos override, increment the refcount and continue
        tls_set_direct(QOS_KEY, (void *)(overrideRefCount + 1));
    }
    else {
        pthread_priority_t currentPriority = pthread_self_priority_direct();
        // Check if override is needed. Only override if we are background qos
        if (currentPriority != 0  &&  currentPriority <= BackgroundPriority) {
            int res __unused = _pthread_override_qos_class_start_direct(mach_thread_self_direct(), MainPriority);
            assert(res == 0);
            // Once we override, we set the reference count in the tsd 
            // to know when to end the override
            tls_set_direct(QOS_KEY, (void *)1);
        }
    }
}

static inline void qosEndOverride()
{
    uintptr_t overrideRefCount = (uintptr_t)tls_get_direct(QOS_KEY);
    if (overrideRefCount == 0) return;

    if (overrideRefCount == 1) {
        // end the override
        int res __unused = _pthread_override_qos_class_end_direct(mach_thread_self_direct());
        assert(res == 0);
    }

    // decrement refcount
    tls_set_direct(QOS_KEY, (void *)(overrideRefCount - 1));
}

// SUPPORT_QOS_HACK
#else
// not SUPPORT_QOS_HACK

static inline void qosStartOverride() { }
static inline void qosEndOverride() { }

// not SUPPORT_QOS_HACK
#endif

/*
 读写锁实际是一种特殊的自旋锁，它把对共享资源的访问者划分成读者和写者，读者只对共享资源进行读访问，写者则需要对共享资源进行写操作。这种锁相对于自旋锁而言，能提高并发性，因为在多处理器系统中，它允许同时有多个读者来访问共享资源，最大可能的读者数为实际的逻辑CPU数。写者是排他性的，一个读写锁同时只能有一个写者或多个读者（与CPU数相关），但不能同时既有读者又有写者。
 在读写锁保持期间也是抢占失效的。
 如果读写锁当前没有读者，也没有写者，那么写者可以立刻获得读写锁，否则它必须自旋在那里，直到没有任何写者或读者。如果读写锁没有写者，那么读者可以立即获得该读写锁，否则读者必须自旋在那里，直到写者释放该读写锁。
 */

template <bool Debug>
class rwlock_tt : nocopy_t {
    pthread_rwlock_t mLock = PTHREAD_RWLOCK_INITIALIZER;

  public:
    
    rwlock_tt() {
    }
    
    void read() 
    {
        lockdebug_rwlock_read(this);

        qosStartOverride();
        int err = pthread_rwlock_rdlock(&mLock);
        if (err) _objc_fatal("pthread_rwlock_rdlock failed (%d)", err);
    }

    void unlockRead()
    {
        lockdebug_rwlock_unlock_read(this);

        int err = pthread_rwlock_unlock(&mLock);
        if (err) _objc_fatal("pthread_rwlock_unlock failed (%d)", err);
        qosEndOverride();
    }

    bool tryRead()
    {
        qosStartOverride();
        int err = pthread_rwlock_tryrdlock(&mLock);
        if (err == 0) {
            lockdebug_rwlock_try_read_success(this);
            return true;
        } else if (err == EBUSY) {
            qosEndOverride();
            return false;
        } else {
            _objc_fatal("pthread_rwlock_tryrdlock failed (%d)", err);
        }
    }

    void write()
    {
        lockdebug_rwlock_write(this);

        qosStartOverride();
        int err = pthread_rwlock_wrlock(&mLock);
        if (err) _objc_fatal("pthread_rwlock_wrlock failed (%d)", err);
    }

    void unlockWrite()
    {
        lockdebug_rwlock_unlock_write(this);

        int err = pthread_rwlock_unlock(&mLock);
        if (err) _objc_fatal("pthread_rwlock_unlock failed (%d)", err);
        qosEndOverride();
    }

    bool tryWrite()
    {
        qosStartOverride();
        int err = pthread_rwlock_trywrlock(&mLock);
        if (err == 0) {
            lockdebug_rwlock_try_write_success(this);
            return true;
        } else if (err == EBUSY) {
            qosEndOverride();
            return false;
        } else {
            _objc_fatal("pthread_rwlock_trywrlock failed (%d)", err);
        }
    }


    void assertReading() {
        lockdebug_rwlock_assert_reading(this);
    }

    void assertWriting() {
        lockdebug_rwlock_assert_writing(this);
    }

    void assertLocked() {
        lockdebug_rwlock_assert_locked(this);
    }

    void assertUnlocked() {
        lockdebug_rwlock_assert_unlocked(this);
    }
};

using rwlock_t = rwlock_tt<DEBUG>;


#ifndef __LP64__
typedef struct mach_header headerType;
typedef struct segment_command segmentType;
typedef struct section sectionType;
#else
typedef struct mach_header_64 headerType;
typedef struct segment_command_64 segmentType;
typedef struct section_64 sectionType;
#endif
#define headerIsBundle(hi) (hi->mhdr->filetype == MH_BUNDLE)
#define libobjc_header ((headerType *)&_mh_dylib_header)

// Prototypes

/* Secure /tmp usage */
extern int secure_open(const char *filename, int flags, uid_t euid);


#else


#error unknown OS


#endif


static inline void *
memdup(const void *mem, size_t len)
{
    void *dup = malloc(len);
    memcpy(dup, mem, len);
    return dup;
}

// unsigned strdup
static inline uint8_t *
ustrdup(const uint8_t *str)
{
    return (uint8_t *)strdup((char *)str);
}

// nil-checking strdup
static inline uint8_t *
strdupMaybeNil(const uint8_t *str)
{
    if (!str) return nil;
    return (uint8_t *)strdup((char *)str);
}

// nil-checking unsigned strdup
static inline uint8_t *
ustrdupMaybeNil(const uint8_t *str)
{
    if (!str) return nil;
    return (uint8_t *)strdup((char *)str);
}

#endif
