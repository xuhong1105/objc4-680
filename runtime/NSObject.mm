/*
 * Copyright (c) 2010-2012 Apple Inc. All rights reserved.
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

#include "objc-private.h"
#include "NSObject.h"

#include "objc-weak.h"
#include "llvm-DenseMap.h"
#include "NSObject.h"

#include <malloc/malloc.h>
#include <stdint.h>
#include <stdbool.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/nlist.h>
#include <sys/types.h>
#include <sys/mman.h>
#include <libkern/OSAtomic.h>
#include <Block.h>
#include <map>
#include <execinfo.h>

/*
 #ALLEN:
 An NSInvocation is an Objective-C message rendered static, that is, it is an action turned into an object. NSInvocation objects are used to store and forward messages between objects and between applications, primarily by NSTimer objects and the distributed objects system.
 */
// 这个声明好像不是 NSInvocation 真正的形态
// 在 NSInvocation.h 有复杂得多的声明
@interface NSInvocation
- (SEL)selector;
@end


#if TARGET_OS_MAC

// NSObject used to be in Foundation/CoreFoundation.

#define SYMBOL_ELSEWHERE_IN_3(sym, vers, n)                             \
    OBJC_EXPORT const char elsewhere_ ##n __asm__("$ld$hide$os" #vers "$" #sym); const char elsewhere_ ##n = 0
#define SYMBOL_ELSEWHERE_IN_2(sym, vers, n)     \
    SYMBOL_ELSEWHERE_IN_3(sym, vers, n)
#define SYMBOL_ELSEWHERE_IN(sym, vers)                  \
    SYMBOL_ELSEWHERE_IN_2(sym, vers, __COUNTER__)

#if __OBJC2__
# define NSOBJECT_ELSEWHERE_IN(vers)                       \
    SYMBOL_ELSEWHERE_IN(_OBJC_CLASS_$_NSObject, vers);     \
    SYMBOL_ELSEWHERE_IN(_OBJC_METACLASS_$_NSObject, vers); \
    SYMBOL_ELSEWHERE_IN(_OBJC_IVAR_$_NSObject.isa, vers)
#else
# define NSOBJECT_ELSEWHERE_IN(vers)                       \
    SYMBOL_ELSEWHERE_IN(.objc_class_name_NSObject, vers)
#endif

#if TARGET_OS_IOS
    NSOBJECT_ELSEWHERE_IN(5.1);
    NSOBJECT_ELSEWHERE_IN(5.0);
    NSOBJECT_ELSEWHERE_IN(4.3);
    NSOBJECT_ELSEWHERE_IN(4.2);
    NSOBJECT_ELSEWHERE_IN(4.1);
    NSOBJECT_ELSEWHERE_IN(4.0);
    NSOBJECT_ELSEWHERE_IN(3.2);
    NSOBJECT_ELSEWHERE_IN(3.1);
    NSOBJECT_ELSEWHERE_IN(3.0);
    NSOBJECT_ELSEWHERE_IN(2.2);
    NSOBJECT_ELSEWHERE_IN(2.1);
    NSOBJECT_ELSEWHERE_IN(2.0);
#elif TARGET_OS_MAC  &&  !TARGET_OS_IPHONE
    NSOBJECT_ELSEWHERE_IN(10.7);
    NSOBJECT_ELSEWHERE_IN(10.6);
    NSOBJECT_ELSEWHERE_IN(10.5);
    NSOBJECT_ELSEWHERE_IN(10.4);
    NSOBJECT_ELSEWHERE_IN(10.3);
    NSOBJECT_ELSEWHERE_IN(10.2);
    NSOBJECT_ELSEWHERE_IN(10.1);
    NSOBJECT_ELSEWHERE_IN(10.0);
#else
    // NSObject has always been in libobjc on these platforms.
#endif

// TARGET_OS_MAC
#endif


/***********************************************************************
* Weak ivar support
**********************************************************************/

static id defaultBadAllocHandler(Class cls)
{
    _objc_fatal("attempt to allocate object of class '%s' failed", 
                cls->nameForLogging());
}

static id(*badAllocHandler)(Class) = &defaultBadAllocHandler;

static id callBadAllocHandler(Class cls)
{
    // fixme add re-entrancy protection in case allocation fails inside handler
    return (*badAllocHandler)(cls);
}

void _objc_setBadAllocHandler(id(*newHandler)(Class))
{
    badAllocHandler = newHandler;
}


namespace {

// The order of these bits is important.
    
// 第一个 bit 表示有弱引用，如果没有，在析构释放内存时可以更快；
// 第二个 bit 表示该对象是否正在析构
// 从第三个 bit 开始才是存储引用计数数值的地方。所以这里要做向左移两位的操作，而对引用计数的 +1 和 -1 可以使用 SIDE_TABLE_RC_ONE, 还可以用 SIDE_TABLE_RC_PINNED 来判断是否引用计数值有可能溢出。
#define SIDE_TABLE_WEAKLY_REFERENCED (1UL<<0)
#define SIDE_TABLE_DEALLOCATING      (1UL<<1)  // MSB-ward of weak bit
#define SIDE_TABLE_RC_ONE            (1UL<<2)  // MSB-ward of deallocating bit
#define SIDE_TABLE_RC_PINNED         (1UL<<(WORD_BITS-1)) // 用来判断引用计数值是否溢出

#define SIDE_TABLE_RC_SHIFT 2 // 引用计数需要移动的 bit 位，因为第 3 位开始才是存引用计数的位置，所以需要移 2 位
#define SIDE_TABLE_FLAG_MASK (SIDE_TABLE_RC_ONE-1)

// RefcountMap disguises（伪装） its pointers because we don't want the table to act as a root for `leaks`.
    
// DenseMap 模板的三个参数：
//     DisguisedPtr<objc_object> : 稠密图里的 key 的类型，是经过伪装后的 objc_object 指针
//     size_t : 稠密图里的 value 的类型
//     true   : 代表 Zero Values Are Purgeable 看字面意思是零值可以被清除
typedef objc::DenseMap<DisguisedPtr<objc_object>,size_t,true> RefcountMap;

//  SideTable 这个类，它用于管理引用计数表和弱引用表，并使用 spinlock_lock 自旋锁来防止操作表结构时可能的竞态条件。
struct SideTable {
    spinlock_t slock; // 自旋锁（忙等锁）
    RefcountMap refcnts; // 用来记录引用计数、是否有弱引用、是否在 dealloc 等信息
    weak_table_t weak_table;  // 弱引用表，存了弱引用对象，以及指向它的弱引用们

    SideTable() {
        // 将 weak_table 所在区域的内存清零
        memset(&weak_table, 0, sizeof(weak_table));
    }

    // side table 对象常驻内存，不能删除 ？
    ~SideTable() {
        _objc_fatal("Do not delete SideTable.");
    }

    void lock() { slock.lock(); }
    void unlock() { slock.unlock(); }
    bool trylock() { return slock.trylock(); }

    // Address-ordered lock discipline for a pair of side tables.

    template<bool HaveOld, bool HaveNew>
    static void lockTwo(SideTable *lock1, SideTable *lock2);
    template<bool HaveOld, bool HaveNew>
    static void unlockTwo(SideTable *lock1, SideTable *lock2);
};


template<>
void SideTable::lockTwo<true, true>(SideTable *lock1, SideTable *lock2) {
    // 加锁也要看顺序，按地址排序，地址大的先加锁
    spinlock_t::lockTwo(&lock1->slock, &lock2->slock);
}

template<>
void SideTable::lockTwo<true, false>(SideTable *lock1, SideTable *) {
    lock1->lock();
}

template<>
void SideTable::lockTwo<false, true>(SideTable *, SideTable *lock2) {
    lock2->lock();
}

template<>
void SideTable::unlockTwo<true, true>(SideTable *lock1, SideTable *lock2) {
    spinlock_t::unlockTwo(&lock1->slock, &lock2->slock);
}

template<>
void SideTable::unlockTwo<true, false>(SideTable *lock1, SideTable *) {
    lock1->unlock();
}

template<>
void SideTable::unlockTwo<false, true>(SideTable *, SideTable *lock2) {
    lock2->unlock();
}
    


// We cannot use a C++ static initializer to initialize SideTables because
// libc calls us before our C++ initializers run. We also don't want a global 
// pointer to this struct because of the extra indirection.
// Do it the hard way.
// 不能用 C++ 的初始化器去初始化 Side Table，因为 libc 调用比 C++ 初始化器运行的时间还要早
// 我们也不想用全局的指针，因为会多个额外的中间层（？？？是这个意思吗）
    
// 这行代码的意思是，声明了一个静态的数组，数组名是SideTableBuf，
// 数组中元素的类型是uint8_t（unsigned char 也就是一个字节），数组中元素个数是sizeof(StripedMap<SideTable>)
// 相当于开辟了一块大小为 sizeof(StripedMap<SideTable>) 个 字节 的内存
// 但这时内存中全是0，没有经过初始化
alignas(StripedMap<SideTable>) static uint8_t
    SideTableBuf[sizeof(StripedMap<SideTable>)];

// 顺便说一下，比较有意思的是，StripedMap 里存数据的部分是
//          PaddedT array[StripeCount];
// 它一个数组，元素类型是 PaddedT ，元素个数是 StripeCount，在 iOS 上是64
// PaddedT 是一个结构体，存的是
//          T value alignas(CacheLineSize);
// T 现在是 SideTable，并且以 CacheLineSize 对齐（现在是64），即最小的内存单元是 CacheLineSize
// 即 PaddedT 占的内存大小是 64 的整数倍
// 那么 sizeof(SideTable) <= 64的时候， PaddedT 就占 1 个内存单元大小是 64
// 64 < sizeof(SideTable) <= 128的时候，PaddedT 就占 2 个内存单元大小是 128
// 以此类推
// sizeof(StripedMap<SideTable>) 的值就是 PaddedT 实际占用的大小 乘以 64
// 例如：sizeof(SideTable) <= 64 的时候，它等于 4096
//      64 < sizeof(SideTable) <= 128的时候，它等于 8192

// 重要！！！ StripedMap 一共分了 64 块，每块一个 SideTable，每个 SideTable 可以装很多个对象，
// 所以可以看到代码中多次用到类似
//    newTable = &SideTables()[newObj];
// 这样的代码查找对象所在的 SideTable
    
// SideTable 并没有直接存对象，是在 refcnts 和 weak_table 中有与对象有关的信息
static void SideTableInit() {
    // 将这块内存用 StripedMap<SideTable> 类的构造方法进行初始化，
    // 初始化后，内存中就有值了
    new (SideTableBuf) StripedMap<SideTable>();
}

static StripedMap<SideTable>& SideTables() {
    // 取值时需要将这块内存进行类型转化
    return *reinterpret_cast<StripedMap<SideTable>*>(SideTableBuf);
}

// anonymous namespace
};


//
// The -fobjc-arc flag causes the compiler to issue calls to objc_{retain/release/autorelease/retain_block}
//
// 持有 block，其中会将 block 从栈上拷贝到堆上
id objc_retainBlock(id x) {
    return (id)_Block_copy(x);
}

//
// The following SHOULD be called by the compiler directly, but the request hasn't been made yet :-)
//

BOOL objc_should_deallocate(id object) {
    return YES;
}

// 既持有对象，又将其放入自动释放池
id
objc_retain_autorelease(id obj)
{
    return objc_autorelease(objc_retain(obj));
}


// 使 location 指针强引用 obj 对象
void
objc_storeStrong(id *location, id obj)
{
    // 判断 location 指针原来指向的对象是否是 obj，
    // 如果是，后面的工作就不用做了
    id prev = *location;
    if (obj == prev) {
        return;
    }
    // 先 retain 新值，使新值引用计数 +1
    objc_retain(obj);
    // location 指向新值
    *location = obj;
    // release 旧值，使旧值引用计数 -1
    objc_release(prev);
}


// Update a weak variable.
// If HaveOld is true, the variable has an existing value 
//   that needs to be cleaned up. This value might be nil.
// If HaveNew is true, there is a new value that needs to be 
//   assigned into the variable. This value might be nil.
// If CrashIfDeallocating is true, the process is halted if newObj is 
//   deallocating or newObj's class does not support weak references. 
//   If CrashIfDeallocating is false, nil is stored instead.

// location 指针弱引用 newObj
// 如果 HaveOld 是 true ，表示有旧值，旧值需要被清理
// 如果 HaveNew 是 true ，表示有新值，location 要指向新值，不过新值可能是 nil
// 如果 CrashIfDeallocating 是 true，表示如果新值正在被 dealloc，那么进程就直接挂掉；否则就不挂掉，新值替换成 nil
template <bool HaveOld, bool HaveNew, bool CrashIfDeallocating>
static id 
storeWeak(id *location, objc_object *newObj)
{
    // 如果新值旧值都没有，那玩个蛋，直接挂掉好了
    assert(HaveOld  ||  HaveNew);
    // 如果指明了没有新值，但是新值却不是 nil ，也需要报错
    if (!HaveNew) {
        assert(newObj == nil);
    }

    Class previouslyInitializedClass = nil;
    id oldObj;
    SideTable *oldTable;
    SideTable *newTable;

    // Acquire（获取、取得） locks for old and new values.
    // Order by lock address to prevent lock ordering problems. 
    // Retry if the old value changes underneath us.
 retry:
    // 如果有旧值，找到旧值所对应的 Side Table
    if (HaveOld) {
        oldObj = *location;
        oldTable = &SideTables()[oldObj]; // [] 是 StripedMap 类中重载了 [] 运算符
    } else {
        oldTable = nil;
    }
    // 如果有新值，找到新值所对应的 Side Table
    if (HaveNew) {
        newTable = &SideTables()[newObj];
    } else {
        newTable = nil;
    }

    // 将旧值、新值对应的 Side Table 加锁
    SideTable::lockTwo<HaveOld, HaveNew>(oldTable, newTable);

    // 如果有旧值，并且 location 并没有指向 oldObj，就解锁 Side Table 以后再从头再试一次
    // 不过这怎么可能呢，靠，oldObj 是通过 oldObj = *location 得到的，它还能变不成
    if (HaveOld  &&  *location != oldObj) {
        SideTable::unlockTwo<HaveOld, HaveNew>(oldTable, newTable);
        goto retry;
    }

    // Prevent a deadlock（防止死锁） between the weak reference machinery
    // and the +initialize machinery by ensuring that no 
    // weakly-referenced object has an un-+initialized isa.
    
    // 如果有新值，而且新值不是 nil
    if (HaveNew  &&  newObj) {
        Class cls = newObj->getIsa();
        // 判断 新值的类 是否已经被 Initialized
        // 如果还没有被 Initialized ，就尴尬了，只能手动 Initialize 一下，然后重新来过
        // 防止死锁是指这段代码
        // 第一次走，第一个判断条件 previouslyInitializedClass 是 nil，就会走第二个判断条件
        // 第二次走，照理说 previouslyInitializedClass 应该与 cls 是相等的，第二个判断条件压根不会走
        // 可能因为某种原因比如 +initialize called storeWeak on an instance of itself，它还没完成 initialize
        // 这种情况下，如果直接判断第二个判断条件，还是符合的，那么又会再 initialize 一次，如此反复，无穷尽也
        if (cls != previouslyInitializedClass  &&  
            !((objc_class *)cls)->isInitialized()) 
        {
            SideTable::unlockTwo<HaveOld, HaveNew>(oldTable, newTable);
            // initialize 类 cls，传入 newObj 会使过程快一些
            _class_initialize(_class_getNonMetaClass(cls, (id)newObj));

            // If this class is finished with +initialize then we're good.
            // If this class is still running +initialize on this thread 
            // (i.e. +initialize called storeWeak on an instance of itself)
            // then we may proceed but it will appear initializing and 
            // not yet initialized to the check above.
            // Instead set previouslyInitializedClass to recognize it on retry.
            previouslyInitializedClass = cls;

            goto retry;
        }
    }

    // Clean up old value, if any.
    if (HaveOld) {
        // 解除 weak_table 中，location 对 oldObj 的弱引用
        weak_unregister_no_lock(&oldTable->weak_table, oldObj, location);
    }

    // Assign new value, if any.
    if (HaveNew) {
        // 在 newTable->weak_table 中注册 location 对 newObj 的弱引用
        newObj = (objc_object *)weak_register_no_lock(&newTable->weak_table, 
                                                      (id)newObj, location, 
                                                      CrashIfDeallocating);
        // weak_register_no_lock returns nil if weak store should be rejected

        // Set is-weakly-referenced bit in refcount table.
        // tagged pointer 介绍 http://www.infoq.com/cn/articles/deep-understanding-of-tagged-pointer/
        if (newObj  &&  !newObj->isTaggedPointer()) {
            // 在 side table 中标记有弱引用
            newObj->setWeaklyReferenced_nolock();
        }

        // Do not set *location anywhere else. That would introduce a race.
        
        // location 指向 newObj，即 location 里存的值是 newObj 的地址
        // newObj 可能是 nil
        *location = (id)newObj;
    }
    else {
        // No new value. The storage is not changed.
    }
    
    SideTable::unlockTwo<HaveOld, HaveNew>(oldTable, newTable);

    return (id)newObj;
}


/** 
 * This function stores a new value into a __weak variable. It would
 * be used anywhere a __weak variable is the target of an assignment.
 * 
 * @param location The address of the weak pointer itself
 * @param newObj The new object this weak ptr should now point to
 * 
 * @return \e newObj
 */
// __weak 指针 location 指向对象 newObj，也就是给 newObj 添加一个弱引用 location
// location 是 weak pointer 自己的地址
id
objc_storeWeak(id *location, id newObj)
{

    return storeWeak<true/*old*/,
                    true/*new*/,
                    true/*crash*/>
        (location, (objc_object *)newObj);
}


/** 
 * This function stores a new value into a __weak variable. 
 * If the new object is deallocating or the new object's class 
 * does not support weak references, stores nil instead.
 * 
 * @param location The address of the weak pointer itself
 * @param newObj The new object this weak ptr should now point to
 * 
 * @return The value stored (either the new object or nil)
 */
id
objc_storeWeakOrNil(id *location, id newObj)
{
    return storeWeak<true/*old*/,
                    true/*new*/,
                    false/*crash*/>
        (location, (objc_object *)newObj);
}


/** 
 * Initialize a fresh weak pointer to some object location. 
 * It would be used for code like: 
 *
 * (The nil case) 
 * __weak id weakPtr;
 * (The non-nil case) 
 * NSObject *o = ...;
 * __weak id weakPtr = o;
 * 
 * This function IS NOT thread-safe with respect to concurrent 
 * modifications to the weak variable. (Concurrent weak clear is safe.)
 *
 * @param location Address of __weak ptr. 
 * @param newObj Object ptr. 
 */
// location 弱引用 newObj，location 之前没有弱引用其他对象
id
objc_initWeak(id *location, id newObj)
{
    if (!newObj) {
        *location = nil;
        return nil;
    }

    return storeWeak<false/*old 没有 old 对象*/, true/*new*/, true/*crash*/>
        (location, (objc_object*)newObj);
}

// 与 objc_initWeak 的区别是允许 newObj 是 nil
id
objc_initWeakOrNil(id *location, id newObj)
{
    if (!newObj) {
        *location = nil;
        return nil;
    }

    return storeWeak<false/*old*/, true/*new*/, false/*crash*/>
        (location, (objc_object*)newObj);
}


/** 
 * Destroys the relationship between a weak pointer
 * and the object it is referencing in the internal weak
 * table. If the weak pointer is not referencing anything, 
 * there is no need to edit the weak table. 
 *
 * This function IS NOT thread-safe with respect to（关于） concurrent
 * modifications to the weak variable. (Concurrent weak clear is safe.)
 * 
 * @param location The weak pointer address. 
 */
// 清除 location 的弱引用，即 location 不指向任何对象，*location 变成 nil
void
objc_destroyWeak(id *location)
{
    (void)storeWeak<true/*old*/, false/*new*/, false/*crash*/>
        (location, nil);
}

// 取得弱引用指向的对象
id
objc_loadWeakRetained(id *location)
{
    id result;

    SideTable *table;
    
 retry:
    result = *location;
    if (!result) return nil;
    
    table = &SideTables()[result];
    
    table->lock();
    // 再检查一下，可能是尽可能减少 并行开发 的时候出错（线程安全 ？）
    if (*location != result) {
        table->unlock();
        goto retry;
    }

    // *location 存有对象，但并不代表 location 对这个对象有弱引用，所以需要去 weak table 中查是否真的有弱引用关系
    result = weak_read_no_lock(&table->weak_table, location);

    table->unlock();
    return result;
}

/** 
 * This loads the object referenced by a weak pointer and returns it, after
 * retaining and autoreleasing the object to ensure that it stays alive
 * long enough for the caller to use it. This function would be used
 * anywhere a __weak variable is used in an expression.
 * 
 * @param location The weak pointer address
 * 
 * @return The object pointed to by \e location, or \c nil if \e location is \c nil.
 */
// 取得 location 弱引用的对象，并将其放到自动释放池
id
objc_loadWeak(id *location)
{
    if (!*location) return nil;
    return objc_autorelease(objc_loadWeakRetained(location));
}


/** 
 * This function copies a weak pointer from one location to another,
 * when the destination doesn't already contain a weak pointer. It
 * would be used for code like:
 *
 *  __weak id src = ...;
 *  __weak id dst = src;
 * 
 * This function IS NOT thread-safe with respect to concurrent 
 * modifications to the destination variable. (Concurrent weak clear is safe.)
 *
 * @param dst The destination variable.
 * @param src The source variable.
 */
// 使 dst 也弱引用 src 弱引用的对象，好像拷贝了一份弱引用关系一样
//    src -----> obj
//                ^
//                |
//    dst ---------
void
objc_copyWeak(id *dst, id *src)
{
    // 找到 src 弱引用的对象 obj
    id obj = objc_loadWeakRetained(src);
    
    // dst 也弱引用 obj
    objc_initWeak(dst, obj);
    
    // 为什么需要 release obj，上面也没有 retain obj 呀
    objc_release(obj);
}

/** 
 * Move a weak pointer from one location to another.
 * Before the move, the destination must be uninitialized.
 * After the move, the source is nil.
 *
 * This function IS NOT thread-safe with respect to concurrent 
 * modifications to either weak variable. (Concurrent weak clear is safe.)
 *
 */
// 使 dst 弱引用 src 弱引用的对象，src 不再弱引用该对象，不要与 objc_copyWeak 混淆
void
objc_moveWeak(id *dst, id *src)
{
    // 先拷贝弱引用
    objc_copyWeak(dst, src);
    
    // 销毁 src 的弱引用
    objc_destroyWeak(src);
    
    // src 指向 nil
    *src = nil;
}


/***********************************************************************
   Autorelease pool implementation

   A thread's autorelease pool is a stack of pointers. 
   Each pointer is either an object to release, or POOL_SENTINEL which is 
     an autorelease pool boundary.
   A pool token is a pointer to the POOL_SENTINEL for that pool. When 
     the pool is popped, every object hotter than the sentinel is released.
   The stack is divided into a doubly-linked list of pages. Pages are added 
     and deleted as necessary. 
   Thread-local storage points to the hot page, where newly autoreleased 
     objects are stored. 
 
   Thread-local storage （TLS）指向 hotpage，新的 autorelease 对象被添加进 hotpage 中。
 
**********************************************************************/

BREAKPOINT_FUNCTION(void objc_autoreleaseNoPool(id obj));

namespace {

struct magic_t {
    static const uint32_t M0 = 0xA1A1A1A1;
#   define M1 "AUTORELEASE!"
    static const size_t M1_len = 12;
    uint32_t m[4];
    
    // 这代码写的真有C的风格啊
    // 构造函数中，将M0填充到 m[0]，M1填充到 M[1] M[2] M[3]
    // 结果是 m 中内容是{0xA1A1A1A1, 'AUTO', 'RELE', 'ASE!'}
    magic_t() {
        assert(M1_len == strlen(M1));
        assert(M1_len == 3 * sizeof(m[1]));

        m[0] = M0;
        strncpy((char *)&m[1], M1, M1_len);
    }

    // 析构，全部置为0
    ~magic_t() {
        m[0] = m[1] = m[2] = m[3] = 0;
    }

    bool check() const {
        // 检查 m 中的数据是否与构造时的一致
        return (m[0] == M0 && 0 == strncmp((char *)&m[1], M1, M1_len));
    }

    // DEBUG的时候 m 中每个元素都检查，release的时候只检查 m[0]
    bool fastcheck() const {
#if DEBUG
        return check();
#else
        return (m[0] == M0);
#endif
    }

#   undef M1
};
    
#pragma mark - AutoreleasePoolPage Private

// 参考博客：http://www.cocoachina.com/ios/20141031/10107.html
//         http://blog.leichunfeng.com/blog/2015/05/31/objective-c-autorelease-pool-implementation-principle/

// 有一点需要明确，线程和 page 链表的确是一一对应的，但 TLS 里只存了 hotPage，即链表最末的 page ，应该是为了性能考虑，
// O(n) 和 O(1) 差距还是很大的。一个线程需要存新的 autorelease 对象时，会先从 TLS 里取出 hotPage，如果没有 hotPage，就会新建一个 page，即新建了这个 page 链表，
// 因为线程和 page 链表一一对应，所以压根儿不需要加锁，因为其他线程是不会操作当前线程的 page 链表的

// Set this to 1 to mprotect() autorelease pool contents
#define PROTECT_AUTORELEASEPOOL 0

class AutoreleasePoolPage 
{
    // POOL_SENTINEL 用来分隔每个AutoreleasePool
    // 如果一个线程有3个AutoreleasePoolPage，其中有2个POOL_SENTINEL，则表明有2个AutoreleasePool
#define POOL_SENTINEL nil // SENTINEL 哨兵、守卫、标记
    static pthread_key_t const key = AUTORELEASE_POOL_KEY;
    static uint8_t const SCRIBBLE = 0xA3;  // 0xA3A3A3A3 after releasing
    
    static size_t const SIZE = 
#if PROTECT_AUTORELEASEPOOL
        PAGE_MAX_SIZE;  // must be multiple of vm page size （vm page size 虚拟内存一页的大小 好像是4K）
#else
        PAGE_MAX_SIZE;  // size and alignment, power of 2 (2的幂次方)
#endif
    // SIZE 大小可以装下几个 id 类型
    static size_t const COUNT = SIZE / sizeof(id);

    // magic 放在这里挺巧妙的，由于前面的变量都是静态变量，存储的位置必然有所不同
    // 所以我猜测，magic在内存中应该位于page对象的头部，它起到了一个标志的作用
    // 一切正常的情况下，magic所占的16个字节中存的是{0xA1A1A1A1, 'AUTO', 'RELE', 'ASE!'}
    // 如果当前page的内存被冲毁，magic就会首当其冲发生改变
    magic_t const magic;
    
    // 指向最新添加的 autoreleased 对象的下一个位置，初始化时指向 begin()
    id *next;
    
    // AutoreleasePoolPage 和线程是一一对应的
    pthread_t const thread; // 所属线程
    
    // AutoreleasePool并没有单独的结构，而是由若干个AutoreleasePoolPage以双向链表的形式组合而成（分别对应结构中的parent指针和child指针）
    AutoreleasePoolPage * const parent; // 父page
    AutoreleasePoolPage *child; // 子page
    
    uint32_t const depth;
    
    uint32_t hiwat; // // high water mark 水位线

    // SIZE-sizeof(*this) bytes of contents follow

    // AutoreleasePoolPage每个对象会开辟4096字节内存（也就是虚拟内存一页的大小），除了上面的实例变量所占空间，剩下的空间全部用来储存autorelease对象的地址
    // new 方法也能被重载，也是开了眼界
    static void * operator new(size_t size) {
        
        /* extern void *malloc_zone_memalign(malloc_zone_t *zone, size_t alignment, size_t size) __OSX_AVAILABLE_STARTING(__MAC_10_6, __IPHONE_3_0);

         * Allocates a new pointer of size size whose address is an exact multiple of alignment.
         * alignment must be a power of two and at least as large as sizeof(void *).
         * zone must be non-NULL.
         */
        return malloc_zone_memalign(malloc_default_zone(), SIZE, SIZE);
    }
    
    // delete方法也重载  丧心病狂
    static void operator delete(void * p) {
        return free(p);
    }

    // 保护当前对象所在的这片内存，即设置为只读
    inline void protect() {
#if PROTECT_AUTORELEASEPOOL
        // int	mprotect(void *, size_t, int)
        // 将从 this 指针开始，长度为SIZE的内存设为只读
        mprotect(this, SIZE, PROT_READ);
        check();
#endif
    }

    // 取消保护，内存权限设置为可读可写
    inline void unprotect() {
#if PROTECT_AUTORELEASEPOOL
        check();
        mprotect(this, SIZE, PROT_READ | PROT_WRITE);
#endif
    }

    // 构造函数
    AutoreleasePoolPage(AutoreleasePoolPage *newParent) 
        : magic(), next(begin()), thread(pthread_self()),
          parent(newParent), child(nil), 
          depth(parent ? 1+parent->depth : 0), // 有父page，则depth是父page的depth+1，否则它就是根的page，depth为0
          hiwat(parent ? parent->hiwat : 0) // 奇怪，如果都继承父page的hiwat，而根page的hiwat也是0，岂不是大家的hiwat都是0，有什么意义呢
    { 
        if (parent) {
            // 检查父page是否正确，主要是检查它的magic是否变化，以及线程是否错误
            parent->check();
            
            // 必须保证父page没有子page，否则后面就不能玩了
            assert(!parent->child);
            
            // 取消父page的内存保护，设置为可读可写，parent->child = this; 才能成功
            parent->unprotect();
            parent->child = this;
            
            // 将父page的内存重新保护起来
            parent->protect();
        }
        // 自己的内存也保护起来
        protect();
    }

    ~AutoreleasePoolPage() 
    {
        check();
        unprotect();
        assert(empty());

        // Not recursive: we don't want to blow out the stack 
        // if a thread accumulates a stupendous amount of garbage
        assert(!child);
    }

    // die 参数应该是决定 要不要让进程直接挂掉
    void busted(bool die = true) 
    {
        magic_t right; // 正确的magic
        // 打印出当前的magic、正确的magic、page存储的线程、当前的线程
        (die ? _objc_fatal : _objc_inform)
            ("autorelease pool page %p corrupted\n"
             "  magic     0x%08x 0x%08x 0x%08x 0x%08x\n"
             "  should be 0x%08x 0x%08x 0x%08x 0x%08x\n"
             "  pthread   %p\n"
             "  should be %p\n", 
             this, 
             magic.m[0], magic.m[1], magic.m[2], magic.m[3], 
             right.m[0], right.m[1], right.m[2], right.m[3], 
             this->thread, pthread_self());
    }

    // 检查 magic 是否完整，以及
    // 参数指定是否让进程直接挂掉，构造函数和析构函数里都是默认值，只有在 print() 里是 false
    // 调用者：AutoreleasePoolPage::AutoreleasePoolPage() / print() / AutoreleasePoolPage::~AutoreleasePoolPage()
    void check(bool die = true)
    {
        // 如果 magic.check() 返回 false，或者 pthread_equal 返回 false，都会造成 busted
        // 即 magic 被冲毁，或者 page 里存的线程并不是当前线程
        if (!magic.check() || !pthread_equal(thread, pthread_self())) {
            busted(die);
        }
    }

    void fastcheck(bool die = true) 
    {
        if (! magic.fastcheck()) {
            busted(die);
        }
    }


    id * begin() {
        // 返回存储autorelease对象的内存区域的头部地址，因为page的头部存了page对象自己的一些东西，大小为sizeof(*this)
        return (id *) ((uint8_t *)this+sizeof(*this));
    }

    id * end() {
        // 返回page的尾部地址，SIZE是page的大小
        return (id *) ((uint8_t *)this+SIZE);
    }

    bool empty() {
        // next的位置还在刚开始的begin()，说明里面没存一个autorelease对象
        return next == begin();
    }

    bool full() {
        // 存满了
        return next == end();
    }

    // 判断存的是否少于一半
    bool lessThanHalfFull() {
        return (next - begin() < (end() - begin()) / 2);
    }

    // 添加autorelease对象，返回值是这个对象在page中的地址
    id *add(id obj)
    {
        // 满了就不能再添加了
        assert(!full());
        unprotect();
        id *ret = next;  // faster than `return next-1` because of aliasing
        // 将obj存储在next的位置
        *next++ = obj;
        protect();
        return ret;
    }

    void releaseAll() 
    {
        releaseUntil(begin());
    }

    // 链表从 hotPage 开始往前删autorelease对象（不是page），直到stop对象（包括stop对象）
    void releaseUntil(id *stop) 
    {
        // Not recursive: we don't want to blow out the stack 
        // if a thread accumulates a stupendous amount of garbage
        
        // this->next != stop ，看意思，应该是当stop也删掉了以后，this->next才会指向stop
        // 因为next指向的是最后一个autorelease对象的下一个位置
        while (this->next != stop) {
            // Restart from hotPage() every time, in case（万一、免得） -release
            // autoreleased more objects
            // 每轮循环都取hotPage,防止删多了
            AutoreleasePoolPage *page = hotPage();

            // fixme I think this `while` can be `if`, but I can't prove it
            // 链表从hotPage开始从后往前，找到第一个不是空的page
            while (page->empty()) {
                page = page->parent;
                setHotPage(page);
            }

            page->unprotect();
            // 找到page中的最后一个autorelease对象
            id obj = *--page->next;
            // 将page->next后面的内存置为SCRIBBLE，SCRIBBLE 等于 0xA3
            memset((void*)page->next, SCRIBBLE, sizeof(*page->next));
            page->protect();

            // 如果obj不是标记的话，则将它释放
            if (obj != POOL_SENTINEL) {
                // 里面实际是向 obj 发送了 release 消息
                objc_release(obj);
            }
        }

        setHotPage(this);

#if DEBUG
        // 循环观察链表中当前page之后的所有page，保证它们全都是空的
        // we expect any children to be completely empty
        for (AutoreleasePoolPage *page = child; page/* page != nil */; page = page->child) {
            assert(page->empty());
        }
#endif
    }

    // 删除链表中从当前page（包括当前page）开始的所有page
    void kill() 
    {
        // Not recursive: we don't want to blow out the stack 
        // if a thread accumulates a stupendous amount of garbage
        
        // 找到链表中最后一个AutoreleasePoolPage
        AutoreleasePoolPage *page = this;
        while (page->child) {
            page = page->child;
        }

        // 链表从后往前，逐个删除page
        AutoreleasePoolPage *deathptr;
        do {
            deathptr = page;
            page = page->parent;
            if (page) {
                page->unprotect();
                // 父page的child指向nil，即断开父page和当前page的链接关系
                page->child = nil;
                page->protect();
            }
            // delete也被重载了，实际上是 free deathptr
            delete deathptr;
        } while (deathptr != this); // 直到连当前的page也被释放了，free只是释放内存，deathptr存的地址依然没有变，所以还可以进行比较
    }

    // TLS(Thread Local Storage 线程局部存储) 销毁时（估计也就是线程销毁的时候），会调用该方法，对 AutoreleasePoolPage 链表进行清理
    static void tls_dealloc(void *p) 
    {
        // reinstate（恢复，复原） TLS value while we work
        
        // 将该 page 设为hotPage，在 releaseUntil()方法中会取得hotPage
        setHotPage((AutoreleasePoolPage *)p);

        // 找到codePage
        if (AutoreleasePoolPage *page = coldPage()) {
            // 如果page不是空的，就将coldPage开始到hotPage之间的所有autorelease对象都pop出去
            if (!page->empty()) {
                pop(page->begin()); // pop all of the pools
            }
            if (DebugMissingPools || DebugPoolAllocation) {
                // pop() killed the pages already
            } else {
                // 删除coldPage开始的所有page
                page->kill();  // free all of the pages
            }
        }
        
        // 将hotPage设为nil，作者的意思是防止 TLS 析构死循环，不明白是什么意思
        // clear TLS value so TLS destruction doesn't loop
        setHotPage(nil);
    }

    // 得到指定指针所在page
    static AutoreleasePoolPage *pageForPointer(const void *p) 
    {
        return pageForPointer((uintptr_t)p);
    }

    // 得到指定指针所在page
    static AutoreleasePoolPage *pageForPointer(uintptr_t p) 
    {
        AutoreleasePoolPage *result;
        // 先取余，得到 p 指针到其所在的page的头部的偏移量
        uintptr_t offset = p % SIZE;

        assert(offset >= sizeof(AutoreleasePoolPage));

        // p 减去偏移量，就是其所在的page的首地址
        result = (AutoreleasePoolPage *)(p - offset);
        result->fastcheck();

        return result;
    }

    // 取得 hotPage，TLS 存的是 hotPage，而不是链表的头节点，应该是为了性能考虑
    static inline AutoreleasePoolPage *hotPage() 
    {
        // 用 tls_get_direct 取出 TLS 里存的当前线程的 hotPage，
        // 这个很关键，即从这可以看出，每个线程拥有独立的 page 链表
        AutoreleasePoolPage *result = (AutoreleasePoolPage *)
            tls_get_direct(key);
        if (result) result->fastcheck();
        return result;
    }

    // 设置 hotPage，除了在 tls_dealloc 方法中将一个不知道从哪儿传入的 page 设为了 hotPage
    // 其他调用该方法的地方，都是将链表的最后一个 page 设为 hotPage
    static inline void setHotPage(AutoreleasePoolPage *page) 
    {
        if (page) page->fastcheck();
        tls_set_direct(key, (void *)page);
    }

    // 按代码看，coldPage貌似就是链表中第一个page
    static inline AutoreleasePoolPage *coldPage() 
    {
        AutoreleasePoolPage *result = hotPage();
        if (result) {
            // 循环查找链表的第一个 page
            while (result->parent) {
                result = result->parent;
                result->fastcheck();
            }
        }
        return result;
    }


    // 快速添加autorelease对象
    static inline id *autoreleaseFast(id obj)
    {
        AutoreleasePoolPage *page = hotPage();
        if (page && !page->full()) {
            // 如果有 hotPage ，并且它还没满，就将 obj 添加进其中
            return page->add(obj);
        } else if (page) {
            // 如果有 hotPage，但是已经满了，就新创建一个 page，
            // 将其设置为hotPage，并将obj添加进其中
            return autoreleaseFullPage(obj, page);
        } else {
            // 如果连 hotPage 都没有，也就是说链表中一个page都没有，
            // 就新创建一个page，它就是链表的头，将其设置为hotPage，并将obj添加进其中
            return autoreleaseNoPage(obj);
        }
    }

    static __attribute__((noinline))
    // 向满了的 page 中添加对象
    id *autoreleaseFullPage(id obj, AutoreleasePoolPage *page)
    {
        // The hot page is full. 
        // Step to the next non-full page, adding a new page if necessary.
        // Then add the object to that page.
        assert(page == hotPage());
        assert(page->full()  ||  DebugPoolAllocation);

        // 从 hotPage 开始找，找到一个没有满的 page ，没有的话，就新建一个 page
        do {
            if (page->child) {
                page = page->child;
            } else {
                page = new AutoreleasePoolPage(page);
            }
        } while (page->full());

        // 将这个 page 设为 hotPage
        setHotPage(page);
        
        // 将 obj 添加进其中
        return page->add(obj);
    }

    static __attribute__((noinline))
    // 没有 page 时添加对象
    id *autoreleaseNoPage(id obj)
    {
        // No pool in place.
        assert(!hotPage());

        // 这段是一点都不懂，不知道干嘛了，应该也是 debug 的时候开启了 DebugMissingPools 这个选项
        // 在这种情况（一个pool都没有）时，会报错
        if (obj != POOL_SENTINEL  &&  DebugMissingPools) {
            // We are pushing an object with no pool in place, 
            // and no-pool debugging was requested by environment.
            _objc_inform("MISSING POOLS: Object %p of class %s "
                         "autoreleased with no pool in place - "
                         "just leaking - break on "
                         "objc_autoreleaseNoPool() to debug", 
                         (void*)obj, object_getClassName(obj));
            objc_autoreleaseNoPool(obj);
            return nil;
        }

        // Install the first page.
        // 新建一个 page ，这个 page 就是链表的第一个 page 了，因为没有 parent ，所以传 nil
        // new 也是被重载了的，里面实际是调用了 malloc_zone_memalign 函数
        // 堆中分配，并且做了对齐
        AutoreleasePoolPage *page = new AutoreleasePoolPage(nil);
        
        // 将其设置为 hotPage
        setHotPage(page);

        // Push an autorelease pool boundary if it wasn't already requested.
        
        // 添加一个 POOL_SENTINEL, 这玩意儿是分隔 pool 的标识符，表示从这里开始是一个新 pool
        if (obj != POOL_SENTINEL) {
            page->add(POOL_SENTINEL);
        }

        // obj 添加进新创建的 page 中
        // Push the requested object.
        return page->add(obj);
    }


    static __attribute__((noinline)) // 强制不内联
    // 向新的 page 中添加对象
    id *autoreleaseNewPage(id obj)
    {
        AutoreleasePoolPage *page = hotPage();
        if (page) {
            // 如果存在 hotPage，就当 hotPage 满了的情况考虑，
            // 很纳闷的情况是，如果 hotPage没满，在autoreleaseFullPage中的断言会报错的啊
            return autoreleaseFullPage(obj, page);
        } else {
            // 没有 hotPage, 则当链表中没有 page 的情况考虑
            return autoreleaseNoPage(obj);
        }
    }

#pragma mark - AutoreleasePoolPage Public
    
public: // 前面都是私有成员和方法，下面开始是公开的方法
    
    static inline id autorelease(id obj)
    {
        assert(obj);
        // 如果是 TaggedPointer，就直接报错，因为 TaggedPointer 并不是真正的对象，
        // 没有引用计数的，所以也不能 autorelease
        assert(!obj->isTaggedPointer());
        // 将 obj 添加进 page 中
        id *dest __unused = autoreleaseFast(obj);
        assert(!dest  ||  *dest == obj);
        return obj;
    }


    static inline void *push() 
    {
        id *dest;
        if (DebugPoolAllocation) {
            // 如果开启了 DebugPoolAllocation ，则每个 pool 都放入一个新建的 page 中
            // Each autorelease pool starts on a new pool page.
            dest = autoreleaseNewPage(POOL_SENTINEL);
        } else {
            // 添加一个 POOL_SENTINEL 进 page 中，表示一个 pool 的开始
            dest = autoreleaseFast(POOL_SENTINEL);
        }
        assert(*dest == POOL_SENTINEL);
        return dest;
    }

    // 链表从hotPage开始往前，pop出所有autorelease对象，直到token对象（包括token对象）
    static inline void pop(void *token) 
    {
        AutoreleasePoolPage *page;
        id *stop;

        // 先找到指定的token指针所在page
        page = pageForPointer(token);
        stop = (id *)token;
        
        // 如果开启了 DebugPoolAllocation ，并且传入的 token 并不是 POOL_SENTINEL
        // 则直接挂掉，这是什么道理呢
        if (DebugPoolAllocation  &&  *stop != POOL_SENTINEL) {
            // This check is not valid with DebugPoolAllocation off
            // after an autorelease with a pool page but no pool in place.
            _objc_fatal("invalid or prematurely-freed（提前释放） autorelease pool %p; ",token);
        }

        // 调试时用的，在 printHiwat 里打印了一下堆栈信息
        if (PrintPoolHiwat) printHiwat();

        // 实际清理对象是在这里面干的
        page->releaseUntil(stop);

        // 把空的page都删了，清理内存
        // memory: delete empty children
        if (DebugPoolAllocation  &&  page->empty()) {
            // special case: delete everything during page-per-pool debugging
            AutoreleasePoolPage *parent = page->parent;
            page->kill();
            setHotPage(parent);
        } else if (DebugMissingPools  &&  page->empty()  &&  !page->parent) {
            // special case: delete everything for pop(top) 
            // when debugging missing autorelease pools
            page->kill();
            setHotPage(nil);
        } 
        else if (page->child) {
            // hysteresis: keep one empty child if page is more than half full
            // 如果当前的page已经用了还没一半，就把后面的page都删了
            if (page->lessThanHalfFull()) {
                page->child->kill();
            }
            // 如果还有存在下下个page，则是一定要删除的
            else if (page->child->child) {
                page->child->child->kill();
            }
            // 有三种情况：
            //     一、page 用量小于一半，则肯定删除child及其后的所有page
            //     二、page 用量大于一半
            //        1. 存在孙子page ，则删除孙子page及其后的所有page
            //        2. 不存在孙子page，则只有一个子page，那么就将其保留，
            //           也就是什么都不干，所以作者都没写，不要误解了
        }
    }

    // 初始化 AutoreleasePoolPage , 只在 arr_init() 函数中调用了一次
    static void init()
    {
        // 函数原型：
        // pthread_key_init_np(TLS_DIRECT_KEY, &_objc_pthread_destroyspecific);
        // 好像是指定了 TLS 销毁时，会调用tls_dealloc方法，进行清理
        int r __unused = pthread_key_init_np(AutoreleasePoolPage::key, 
                                             AutoreleasePoolPage::tls_dealloc);
        assert(r == 0);
    }

    // 打印当前 page 的信息，
    // 调用者：printAll()
    void print() 
    {
        _objc_inform("[%p]  ................  PAGE %s %s %s",
                     this/*当前的 page地址 */,
                     full() ? "(full)" : "" /* 满了没 */,
                     this == hotPage() ? "(hot)" : "" /* 当前 page 是否是 hotPage */,
                     this == coldPage() ? "(cold)" : "") /* 当前 page 是否是 coldPage */;
        
        check(false); // 进行检查，但参数是 false，即有错也不直接挂掉
        
        // 打印出 page 中每个对象的信息
        for (id *p = begin(); p < next; p++) {
            if (*p == POOL_SENTINEL) {
                // 如果是 POOL_SENTINEL ，就把它的地址打出来
                _objc_inform("[%p]  ################  POOL %p", p, p);
            } else {
                // 如果是普通对象，就打印出地址和它的类型
                _objc_inform("[%p]  %#16lx  %s", 
                             p, (unsigned long)*p, object_getClassName(*p));
            }
        }
    }

    // 循环遍历每个 page，统计一共存了多少 autorelease 对象
    // 打印出每个 page 的信息
    static void printAll()
    {        
        _objc_inform("##############");
        _objc_inform("AUTORELEASE POOLS for thread %p", pthread_self());

        AutoreleasePoolPage *page;
        
        // ptrdiff_t是C/C++标准库中定义的一个与机器相关的数据类型。ptrdiff_t类型变量通常用来保存两个指针减法操作的结果。ptrdiff_t定义在stddef.h（cstddef）这个文件内。ptrdiff_t通常被定义为long int类型。
        ptrdiff_t objects = 0;
        
        // 循环遍历每个page，统计一共存了多少 autorelease 对象
        for (page = coldPage(); page /* page != nil */; page = page->child) {
            objects += page->next - page->begin();
        }
        _objc_inform("%llu releases pending.", (unsigned long long)objects);

        // 打印出每个 page 的信息
        for (page = coldPage(); page; page = page->child) {
            page->print();
        }

        _objc_inform("##############");
    }

    static void printHiwat()
    {
        // Check and propagate high water mark
        // Ignore high water marks under 256 to suppress noise.
        AutoreleasePoolPage *p = hotPage();
        uint32_t mark = p->depth*COUNT + (uint32_t)(p->next - p->begin());
        if (mark > p->hiwat  &&  mark > 256) {
            for( ; p; p = p->parent) {
                p->unprotect();
                p->hiwat = mark;
                p->protect();
            }
            
            _objc_inform("POOL HIGHWATER: new high water mark of %u "
                         "pending autoreleases for thread %p:", 
                         mark, pthread_self());
            
            // 以下代码是打印出当前线程的堆栈信息，极为有用
            
            void *stack[128];
            // int backtrace(void **buffer,int size)
            // 该函数用于获取当前线程的调用堆栈,获取的信息将会被存放在buffer中,它是一个指针列表。参数 size 用来指定buffer中可以保存多少个void* 元素。函数返回值是实际获取的指针个数,最大不超过size大小
            int count = backtrace(stack, sizeof(stack)/sizeof(stack[0]));
            
            // backtrace_symbols将从backtrace函数获取的信息转化为一个字符串数组. 参数buffer应该是从backtrace函数获取的指针数组,size是该数组中的元素个数(backtrace的返回值)
            char **sym = backtrace_symbols(stack, count);
            
            for (int i = 0; i < count; i++) {
                _objc_inform("POOL HIGHWATER:     %s", sym[i]);
            }
            free(sym);
        }
    }

#undef POOL_SENTINEL
};

// anonymous namespace
};


/***********************************************************************
* Slow paths for inline control
**********************************************************************/

// objc_object 结构体里的部分方法的实现，统一都写在 objc_object.h 文件里不好么....

#if SUPPORT_NONPOINTER_ISA

// 处理溢出的方法是再调一次 rootRetain
// 第二个参数传 true 代表指定在 rootRetain 中处理溢出
// 我靠，完全不明白这个方法存在的意义
NEVER_INLINE id 
objc_object::rootRetain_overflow(bool tryRetain)
{
    return rootRetain(tryRetain, true);
}

// 处理 release 时的向下溢出
NEVER_INLINE bool 
objc_object::rootRelease_underflow(bool performDealloc)
{
    return rootRelease(performDealloc, true);
}


// Slow path of clearDeallocating() 
// for objects with indexed isa
// that were ever weakly referenced 
// or whose retain count ever overflowed to the side table.

// 如果 isa 中有存引用计数，则会调用这个方法处理弱引用和清空引用计数
// 但是为什么说它 slow 呢，这我就理解不了了
NEVER_INLINE void
objc_object::clearDeallocating_slow()
{
    assert(isa.indexed  &&  (isa.weakly_referenced || isa.has_sidetable_rc));

    SideTable& table = SideTables()[this];
    table.lock();
    // 如果有弱引用，则清空 side table 中该对象对应的弱引用表，将指向该对象的指针置为 nil
    if (isa.weakly_referenced) {
        // 和 sidetable_clearDeallocating 方法一样，都是调用 weak_clear_no_lock 方法，
        // 不同的是这里 isa.weakly_referenced 标记了是否有弱引用
        // 而 sidetable_clearDeallocating 方法是根据 refcnts 里是否存了该对象来判断的
        
        // 将 weak table 中该对象的所有记录都删除，
        // 并且会做将__weak pointer置为 nil 的重要操作
        weak_clear_no_lock(&table.weak_table, (id)this);
    }
    // 将该对象的引用计数清空
    if (isa.has_sidetable_rc) {
        table.refcnts.erase(this);
    }
    table.unlock();
}

#endif

__attribute__((noinline,used))
id 
objc_object::rootAutorelease2()
{
    assert(!isTaggedPointer());
    // 将当前对象添加进了当前的 autoreleasepage 中
    return AutoreleasePoolPage::autorelease((id)this);
}


BREAKPOINT_FUNCTION(
    void objc_overrelease_during_dealloc_error(void)
);


NEVER_INLINE
bool 
objc_object::overrelease_error()
{
    _objc_inform_now_and_on_crash("%s object %p overreleased while already deallocating; break on objc_overrelease_during_dealloc_error to debug", object_getClassName((id)this), this);
    objc_overrelease_during_dealloc_error();
    return false;  // allow rootRelease() to tail-call this
}


/***********************************************************************
* Retain count operations for side table.
**********************************************************************/


#if DEBUG
// Used to assert that an object is not present in the side table.
bool
objc_object::sidetable_present()
{
    bool result = false;
    SideTable& table = SideTables()[this];

    table.lock();

    RefcountMap::iterator it = table.refcnts.find(this);
    if (it != table.refcnts.end()) result = true;

    if (weak_is_registered_no_lock(&table.weak_table, (id)this)) result = true;

    table.unlock();

    return result;
}
#endif

#if SUPPORT_NONPOINTER_ISA

// 将对象所在的 side table 加锁
void 
objc_object::sidetable_lock()
{
    SideTable& table = SideTables()[this];
    table.lock();
}

// 将对象所在的 side table 解锁
void 
objc_object::sidetable_unlock()
{
    SideTable& table = SideTables()[this];
    table.unlock();
}


// Move the entire retain count to the side table, 
// as well as isDeallocating and weaklyReferenced.
// 向 side table 中加上指定的引用计数（从 isa 中的全部引用计数移到 side table，但这个函数中只做side table中引用计数增加的步骤，不做 isa 中的引用计数减少的步骤）
// 和 sidetable_addExtraRC_nolock 不一样，不要混淆
void 
objc_object::sidetable_moveExtraRC_nolock(size_t extra_rc, // 引用计数
                                          bool isDeallocating, // 是否在 dealloc
                                          bool weaklyReferenced) // 是否有弱引用
{
    assert(!isa.indexed);        // should already be changed to not-indexed
    SideTable& table = SideTables()[this];

    // DenseMap 的父类 DenseMapBase 里重载了 [] 运算符
    // 取到 refcnts（是一个稠密图）中对象对应的存储引用计数信息的内存的引用
    // 没用 table.refcnts.find(this) 难道是因为 [] 中会调用 FindAndConstruct，
    // FindAndConstruct 中的会查bucket是否存在，不存在就用 InsertIntoBucket 方法插入bucket
    // 而 table.refcnts.find(this) 只会查是否存在，查不到不会做其他操作
    size_t& refcntStorage = table.refcnts[this];
    size_t oldRefcnt = refcntStorage;
    
    // not deallocating - that was in the isa
    assert((oldRefcnt & SIDE_TABLE_DEALLOCATING) == 0);  
    assert((oldRefcnt & SIDE_TABLE_WEAKLY_REFERENCED) == 0);  

    uintptr_t carry;
    // 给 oldRefcnt 加上 extra_rc 个引用计数
    size_t refcnt = addc(oldRefcnt, extra_rc << SIDE_TABLE_RC_SHIFT, 0, &carry);
    // 如果要溢出了，就设置为 SIDE_TABLE_RC_PINNED
    if (carry) {
        refcnt = SIDE_TABLE_RC_PINNED;
    }
    // 存储是否在 dealloc 的信息
    if (isDeallocating) {
        refcnt |= SIDE_TABLE_DEALLOCATING;
    }
    // 存储是否有弱引用的信息
    if (weaklyReferenced) {
        refcnt |= SIDE_TABLE_WEAKLY_REFERENCED;
    }

    // 因为是引用，所以可以直接赋值
    refcntStorage = refcnt;
}


// Move some retain counts to the side table from the isa field.
// Returns true if the object is now pinned.
// 向 side table 中加上指定的引用计数（从 isa 中的部分引用计数移到 side table，但这个函数中只做side table中引用计数增加的步骤，不做 isa 中的引用计数减少的步骤），不要与 sidetable_moveExtraRC_nolock 混淆
// 返回值表示引用计数是否已经存满了
bool 
objc_object::sidetable_addExtraRC_nolock(size_t delta_rc)
{
    assert(isa.indexed);
    // 对象所在的 SideTable
    SideTable& table = SideTables()[this];

    size_t& refcntStorage = table.refcnts[this];
    size_t oldRefcnt = refcntStorage;
    // isa-side bits should not be set here
    assert((oldRefcnt & SIDE_TABLE_DEALLOCATING) == 0);
    assert((oldRefcnt & SIDE_TABLE_WEAKLY_REFERENCED) == 0);

    // 如果side table里存的引用计数已经满了，就直接返回true
    if (oldRefcnt & SIDE_TABLE_RC_PINNED) {
        return true;
    }

    uintptr_t carry;
    size_t newRefcnt = 
        addc(oldRefcnt, delta_rc << SIDE_TABLE_RC_SHIFT, 0, &carry);
    // 如果存满了
    if (carry) {
        refcntStorage =
            SIDE_TABLE_RC_PINNED | (oldRefcnt & SIDE_TABLE_FLAG_MASK);
        return true;
    }
    else {
        refcntStorage = newRefcnt;
        // 还没满
        return false;
    }
}


// Move some retain counts from the side table to the isa field.
// Returns the actual count subtracted, which may be less than the request.
// 从 side table 中减去指定的引用计数，返回值是减去了多少引用计数，
size_t 
objc_object::sidetable_subExtraRC_nolock(size_t delta_rc)
{
    assert(isa.indexed);
    SideTable& table = SideTables()[this];

    // 因为只是减引用计数，所以只是 table.refcnts.find(this) 就可以了，找不到也不用插入bucket
    // 这与 sidetable_addExtraRC_nolock 中的做法不同，所以不用 [] 运算符
    RefcountMap::iterator it = table.refcnts.find(this);
    // 压根没存这个对象的引用计数，或者引用计数为0
    if (it == table.refcnts.end()  ||  it->second == 0) {
        // Side table retain count is zero. Can't borrow.
        return 0;
    }
    size_t oldRefcnt = it->second;

    // isa-side bits should not be set here
    assert((oldRefcnt & SIDE_TABLE_DEALLOCATING) == 0);
    assert((oldRefcnt & SIDE_TABLE_WEAKLY_REFERENCED) == 0);

    size_t newRefcnt = oldRefcnt - (delta_rc << SIDE_TABLE_RC_SHIFT);
    assert(oldRefcnt > newRefcnt);// 不能向下溢出  // shouldn't underflow
    it->second = newRefcnt;
    return delta_rc;
}

// 取得对象在 side table 中存的引用计数
// 与 sidetable_retainCount 取得的值应该是一样的
// 区别是这个方法着重在 ExtraRC，有一部分引用计数存在 isa 中，而 side table 中存的是额外的引用计数
size_t 
objc_object::sidetable_getExtraRC_nolock()
{
    assert(isa.indexed);
    SideTable& table = SideTables()[this];
    RefcountMap::iterator it = table.refcnts.find(this);
    if (it == table.refcnts.end()) {
        return 0;
    }
    else {
        return it->second >> SIDE_TABLE_RC_SHIFT;
    }
}


// SUPPORT_NONPOINTER_ISA
#endif


__attribute__((used,noinline,nothrow))
// 对象在 side table 中的引用计数加一
id
objc_object::sidetable_retain_slow(SideTable& table)
{
#if SUPPORT_NONPOINTER_ISA
    assert(!isa.indexed);
#endif

    // 直接加锁，可能会等待很久，这就是 slow 的原因
    table.lock();
    size_t& refcntStorage = table.refcnts[this];
    // 如果没满，就加一
    if (! (refcntStorage & SIDE_TABLE_RC_PINNED)) {
        refcntStorage += SIDE_TABLE_RC_ONE;
    }
    table.unlock();

    return (id)this;
}

// 引用计数 +1
// 与 sidetable_tryRetain 的区别是不检查 是否可以 retain
id
objc_object::sidetable_retain()
{
#if SUPPORT_NONPOINTER_ISA
    assert(!isa.indexed);
#endif
    SideTable& table = SideTables()[this];

    // trylock 仅在调用时锁未被另一个线程保持的情况下，才获取该锁
    // 这样不需要等待太长时间，效率更高
    if (table.trylock()) {
        size_t& refcntStorage = table.refcnts[this];
        if (! (refcntStorage & SIDE_TABLE_RC_PINNED)) {
            refcntStorage += SIDE_TABLE_RC_ONE;
        }
        table.unlock();
        return (id)this;
    }
    // 如果 trylock 失败，只能使用 slow 的版本
    return sidetable_retain_slow(table);
}


// 尝试 retain（ 引用计数 +1 ）
// 返回值是 是否 retain 成功，有些情况（比如对象处在 dealloc 状态）下是不能被 retain 的
bool
objc_object::sidetable_tryRetain()
{
#if SUPPORT_NONPOINTER_ISA
    assert(!isa.indexed);
#endif
    SideTable& table = SideTables()[this];

    // NO SPINLOCK HERE
    // _objc_rootTryRetain() is called exclusively by _objc_loadWeak(), 
    // which already acquired the lock on our behalf.

    // fixme can't do this efficiently with os_lock_handoff_s
    // if (table.slock == 0) {
    //     _objc_fatal("Do not call -_tryRetain.");
    // }

    bool result = true;
    RefcountMap::iterator it = table.refcnts.find(this);
    if (it == table.refcnts.end()) {
        // 初始化为 1
        // 上面用 table.refcnts.find ，而这里用 table.refcnts[this]
        // 进一步验证了 二者的区别 （见 sidetable_moveExtraRC_nolock 中的注释）
        table.refcnts[this] = SIDE_TABLE_RC_ONE;
    }
    // 如果在 dealloc 是不能 retain 的
    else if (it->second & SIDE_TABLE_DEALLOCATING) {
        result = false;
    }
    // 如果没满，则 +1
    else if (! (it->second & SIDE_TABLE_RC_PINNED)) {
        it->second += SIDE_TABLE_RC_ONE;
    }
    
    return result;
}

// 取得对象存在 side table 中的引用计数，注意与 sidetable_getExtraRC_nolock 的区分
// 如果已经满了，就返回最大值 SIDE_TABLE_RC_PINNED >> SIDE_TABLE_RC_SHIFT
uintptr_t
objc_object::sidetable_retainCount()
{
    SideTable& table = SideTables()[this];

    size_t refcnt_result = 1;
    
    table.lock();
    RefcountMap::iterator it = table.refcnts.find(this);
    if (it != table.refcnts.end()) {
        // this is valid for SIDE_TABLE_RC_PINNED too
        refcnt_result += it->second >> SIDE_TABLE_RC_SHIFT;
    }
    table.unlock();
    return refcnt_result;
}

// 判断对象是否处于 dealloc 状态
bool 
objc_object::sidetable_isDeallocating()
{
    SideTable& table = SideTables()[this];

    // NO SPINLOCK HERE
    // _objc_rootIsDeallocating() is called exclusively by _objc_storeWeak(), 
    // which already acquired the lock on our behalf.


    // fixme can't do this efficiently with os_lock_handoff_s
    // if (table.slock == 0) {
    //     _objc_fatal("Do not call -_isDeallocating.");
    // }

    RefcountMap::iterator it = table.refcnts.find(this);
    return (it != table.refcnts.end()) && (it->second & SIDE_TABLE_DEALLOCATING);
}

// 判断对象是否有被弱引用
bool 
objc_object::sidetable_isWeaklyReferenced()
{
    bool result = false;

    SideTable& table = SideTables()[this];
    table.lock();

    RefcountMap::iterator it = table.refcnts.find(this);
    if (it != table.refcnts.end()) {
        result = it->second & SIDE_TABLE_WEAKLY_REFERENCED;
    }

    table.unlock();

    return result;
}

// 在 side table 中标记 对象有被强引用
void 
objc_object::sidetable_setWeaklyReferenced_nolock()
{
#if SUPPORT_NONPOINTER_ISA
    assert(!isa.indexed);
#endif

    SideTable& table = SideTables()[this];

    table.refcnts[this] |= SIDE_TABLE_WEAKLY_REFERENCED;
}


// rdar://20206767
// return uintptr_t instead of bool so that the various raw-isa 
// -release paths all return zero in eax
//
// 对位于 side table 对象进行 release 操作
// 参数 performDealloc 表示如果需要 dealloc 的情况下是否执行 dealloc
// 在 objc_object::sidetable_release 中被调用，如果其中 trylock 成功，就不会调用
// 否则只能调用该方法，因为 lock 需要等待，所以会 slow
__attribute__((used,noinline,nothrow))
uintptr_t
objc_object::sidetable_release_slow(SideTable& table, bool performDealloc)
{
#if SUPPORT_NONPOINTER_ISA
    assert(!isa.indexed);
#endif
    bool do_dealloc = false;

    // 下面的逻辑和 objc_object::sidetable_release 里的部分代码逻辑一模一样
    // 看它里面的注释就可以了
    
    table.lock();
    RefcountMap::iterator it = table.refcnts.find(this);
    if (it == table.refcnts.end()) {
        do_dealloc = true;
        table.refcnts[this] = SIDE_TABLE_DEALLOCATING;
    } else if (it->second < SIDE_TABLE_DEALLOCATING) {
        // SIDE_TABLE_WEAKLY_REFERENCED may be set. Don't change it.
        do_dealloc = true;
        it->second |= SIDE_TABLE_DEALLOCATING;
    } else if (! (it->second & SIDE_TABLE_RC_PINNED)) {
        it->second -= SIDE_TABLE_RC_ONE;
    }
    table.unlock();
    if (do_dealloc  &&  performDealloc) {
        ((void(*)(objc_object *, SEL))objc_msgSend)(this, SEL_dealloc);
    }
    return do_dealloc;
}


// rdar://20206767 
// return uintptr_t instead of bool so that the various raw-isa 
// -release paths all return zero in eax
// 对位于 side table 对象进行 release 操作
// 参数 performDealloc 表示如果需要 dealloc 的情况下是否执行 dealloc
// 在 objc_object::rootRelease 和 objc_object::rootReleaseShouldDealloc 中被调用
uintptr_t 
objc_object::sidetable_release(bool performDealloc)
{
#if SUPPORT_NONPOINTER_ISA
    assert(!isa.indexed);
#endif
    SideTable& table = SideTables()[this];

    // 是否需要执行 dealloc
    bool do_dealloc = false;
    
    // 这个值是根据对象在 side table 中的现状来判断出的
    // 和 performDealloc 不一样，performDealloc 是指定是否 dealloc
    // 只有 do_dealloc 和 performDealloc 都是 true ，才会 dealloc

    // trylock 仅在调用时锁未被另一个线程保持的情况下，才获取该锁
    // 这样不需要等待太长时间，效率更高
    if (table.trylock()) {
        RefcountMap::iterator it = table.refcnts.find(this);
        // 如果 refcnts 没找到它，说明它压根儿没引用计数，直接 dealloc，并且标记为正在 dealloc
        if (it == table.refcnts.end()) {
            do_dealloc = true;
            table.refcnts[this] = SIDE_TABLE_DEALLOCATING;
        } else if (it->second < SIDE_TABLE_DEALLOCATING) {
            // SIDE_TABLE_WEAKLY_REFERENCED may be set. Don't change it.
            do_dealloc = true;
            it->second |= SIDE_TABLE_DEALLOCATING;
        } else if (! (it->second & SIDE_TABLE_RC_PINNED)) {
            it->second -= SIDE_TABLE_RC_ONE;
        }
        table.unlock();
        if (do_dealloc  &&  performDealloc) {
            ((void(*)(objc_object *, SEL))objc_msgSend)(this, SEL_dealloc);
        }
        return do_dealloc;
    }

    // trylock 失败，只能用 slow 的版本
    return sidetable_release_slow(table, performDealloc);
}


// 如果引用计数都存在了 side table 中，就会调用这个方法清理弱引用和引用计数
void 
objc_object::sidetable_clearDeallocating()
{
    SideTable& table = SideTables()[this];

    // clear any weak table items
    // clear extra retain count and deallocating bit
    // (fixme warn or abort if extra retain count == 0 ?)
    table.lock();
    RefcountMap::iterator it = table.refcnts.find(this);
    // 如果 side table 中的 refcnts 里有它
    if (it != table.refcnts.end()) {
        // 如果有弱引用
        if (it->second & SIDE_TABLE_WEAKLY_REFERENCED) {
            // 将 weak table 中该对象的所有记录都删除，
            // 并且会做将__weak pointer置为 nil 的重要操作
            weak_clear_no_lock(&table.weak_table, (id)this);
        }
        table.refcnts.erase(it);
    }
    table.unlock();
}


/***********************************************************************
* Optimized retain/release/autorelease entrypoints
**********************************************************************/


#if __OBJC2__

__attribute__((aligned(16)))
id 
objc_retain(id obj)
{
    // 如果是nil 就不管它了
    if (!obj) return obj;
    
    // 如果是TaggedPointer，它不是真正的对象，所以没有办法retain
    if (obj->isTaggedPointer()) return obj;
    
    // 返回retain后的对象
    return obj->retain();
}


__attribute__((aligned(16)))
void 
objc_release(id obj)
{
    if (!obj) return;
    if (obj->isTaggedPointer()) return;
    return obj->release();
}


__attribute__((aligned(16)))
id
objc_autorelease(id obj)
{
    if (!obj) return obj;
    if (obj->isTaggedPointer()) return obj;
    return obj->autorelease();
}


// OBJC2
#else
// not OBJC2


id objc_retain(id obj) { return [obj retain]; }
void objc_release(id obj) { [obj release]; }
id objc_autorelease(id obj) { return [obj autorelease]; }


#endif


/***********************************************************************
* Basic operations for root class implementations a.k.a. _objc_root*()
**********************************************************************/

bool
_objc_rootTryRetain(id obj) 
{
    assert(obj);

    return obj->rootTryRetain();
}

bool
_objc_rootIsDeallocating(id obj) 
{
    assert(obj);

    return obj->rootIsDeallocating();
}


// 清空引用计数表并清除弱引用表，将所有_weak pointer指nil
void 
objc_clear_deallocating(id obj) 
{
    assert(obj);
    assert(!UseGC);

    if (obj->isTaggedPointer()) return;
    obj->clearDeallocating();
}

// 不知道这个方法是干嘛的 was zero 是啥意思
bool
_objc_rootReleaseWasZero(id obj)
{
    assert(obj);

    return obj->rootReleaseShouldDealloc();
}


id
_objc_rootAutorelease(id obj)
{
    assert(obj);
    // assert(!UseGC);
    if (UseGC) return obj;  // fixme CF calls this when GC is on

    return obj->rootAutorelease();
}

uintptr_t
_objc_rootRetainCount(id obj)
{
    assert(obj);

    return obj->rootRetainCount();
}


id
_objc_rootRetain(id obj)
{
    assert(obj);

    return obj->rootRetain();
}

void
_objc_rootRelease(id obj)
{
    assert(obj);

    obj->rootRelease();
}

// 利用指定的 Class cls 和 zone 在堆中分配一块内存，并实例化对象
// 但在 Objective-C 2.0 中 zone 被忽略，没啥用
id
_objc_rootAllocWithZone(Class cls, malloc_zone_t *zone)
{
    id obj;

#if __OBJC2__
    // allocWithZone under __OBJC2__ ignores the zone parameter
    (void)zone;
    // 利用给定的 cls 实例化对象
    obj = class_createInstance(cls, 0);
#else
    if (!zone || UseGC) {
        obj = class_createInstance(cls, 0);
    }
    else {
        obj = class_createInstanceFromZone(cls, 0, zone);
    }
#endif

    if (!obj) {
        obj = callBadAllocHandler(cls);
    }
    return obj;
}


// Call [cls alloc] or [cls allocWithZone:nil], with appropriate 
// shortcutting optimizations.
// 利用给定 cls 实例化对象
static ALWAYS_INLINE id
callAlloc(Class cls, bool checkNil, bool allocWithZone=false)
{
    // 如果 checkNil 并且 cls 是 nil ，就直接返回 nil
    if (checkNil && !cls) return nil;

#if __OBJC2__
    // 如果 cls 没有自定义 allocWithZone，就按默认的来
    if (! cls->ISA()->hasCustomAWZ()) {
        // No alloc/allocWithZone implementation. Go straight to the allocator.
        // fixme store hasCustomAWZ in the non-meta class and 
        // add it to canAllocFast's summary
        // 快速实例化，太高深，没看懂
        if (cls->canAllocFast()) {
            // No ctors, raw isa, etc. Go straight to the metal.
            // ctor 构造函数
            // dtor 析构函数
            bool dtor = cls->hasCxxDtor();
            id obj = (id)calloc(1, cls->bits.fastInstanceSize());
            if (!obj) return callBadAllocHandler(cls);
            obj->initInstanceIsa(cls, dtor);
            return obj;
        }
        else { // 慢的实例化
            // Has ctor or raw isa or something. Use the slower path.
            id obj = class_createInstance(cls, 0);
            if (!obj) return callBadAllocHandler(cls);
            return obj;
        }
    }
#endif

    // No shortcuts available.
    if (allocWithZone) {
        // 有自定义的 allocWithZone ,并且指定要调用 allocWithZone ，所以就调用呗
        return [cls allocWithZone:nil];
    }
    return [cls alloc];
}


// Base class implementation of +alloc. cls is not nil.
// Calls [cls allocWithZone:nil].
// 被 + (id)alloc 调用
id
_objc_rootAlloc(Class cls)
{
    return callAlloc(cls, false/*checkNil*/, true/*allocWithZone*/);
}

// Calls [cls alloc].
// 和 SEL_alloc 有关
id
objc_alloc(Class cls)
{
    return callAlloc(cls, true/*checkNil*/, false/*allocWithZone*/);
}

// Calls [cls allocWithZone:nil].
// 和 SEL_allocWithZone 有关
id 
objc_allocWithZone(Class cls)
{
    return callAlloc(cls, true/*checkNil*/, true/*allocWithZone*/);
}

// 被 - (void)dealloc 调用
void
_objc_rootDealloc(id obj)
{
    assert(obj);

    // rootDealloc 会做 dealloc 的主要工作
    obj->rootDealloc();
}

// 被 - (void)finalize 调用
void
_objc_rootFinalize(id obj __unused)
{
    assert(obj);
    assert(UseGC);

    if (UseGC) {
        return;
    }
    _objc_fatal("_objc_rootFinalize called with garbage collection off");
}

// 被 - (id)init 调用
id
_objc_rootInit(id obj)
{
    // In practice, it will be hard to rely on（依赖） this function.
    // Many classes do not properly chain -init calls.
    return obj;
}

// 取得对象所在的 zone ，Objective-C 2.0 中会返回默认的 zone
// 在 - (struct _NSZone *)zone 和 + (struct _NSZone *)zone 被调用
malloc_zone_t *
_objc_rootZone(id obj)
{
    (void)obj;
    if (gc_zone) {
        return gc_zone;
    }
#if __OBJC2__
    // allocWithZone under __OBJC2__ ignores the zone parameter
    return malloc_default_zone();
#else
    malloc_zone_t *rval = malloc_zone_from_ptr(obj);
    return rval ? rval : malloc_default_zone();
#endif
}

// 取得对象的 hash 值
// 在 - (NSUInteger)hash 和 + (NSUInteger)hash 被调用
uintptr_t
_objc_rootHash(id obj)
{
    if (UseGC) {
        return _object_getExternalHash(obj);
    }
    return (uintptr_t)obj;
}


//    经过实验，原代码：
//    int main(int argc, const char * argv[]) {
//    @autoreleasepool {
//        int a = 0;
//    }
//    return 0;
//    }
//    经过 clang -rewrite-objc 后会被翻译成：
//    struct __AtAutoreleasePool {
//        __AtAutoreleasePool() {atautoreleasepoolobj = objc_autoreleasePoolPush();}
//        ~__AtAutoreleasePool() {objc_autoreleasePoolPop(atautoreleasepoolobj);}
//        void * atautoreleasepoolobj;
//    };
//
//    int main(int argc, const char * argv[]) {
//        /* @autoreleasepool */ { __AtAutoreleasePool __autoreleasepool;
//            int a = 0;
//        }
//        return 0;
//    }
//    也就是说 @autoreleasepool 原理是新建了一个 __AtAutoreleasePool 结构体的实例
//    而__AtAutoreleasePool的构造函数中直接调用了 objc_autoreleasePoolPush 函数
//    向 AutoreleasePoolPage 链表中新添加了一个 pool，__AtAutoreleasePool 结构体中的
//    成员变量 atautoreleasepoolobj 接收并存储了 pool 在page链表中的起始地址（POOL_SENTINEL）

// 添加一个新的 AutoreleasePoolPage
void *
objc_autoreleasePoolPush(void)
{
    if (UseGC) return nil;
    return AutoreleasePoolPage::push();
}

// pop 一个 AutoreleasePoolPage
void
objc_autoreleasePoolPop(void *ctxt)
{
    if (UseGC) return;
    AutoreleasePoolPage::pop(ctxt);
}


void *
_objc_autoreleasePoolPush(void)
{
    return objc_autoreleasePoolPush();
}

void
_objc_autoreleasePoolPop(void *ctxt)
{
    objc_autoreleasePoolPop(ctxt);
}

void 
_objc_autoreleasePoolPrint(void)
{
    if (UseGC) return;
    AutoreleasePoolPage::printAll();
}

#pragma mark - 为 tail-calling 优化添加的方法

// Same as objc_release but suitable for tail-calling 
// if you need the value back and don't want to push a frame before this point.
// 与直接调用 objc_release 不同的是将对象返回了，有利于 tail-calling
// http://www.ruanyifeng.com/blog/2015/04/tail-call.html
__attribute__((noinline))
static id 
objc_releaseAndReturn(id obj)
{
    objc_release(obj);
    return obj;
}

// Same as objc_retainAutorelease but suitable for tail-calling 
// if you don't want to push a frame before this point.
// 与直接调用 objc_retainAutoreleaseAndReturn 不同的是将对象返回了，有利于 tail-calling
__attribute__((noinline))
static id 
objc_retainAutoreleaseAndReturn(id obj)
{
    return objc_retainAutorelease(obj);
}


// Prepare a value at +1 for return through a +0 autoreleasing convention.
// 被调用方 autorelease 返回的对象
id 
objc_autoreleaseReturnValue(id obj)
{
    // 如果支持返回值优化，就不用走 autorelease 了，直接返回对象
    if (prepareOptimizedReturn(ReturnAtPlus1)) {
        return obj;
    }

    // 否则，只能走原来的流程
    return objc_autorelease(obj);
}

// Prepare a value at +0 for return through a +0 autoreleasing convention.
id 
objc_retainAutoreleaseReturnValue(id obj)
{
    if (prepareOptimizedReturn(ReturnAtPlus0)) return obj;

    // not objc_autoreleaseReturnValue(objc_retain(obj)) 
    // because we don't need another optimization attempt
    return objc_retainAutoreleaseAndReturn(obj);
}

// Accept a value returned through a +0 autoreleasing convention for use at +1.
// 调用方 retain 被调用方返回的对象
id
objc_retainAutoreleasedReturnValue(id obj)
{
    // 如果可以支持返回值优化，就不用 retain 了，直接返回对象
    if (acceptOptimizedReturn() == ReturnAtPlus1) {
        return obj;
    }

    // 不支持优化，就只能走原来的流程了
    return objc_retain(obj);
}

// Accept a value returned through a +0 autoreleasing convention for use at +0.
id
objc_unsafeClaimAutoreleasedReturnValue(id obj)
{
    if (acceptOptimizedReturn() == ReturnAtPlus0) return obj;

    return objc_releaseAndReturn(obj);
}

// retain 对象，并将其放入自动释放池
// 在 objc_retainAutoreleaseAndReturn 中被调用
id
objc_retainAutorelease(id obj)
{
    return objc_autorelease(objc_retain(obj));
}

// 不大理解是干嘛用的
void
_objc_deallocOnMainThreadHelper(void *context)
{
    id obj = (id)context;
    [obj dealloc];
}

#undef objc_retainedObject
#undef objc_unretainedObject
#undef objc_unretainedPointer

// convert objc_objectptr_t to id, callee must take ownership.
id objc_retainedObject(objc_objectptr_t pointer) { return (id)pointer; }

// convert objc_objectptr_t to id, without ownership transfer.
id objc_unretainedObject(objc_objectptr_t pointer) { return (id)pointer; }

// convert id to objc_objectptr_t, no ownership transfer.
objc_objectptr_t objc_unretainedPointer(id object) { return object; }



// 初始化自动释放池、初始化 side table
// 是在 map_images_nolock 被调用的，发生在 libobjc 动态库加载完成后
void arr_init(void) 
{
    AutoreleasePoolPage::init();
    SideTableInit();
}



@implementation NSObject

+ (void)load {
    if (UseGC) gc_init2();
}

+ (void)initialize {
}

+ (id)self {
    return (id)self;
}

- (id)self {
    return self;
}

+ (Class)class {
    return self;
}

- (Class)class {
    return object_getClass(self);
}

+ (Class)superclass {
    return self->superclass;
}

- (Class)superclass {
    return [self class]->superclass;
}

+ (BOOL)isMemberOfClass:(Class)cls {
    return object_getClass((id)self) == cls;
}

- (BOOL)isMemberOfClass:(Class)cls {
    return [self class] == cls;
}

+ (BOOL)isKindOfClass:(Class)cls {
    for (Class tcls = object_getClass((id)self); tcls; tcls = tcls->superclass) {
        if (tcls == cls) return YES;
    }
    return NO;
}

- (BOOL)isKindOfClass:(Class)cls {
    for (Class tcls = [self class]; tcls; tcls = tcls->superclass) {
        if (tcls == cls) return YES;
    }
    return NO;
}

+ (BOOL)isSubclassOfClass:(Class)cls {
    for (Class tcls = self; tcls; tcls = tcls->superclass) {
        if (tcls == cls) return YES;
    }
    return NO;
}

+ (BOOL)isAncestorOfObject:(NSObject *)obj {
    for (Class tcls = [obj class]; tcls; tcls = tcls->superclass) {
        if (tcls == self) return YES;
    }
    return NO;
}

+ (BOOL)instancesRespondToSelector:(SEL)sel {
    if (!sel) return NO;
    return class_respondsToSelector(self, sel);
}

+ (BOOL)respondsToSelector:(SEL)sel {
    if (!sel) return NO;
    return class_respondsToSelector_inst(object_getClass(self), sel, self);
}

- (BOOL)respondsToSelector:(SEL)sel {
    if (!sel) return NO;
    return class_respondsToSelector_inst([self class], sel, self);
}

+ (BOOL)conformsToProtocol:(Protocol *)protocol {
    if (!protocol) return NO;
    for (Class tcls = self; tcls; tcls = tcls->superclass) {
        if (class_conformsToProtocol(tcls, protocol)) return YES;
    }
    return NO;
}

- (BOOL)conformsToProtocol:(Protocol *)protocol {
    if (!protocol) return NO;
    for (Class tcls = [self class]; tcls; tcls = tcls->superclass) {
        if (class_conformsToProtocol(tcls, protocol)) return YES;
    }
    return NO;
}

+ (NSUInteger)hash {
    return _objc_rootHash(self);
}

- (NSUInteger)hash {
    return _objc_rootHash(self);
}

+ (BOOL)isEqual:(id)obj {
    return obj == (id)self;
}

- (BOOL)isEqual:(id)obj {
    return obj == self;
}


+ (BOOL)isFault {
    return NO;
}

- (BOOL)isFault {
    return NO;
}

+ (BOOL)isProxy {
    return NO;
}

- (BOOL)isProxy {
    return NO;
}


+ (IMP)instanceMethodForSelector:(SEL)sel {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return class_getMethodImplementation(self, sel);
}

+ (IMP)methodForSelector:(SEL)sel {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return object_getMethodImplementation((id)self, sel);
}

// 通过 sel 找到对应的方法实现的函数指针
- (IMP)methodForSelector:(SEL)sel {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return object_getMethodImplementation(self, sel);
}

// 与 resolveInstanceMethod 类似，不过这时尚未实现的方法不是实例方法，而是类方法
+ (BOOL)resolveClassMethod:(SEL)sel {
    return NO;
}

// 当对象在收到无法解读的消息时，首先将调用该方法
// 该方法的参数就是那个未知的 SEL
// 返回值表示这个类是否能新增一个实例方法用以处理此 SEL
// 在继续往下执行转发机制之前，本类有机会新增一个处理此 SEL 的方法
// 在 _class_resolveInstanceMethod 中被调用
+ (BOOL)resolveInstanceMethod:(SEL)sel {
    return NO;
}

// Replaced by CF (throws an NSException)
+ (void)doesNotRecognizeSelector:(SEL)sel {
    _objc_fatal("+[%s %s]: unrecognized selector sent to instance %p", 
                class_getName(self), sel_getName(sel), self);
}

// Replaced by CF (throws an NSException)
- (void)doesNotRecognizeSelector:(SEL)sel {
    _objc_fatal("-[%s %s]: unrecognized selector sent to instance %p", 
                object_getClassName(self), sel_getName(sel), self);
}


+ (id)performSelector:(SEL)sel {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return ((id(*)(id, SEL))objc_msgSend)((id)self, sel);
}

+ (id)performSelector:(SEL)sel withObject:(id)obj {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return ((id(*)(id, SEL, id))objc_msgSend)((id)self, sel, obj);
}

+ (id)performSelector:(SEL)sel withObject:(id)obj1 withObject:(id)obj2 {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return ((id(*)(id, SEL, id, id))objc_msgSend)((id)self, sel, obj1, obj2);
}

- (id)performSelector:(SEL)sel {
    if (!sel) {[self doesNotRecognizeSelector:sel];}
    // 原来本质都是用了 objc_msgSend
    return ((id(*)(id, SEL))objc_msgSend)(self, sel);
}

- (id)performSelector:(SEL)sel withObject:(id)obj {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return ((id(*)(id, SEL, id))objc_msgSend)(self, sel, obj);
}

- (id)performSelector:(SEL)sel withObject:(id)obj1 withObject:(id)obj2 {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return ((id(*)(id, SEL, id, id))objc_msgSend)(self, sel, obj1, obj2);
}


// Replaced by CF (returns an NSMethodSignature)
+ (NSMethodSignature *)instanceMethodSignatureForSelector:(SEL)sel {
    _objc_fatal("+[NSObject instanceMethodSignatureForSelector:] "
                "not available without CoreFoundation");
}

// Replaced by CF (returns an NSMethodSignature)
+ (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    _objc_fatal("+[NSObject methodSignatureForSelector:] "
                "not available without CoreFoundation");
}

// Replaced by CF (returns an NSMethodSignature)
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    _objc_fatal("-[NSObject methodSignatureForSelector:] "
                "not available without CoreFoundation");
}

+ (void)forwardInvocation:(NSInvocation *)invocation {
    [self doesNotRecognizeSelector:(invocation ? [invocation selector] : 0)];
}

// 到这里，只能启用完整的消息转发机制，
// 首先，runtime 会创建 NSInvocation 对象，把与尚未处理的那条消息有关的全部细节都封装在其中
// 包括 selector、目标(target) 及 参数
// 在触发 NSInvocation 对象时，消息派发系统（message dispatch system）将亲自出马，把消息指派给目标对象
// 此步骤会调用 forwardInvocation 来转发消息
// 这个方法可以实现的很简单：只需改变调用目标，使消息在新目标上得以调用即可，然而这样实现出来的方法与 forwardingTargetForSelector 方案所实现的方法等效，所以很少有人采用这么简单的实现方法
// 比较有用的实现方式是：在触发消息前，先以某种方式改变消息内容，比如追加一个参数，或是改换 selector
- (void)forwardInvocation:(NSInvocation *)invocation {
    [self doesNotRecognizeSelector:(invocation ? [invocation selector] : 0)];
}


+ (id)forwardingTargetForSelector:(SEL)sel {
    return nil;
}


// resolveInstanceMethod 失败后，当前接受者还有第二次机会能处理未知的 seletor，
// 在这步，runtime 会调用这个方法，询问能否将消息转给其他接收者处理
// 返回值就是指定的处理消息的对象
- (id)forwardingTargetForSelector:(SEL)sel {
    return nil;
}


// Replaced by CF (returns an NSString)
+ (NSString *)description {
    return nil;
}

// Replaced by CF (returns an NSString)
- (NSString *)description {
    return nil;
}

+ (NSString *)debugDescription {
    return [self description];
}

- (NSString *)debugDescription {
    return [self description];
}

// new 实现与 + (id)alloc 稍稍有一点点不同，不过实际都通过 callAlloc 分配内存
+ (id)new {
    return [callAlloc(self, false/*checkNil*/) init];
}

+ (id)retain {
    return (id)self;
}

// Replaced by ObjectAlloc
- (id)retain {
    return ((id)self)->rootRetain();
}


+ (BOOL)_tryRetain {
    return YES;
}

// Replaced by ObjectAlloc
- (BOOL)_tryRetain {
    return ((id)self)->rootTryRetain();
}

// Class 不会被 dealloc ，所以总是返回 NO
+ (BOOL)_isDeallocating {
    return NO;
}

// 查看对象是否处于正在 dealloc 的状态
- (BOOL)_isDeallocating {
    return ((id)self)->rootIsDeallocating();
}

// 因为 Class 不会被 dealloc，所以永远可以被弱引用
+ (BOOL)allowsWeakReference { 
    return YES; 
}

+ (BOOL)retainWeakReference { 
    return YES; 
}

// 对象处于处于正在 dealloc 的状态时是不能被弱引用的
- (BOOL)allowsWeakReference { 
    return ! [self _isDeallocating]; 
}

- (BOOL)retainWeakReference { 
    return [self _tryRetain]; 
}

// oneway 是线程之间通信的接口定义，表示单向的调用
+ (oneway void)release {
}

// Replaced by ObjectAlloc
- (oneway void)release {
    ((id)self)->rootRelease();
}

+ (id)autorelease {
    return (id)self;
}

// Replaced by ObjectAlloc
- (id)autorelease {
    return ((id)self)->rootAutorelease();
}

// Class 的引用计数是满的，因为永远都不会被释放，常驻内存
+ (NSUInteger)retainCount {
    return ULONG_MAX;
}

// 取得引用计数总数，看来传言的引用计数不准的说法是错误的
- (NSUInteger)retainCount {
    return ((id)self)->rootRetainCount();
}

+ (id)alloc {
    return _objc_rootAlloc(self);
}

// Replaced by ObjectAlloc
+ (id)allocWithZone:(struct _NSZone *)zone {
    return _objc_rootAllocWithZone(self, (malloc_zone_t *)zone);
}

// Replaced by CF (throws an NSException)
// Class 不需要被 init，所以其中没干其他的事儿
+ (id)init {
    return (id)self;
}

// 不过....也没见 _objc_rootInit 里干了有用的事儿
- (id)init {
    return _objc_rootInit(self);
}

// Replaced by CF (throws an NSException)
+ (void)dealloc {
}


// Replaced by NSZombies
// NSZombies 会覆写这个方法 ？
- (void)dealloc {
    _objc_rootDealloc(self);
}

// Replaced by CF (throws an NSException)
+ (void)finalize {
}

// 对象从内存中清除出去之前做必要的清理工作
// 子类覆盖 finalize 方法以整理系统资源或者执行其他清理工作。
// 比如在 finalizeOneObject 方法就调用了一次
- (void)finalize {
    _objc_rootFinalize(self);
}

+ (struct _NSZone *)zone {
    return (struct _NSZone *)_objc_rootZone(self);
}

- (struct _NSZone *)zone {
    return (struct _NSZone *)_objc_rootZone(self);
}

+ (id)copy {
    return (id)self;
}

+ (id)copyWithZone:(struct _NSZone *)zone {
    return (id)self;
}

- (id)copy {
    // 奇怪啊 copyWithZone 是在哪里定义的
    return [(id)self copyWithZone:nil];
}

+ (id)mutableCopy {
    return (id)self;
}

+ (id)mutableCopyWithZone:(struct _NSZone *)zone {
    return (id)self;
}

- (id)mutableCopy {
    return [(id)self mutableCopyWithZone:nil];
}

@end


