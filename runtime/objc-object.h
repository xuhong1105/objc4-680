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


/***********************************************************************
* Inlineable parts of NSObject / objc_object implementation
* NSObject / objc_object 的实现中的 内联部分
**********************************************************************/

#ifndef _OBJC_OBJCOBJECT_H_
#define _OBJC_OBJCOBJECT_H_


// 只引用了这一个头文件，所以只和 objc-private 有关系
#include "objc-private.h"


enum ReturnDisposition : bool {
    ReturnAtPlus0 = false,
    ReturnAtPlus1 = true
};

static ALWAYS_INLINE 
bool prepareOptimizedReturn(ReturnDisposition disposition);


#if SUPPORT_TAGGED_POINTERS

#define TAG_COUNT 8
#define TAG_SLOT_MASK 0xf

#if SUPPORT_MSB_TAGGED_POINTERS
#   define TAG_MASK (1ULL<<63)
#   define TAG_SLOT_SHIFT 60
#   define TAG_PAYLOAD_LSHIFT 4
#   define TAG_PAYLOAD_RSHIFT 4
#else
#   define TAG_MASK 1
#   define TAG_SLOT_SHIFT 0
#   define TAG_PAYLOAD_LSHIFT 0
#   define TAG_PAYLOAD_RSHIFT 4
#endif

extern "C" { extern Class objc_debug_taggedpointer_classes[TAG_COUNT*2]; }
#define objc_tag_classes objc_debug_taggedpointer_classes

#endif


// 判断一个 objc_object 结构体对象是否是 类
inline bool
objc_object::isClass()
{
    // 例如 NSNumber 等 TaggedPointer 不是类，里面存的就是值本身
    if (isTaggedPointer()) return false;
    
    // 先取得这个结构体对象中存储在 isa 中的 cls，然后判断这个 cls 是否是元类，
    // 如果是元类那么这个结构体对象就是类，反之不是
    return ISA()->isMetaClass();
}

#if SUPPORT_NONPOINTER_ISA  // iphone 真机支持

#   if !SUPPORT_TAGGED_POINTERS
#       error sorry
#   endif


inline Class 
objc_object::ISA() 
{
    assert(!isTaggedPointer());
    // 取得 isa.bits 中的 shiftcls，即原来的 class cls
    return (Class)(isa.bits & ISA_MASK);
}


inline bool 
objc_object::hasIndexedIsa()
{
    // 0表示普通的isa指针 1表示优化过的，存储引用计数
    return isa.indexed;
}

inline Class 
objc_object::getIsa() 
{
    if (isTaggedPointer()) { // 如果是 tagged pointer，需要转换后取出里面的class
        uintptr_t slot = ((uintptr_t)this >> TAG_SLOT_SHIFT) & TAG_SLOT_MASK;
        return objc_tag_classes[slot];
    }
    return ISA(); // 否则直接返回 isa_t isa 中存的 cls
}


inline void 
objc_object::initIsa(Class cls)
{
    initIsa(cls, false, false);
}

inline void 
objc_object::initClassIsa(Class cls)
{
    // disable non-pointer isa fields
    if (DisableIndexedIsa) {
        initIsa(cls, false, false);
    } else {
        initIsa(cls, true, false);
    }
}

inline void
objc_object::initProtocolIsa(Class cls)
{
    return initClassIsa(cls);
}

inline void 
objc_object::initInstanceIsa(Class cls, bool hasCxxDtor)
{
    assert(!UseGC);
    // 如果需要 raw isa ，就玩不下去了
    assert(!cls->requiresRawIsa());
    assert(hasCxxDtor == cls->hasCxxDtor());

    initIsa(cls, true, hasCxxDtor);
}

// cls : 类
// indexed : whether enable non-pointer isa fields
// hasCxxDtor : 是否有c++的析构函数
inline void 
objc_object::initIsa(Class cls, bool indexed, bool hasCxxDtor)
{ 
    assert(!isTaggedPointer()); 
    
    if (!indexed) {
        isa.cls = cls;
    } else {
        // 如果用 non-pointer isa fields
        // 就会在其中存其他的东西
        assert(!DisableIndexedIsa);
        isa.bits = ISA_MAGIC_VALUE;
        // isa.magic is part of ISA_MAGIC_VALUE
        // isa.indexed is part of ISA_MAGIC_VALUE
        isa.has_cxx_dtor = hasCxxDtor;
        // 为什么是右移3位？？？
        isa.shiftcls = (uintptr_t)cls >> 3;
    }
}

// 修改一个 objc_object 对象的 cls，只是 cls，不是整个 isa
// 方法名叫 changeIsa ，是因为 objc.h 中暴露出来的假 objc_object 里声明 Class isa
// 这样可以隐藏 isa 的实现细节
inline Class 
objc_object::changeIsa(Class newCls)
{
    // This is almost always true but there are
    // enough edge cases that we can't assert it.
    // assert(newCls->isFuture()  || 
    //        newCls->isInitializing()  ||  newCls->isInitialized());

    assert(!isTaggedPointer()); 

    isa_t oldisa;
    isa_t newisa;

    bool sideTableLocked = false;
    // transcribe 转录 抄写
    bool transcribeToSideTable = false;

    do {
        transcribeToSideTable = false;
        oldisa = LoadExclusive(&isa.bits);
        if ((oldisa.bits == 0  ||  oldisa.indexed)  &&
            !newCls->isFuture()  &&  newCls->canAllocIndexed())
        {
            // 0 -> indexed
            // indexed -> indexed
            if (oldisa.bits == 0) {
                newisa.bits = ISA_MAGIC_VALUE;
            } else {
                newisa = oldisa;
            }
            // isa.magic is part of ISA_MAGIC_VALUE
            // isa.indexed is part of ISA_MAGIC_VALUE
            newisa.has_cxx_dtor = newCls->hasCxxDtor();
            newisa.shiftcls = (uintptr_t)newCls >> 3;
        }
        else if (oldisa.indexed) {
            // indexed -> not indexed
            // Need to copy retain count et al to side table.
            // Acquire side table lock before setting isa to 
            // prevent races such as concurrent -release.
            if (!sideTableLocked) sidetable_lock();
            sideTableLocked = true;
            transcribeToSideTable = true;
            newisa.cls = newCls;
        }
        else {
            // not indexed -> not indexed
            newisa.cls = newCls;
        }
    } while (!StoreExclusive(&isa.bits, oldisa.bits, newisa.bits));

    // 从 indexed 变为 not indexed，isa_t 里不能再存引用计数
    // 则将 oldisa 中的信息移到 side table 中
    if (transcribeToSideTable) {
        // Copy oldisa's retain count et al to side table.
        // oldisa.weakly_referenced: nothing to do
        // oldisa.has_assoc: nothing to do
        // oldisa.has_cxx_dtor: nothing to do
        sidetable_moveExtraRC_nolock(oldisa.extra_rc, 
                                     oldisa.deallocating, 
                                     oldisa.weakly_referenced);
    }

    if (sideTableLocked) sidetable_unlock();

    Class oldCls;
    if (oldisa.indexed) {
        // 左移 3 位，取出cls
        oldCls = (Class)((uintptr_t)oldisa.shiftcls << 3);
    } else {
        oldCls = oldisa.cls;
    }
    
    return oldCls;
}

// SUPPORT_TAGGED_POINTERS
// 判断当前对象是否是 tagged pointer
inline bool 
objc_object::isTaggedPointer() 
{
    return ((uintptr_t)this & TAG_MASK);
}

    
inline bool
objc_object::hasAssociatedObjects()
{
    if (isTaggedPointer()) {
        return true;
    }
    if (isa.indexed) {
        return isa.has_assoc;
    }
    return true;
}


inline void
objc_object::setHasAssociatedObjects()
{
    if (isTaggedPointer()) return;

 retry:
    // LoadExclusive 里做了很玄妙的事情，完全看不懂，应该不用深究
    isa_t oldisa = LoadExclusive(&isa.bits);
    isa_t newisa = oldisa;
    if (!newisa.indexed) return;
    if (newisa.has_assoc) return;
    newisa.has_assoc = true;
    if (!StoreExclusive(&isa.bits, oldisa.bits, newisa.bits)) goto retry;
}


inline bool
objc_object::isWeaklyReferenced()
{
    assert(!isTaggedPointer());
    if (isa.indexed) {
        return isa.weakly_referenced;
    } else {
        return sidetable_isWeaklyReferenced();
    }
}

// 设置有弱引用
inline void
objc_object::setWeaklyReferenced_nolock()
{
 retry:
    isa_t oldisa = LoadExclusive(&isa.bits);
    isa_t newisa = oldisa;
    // isa中没有indexed，则引用计数是由side table管理的
    // 必须在side table中设置有弱引用
    if (!newisa.indexed) {
        return sidetable_setWeaklyReferenced_nolock();
    }
    // isa中原本已经是有弱引用，则不用修改
    if (newisa.weakly_referenced) return;
    // 原来没有弱引用，则修改为有弱引用
    newisa.weakly_referenced = true;
    // 修改指定地址的值
    // 这里是将isa.bits位置处的值，由oldisa.bits修改为newisa.bits
    // StoreExclusive 里用了__sync_bool_compare_and_swap内建函数，先比较后交换，如果中间失败了，就会返回false。
    // 那么就重新再试一次.....还真是粗暴呢.....
    if (!StoreExclusive(&isa.bits, oldisa.bits, newisa.bits)) {
        goto retry;
    }
}


inline bool
objc_object::hasCxxDtor()
{
    assert(!isTaggedPointer());
    // 对象是否有c++析构器，或者对象的类是否有c++析构器
    if (isa.indexed) {
        return isa.has_cxx_dtor;
    } else {
        return isa.cls->hasCxxDtor();
    }
}


// 是否在 deallocating
inline bool 
objc_object::rootIsDeallocating()
{
    // 如果有 Garbage Collection，这些操作都是非法的，所以要断言
    assert(!UseGC);

    if (isTaggedPointer()) {
        return false;
    }
    if (isa.indexed) {
        return isa.deallocating;
    }
    return sidetable_isDeallocating();
}

// 清空引用计数表并清除弱引用表，将所有weak引用指nil（这也就是weak变量能安全置空的所在）
inline void 
objc_object::clearDeallocating()
{
    // 如果引用计数都存在了 side table 中，那么直接操作 side table 就好了
    if (!isa.indexed) {
        // Slow path for raw pointer isa.
        sidetable_clearDeallocating();
    }
    
    // 如果对象有被弱引用，或者有部分引用计数存在了 side table 中，
    // 就调用 clearDeallocating_slow 
    else if (isa.weakly_referenced  ||  isa.has_sidetable_rc) {
        // Slow path for non-pointer isa with weak refs and/or side table data.
        clearDeallocating_slow();
    }

    assert(!sidetable_present());
}


inline void
objc_object::rootDealloc()
{
    assert(!UseGC);
    // 直接返回了？ tagged point 就不需要清理了？
    if (isTaggedPointer()) return;

    if (isa.indexed  &&  
        !isa.weakly_referenced  &&  
        !isa.has_assoc  &&  
        !isa.has_cxx_dtor  &&  
        !isa.has_sidetable_rc)
    {
        // 没有弱引用、关联对象、c++析构器，引用计数还不存储在side table的话
        // 就直接 free 掉对象的内存
        // 真粗暴😂😂😂，难怪说可以大幅度提高效率
        assert(!sidetable_present());
        free(this);
    } 
    else {
        // object_dispose 中会做调用c++析构器、清除关联对象、清除弱引用、释放内存等等工作，把对象安全彻底的干掉
        object_dispose((id)this);
    }
}


// Equivalent to calling [this retain], with shortcuts if there is no override
inline id 
objc_object::retain()
{
    // UseGC is allowed here, but requires hasCustomRR.
    // 有自定义 RR (不知道是什么玩意儿)，就可以用 GC
    // 反正 GC 这玩意儿在iOS上也不能用，就不去管它了
    assert(!UseGC  ||  ISA()->hasCustomRR());
    assert(!isTaggedPointer());

    // 没有自定义 retain/release
    if (! ISA()->hasCustomRR()) {
        return rootRetain();
    }

    // 有自定义 retain/release
    // 猜的，最后会调用 objc_retain，见 fixupMessageRef
    return ((id(*)(objc_object *, SEL))objc_msgSend)(this, SEL_retain);
}


// Base retain implementation, ignoring overrides.
// This does not check isa.fast_rr; if there is an RR override then 
// it was already called and it chose to call [super retain].
//
// tryRetain=true is the -_tryRetain path.
// handleOverflow=false is the frameless fast path.
// handleOverflow=true is the framed slow path including overflow to side table
// The code is structured this way to prevent duplication.

ALWAYS_INLINE id 
objc_object::rootRetain()
{
    return rootRetain(false, false);
}

ALWAYS_INLINE bool 
objc_object::rootTryRetain()
{
    return rootRetain(true, false) ? true : false;
}

#pragma mark - rootRetain

// 看名字就知道，肯定是最根本的 retain 了
ALWAYS_INLINE id 
objc_object::rootRetain(bool tryRetain, bool handleOverflow)
{
    assert(!UseGC);
    // tagged pointer 不需要 retain
    if (isTaggedPointer()) return (id)this;

    bool sideTableLocked = false;
    bool transcribeToSideTable = false;

    isa_t oldisa;
    isa_t newisa;

    do {
        transcribeToSideTable = false;
        oldisa = LoadExclusive(&isa.bits);
        newisa = oldisa;
        if (!newisa.indexed) goto unindexed;
        // don't check newisa.fast_rr; we already called any RR overrides
        // 正在析构，就不能 retain 了，很有道理
        if (tryRetain && newisa.deallocating) {
            goto tryfail;
        }
        uintptr_t carry;
        // 向 newisa.bits 中加 RC_ONE
        // RC_ONE 是一个引用计数 RC  retain count
        // carry 可能是检测是否溢出的
        newisa.bits = addc(newisa.bits, RC_ONE, 0, &carry);  // extra_rc++

        if (carry) { // 如果溢出了
            // newisa.extra_rc++ overflowed
            // 不处理溢出
            if (!handleOverflow) {
                return rootRetain_overflow(tryRetain);
            }
            // Leave half of the retain counts inline and 
            // prepare to copy the other half to the side table.
            // 处理溢出，留一半引用计数在 isa.bits 里
            // 另一半移到 side table 里
            if (!tryRetain && !sideTableLocked) {
                // 给 side table 加锁，因为后面要操作它
                sidetable_lock();
            }
            sideTableLocked = true;
            // 标记要移动引用计数到 sidetable
            transcribeToSideTable = true;
            // 留一半引用计数在 isa.bits 里
            newisa.extra_rc = RC_HALF;
            // 在 isa 中标记有部分引用计数在 side table 中
            newisa.has_sidetable_rc = true;
        }
    } while (!StoreExclusive(&isa.bits, oldisa.bits, newisa.bits));// 一直交换，交换到成功为止，就是这么粗暴

    // 如果需要移动引用计数
    if (transcribeToSideTable) {
        // Copy the other half of the retain counts to the side table.
        // 给 side table 里存的引用计数加 RC_HALF
        sidetable_addExtraRC_nolock(RC_HALF);
    }

    // 搞定后，给 side table 解锁
    if (!tryRetain && sideTableLocked) sidetable_unlock();
    return (id)this;

 tryfail:
    if (!tryRetain && sideTableLocked) sidetable_unlock();
    return nil;

 unindexed: // 没有 indexed ，引用计数都在side table，直接操作side table就好了
    if (!tryRetain && sideTableLocked) {
        sidetable_unlock();
    }
    // 是否 try retain ，调用的 side table 的方法还不一样
    if (tryRetain) {
        return sidetable_tryRetain() ? (id)this : nil;
    } else {
        return sidetable_retain();
    }
}


// Equivalent to calling [this release], with shortcuts if there is no override
inline void
objc_object::release()
{
    // UseGC is allowed here, but requires hasCustomRR.
    assert(!UseGC  ||  ISA()->hasCustomRR());
    assert(!isTaggedPointer());

    // 没有自定义 retain/release
    if (! ISA()->hasCustomRR()) {
        rootRelease();
        return;
    }

    // 有自定义 RR
    ((void(*)(objc_object *, SEL))objc_msgSend)(this, SEL_release);
}


// Base release implementation, ignoring overrides.
// Does not call -dealloc.
// Returns true if the object should now be deallocated.
// This does not check isa.fast_rr; if there is an RR override then
// it was already called and it chose to call [super release].
// 
// handleUnderflow=false is the frameless fast path.
// handleUnderflow=true is the framed slow path including side table borrow
// The code is structured this way to prevent duplication.

ALWAYS_INLINE bool
objc_object::rootRelease()
{
    return rootRelease(true, false);
}

ALWAYS_INLINE bool 
objc_object::rootReleaseShouldDealloc()
{
    return rootRelease(false, false);
}

// 如果对象引用计数为0，则需要被dealloc 就返回 true，否则返回 false
// 第一个参数是若引用计数等于0，是否执行dealloc，但是无论执行dealloc，都会返回true
ALWAYS_INLINE bool 
objc_object::rootRelease(bool performDealloc, bool handleUnderflow)
{
    assert(!UseGC);
    // tagged pointer 不需要 retain release
    if (isTaggedPointer()) return false;

    bool sideTableLocked = false;

    isa_t oldisa;
    isa_t newisa;

 retry:
    do {
        oldisa = LoadExclusive(&isa.bits);
        newisa = oldisa;
        // 如果没有 indexed ，直接操作 side table
        if (!newisa.indexed) {
            goto unindexed;
        }
        // don't check newisa.fast_rr; we already called any RR overrides
        uintptr_t carry;
        // isa 中存的引用计数减一
        newisa.bits = subc(newisa.bits, RC_ONE, 0, &carry);  // extra_rc--
        // 如果溢出了（向下溢出）
        if (carry) {
            goto underflow;
        }
    } while (!StoreReleaseExclusive(&isa.bits, oldisa.bits, newisa.bits));

    if (sideTableLocked) sidetable_unlock();
    // 引用计数还大于0，不需要dealloc，所以返回false
    return false;

 underflow:
    // newisa.extra_rc-- underflowed: borrow from side table or deallocate

    // abandon newisa to undo the decrement
    // 让 newisa 重新等于 oldisa，回到减一前的状态
    newisa = oldisa;

    // 如果有部分引用计数存在了 side table 中
    if (newisa.has_sidetable_rc) {
        
        // 不处理溢出
        if (!handleUnderflow) {
            // 坑货 rootRelease_underflow 里还是调用 rootRelease 方法
            // 只是第二个参数变成了 true rootRelease(performDealloc, true);
            // 那么终究还是处理了溢出，卧槽，什么逻辑
            return rootRelease_underflow(performDealloc);
        }

        // Transfer retain count from side table to inline storage.

        if (!sideTableLocked) {
            sidetable_lock();
            sideTableLocked = true;
            if (!isa.indexed) {
                // Lost a race vs the indexed -> not indexed transition
                // before we got the side table lock. Stop now to avoid 
                // breaking the safety checks in the sidetable ExtraRC code.
                goto unindexed;
            }
        }

        // Try to remove some retain counts from the side table.
        // 从 side table 减掉大小为 RC_HALF 的引用计数
        size_t borrowed = sidetable_subExtraRC_nolock(RC_HALF);

        // To avoid races, has_sidetable_rc must remain set 
        // even if the side table count is now zero.

        // 为避免 races (竞争？啥玩意儿)，即使现在 side table 里存的引用计数是0，has_sidetable_rc 也必须保持 1
        
        // 若原来side table里存有引用计数，那么borrowed应该等于RC_HALF，猜的
        // 若 borrowed < 0，side table 里肯定没存引用计数
        if (borrowed > 0) {
            // Side table retain count decreased.
            // Try to add them to the inline count.
            
            // release 操作，所以需要减一
            newisa.extra_rc = borrowed - 1;  // redo the original decrement too
            // 向 isa.bits 里装载新的 newisa.bits
            bool stored = StoreExclusive(&isa.bits, oldisa.bits, newisa.bits);
            
            // 如果失败了，立即换 addc 方法重新尝试
            if (!stored) {
                // Inline update failed. 
                // Try it again right now. This prevents livelock(活锁？) on LL/SC
                // architectures where the side table access itself may have 
                // dropped the reservation.
                isa_t oldisa2 = LoadExclusive(&isa.bits);
                isa_t newisa2 = oldisa2;
                if (newisa2.indexed) {
                    uintptr_t overflow;
                    // 向 newisa2.bits 一次加 borrowed-1 个引用计数
                    // 并且看有没有溢出
                    newisa2.bits = 
                        addc(newisa2.bits, RC_ONE * (borrowed-1), 0, &overflow);
                    if (!overflow) {
                        // 如果没有溢出，将新的 newisa2 装进 isa.bits 里
                        stored = StoreReleaseExclusive(&isa.bits, oldisa2.bits, newisa2.bits);
                    }
                }
            }

            // 所有的努力都失败了，那么就只能将引用计数先重新放回 side table，然后回到 retry，再重头尝试一次，妈蛋，真简单粗暴
            if (!stored) {
                // Inline update failed.
                // Put the retains back in the side table.
                sidetable_addExtraRC_nolock(borrowed);
                goto retry;
            }

            // Decrement successful after borrowing from side table.
            // This decrement cannot be the deallocating decrement - the side 
            // table lock and has_sidetable_rc bit ensure that if everyone 
            // else tried to -release while we worked, the last one would block.
            sidetable_unlock();
            
            // 因为side table里有引用计数，所以引用计数肯定大于 0，所以不需要 dealloc
            return false;
        }
        else {
            // Side table is empty after all. Fall-through to the dealloc path.
            // side table 取出的引用计数等于 0，即这个对象总共的引用计数是 0，对象就可以干掉了，就会走到下面的 dealloc
        }
    }

    // Really deallocate.
    // 真正在 dealloc 操作 😝😝😝😝😝😝

    if (sideTableLocked) sidetable_unlock();

    // 如果已经在 dealloc , 就尴尬了，直接报错
    if (newisa.deallocating) {
        return overrelease_error();
    }
    
    // 标记为正在 dealloc
    newisa.deallocating = true;
    
    // 装载失败，又要重新来一次，啊，卧槽
    if (!StoreExclusive(&isa.bits, oldisa.bits, newisa.bits)) goto retry;
    __sync_synchronize();
    if (performDealloc) {
        // 执行 dealloc，最终的 dealloc 还是由 SEL_dealloc 实现
        // SEL_dealloc 里究竟干了啥呢
        ((void(*)(objc_object *, SEL))objc_msgSend)(this, SEL_dealloc);
    }
    return true;

 unindexed: // 如果引用计数等信息都存在了 side table 中，就调用 sidetable_release 进行 release
    if (sideTableLocked) sidetable_unlock();
    return sidetable_release(performDealloc);
}


// Equivalent to [this autorelease], with shortcuts if there is no override
inline id 
objc_object::autorelease()
{
    // UseGC is allowed here, but requires hasCustomRR.
    assert(!UseGC  ||  ISA()->hasCustomRR());

    if (isTaggedPointer()) {
        return (id)this;
    }
    if (! ISA()->hasCustomRR()) {
        return rootAutorelease();
    }

    return ((id(*)(objc_object *, SEL))objc_msgSend)(this, SEL_autorelease);
}


// Base autorelease implementation, ignoring overrides.
inline id 
objc_object::rootAutorelease()
{
    assert(!UseGC);

    if (isTaggedPointer()) return (id)this;
    // 检测是否支持 Optimized Return（不知道干嘛用的）
    if (prepareOptimizedReturn(ReturnAtPlus1)) return (id)this;

    // rootAutorelease2 里的操作是，将当前对象添加进了当前的 autoreleasepage 中
    return rootAutorelease2();
}

// 取得对象的所有引用计数，包括 isa 中的和 side table 中的
inline uintptr_t 
objc_object::rootRetainCount()
{
    assert(!UseGC);
    if (isTaggedPointer()) return (uintptr_t)this;

    // side table 加锁
    sidetable_lock();
    isa_t bits = LoadExclusive(&isa.bits);
    // 如果 indexed ，则有一部分引用计数存在了 isa.bits 中
    if (bits.indexed) {
        // 看来 extra_rc 中存的真的是减一后的值
        uintptr_t rc = 1 + bits.extra_rc;
        // 如果side table有引用计数
        if (bits.has_sidetable_rc) {
            // 加上side table中存的引用计数
            rc += sidetable_getExtraRC_nolock();
        }
        // 解锁side table后返回引用计数
        sidetable_unlock();
        return rc;
    }

    // 没有 index，则全部引用计数都在side table中
    // 直接返回side table中存的引用计数
    sidetable_unlock();
    return sidetable_retainCount();
}


// SUPPORT_NONPOINTER_ISA
#else
// not SUPPORT_NONPOINTER_ISA

// not SUPPORT_NONPOINTER_ISA 的时候，引用计数都保存在 side table 中
// 所以少了很多判断逻辑，代码都很简单
    
inline Class 
objc_object::ISA() 
{
    assert(!isTaggedPointer());
    // 不支持SUPPORT_NONPOINTER_ISA的话，
    // isa_t 结构体中只存了 cls ，所以可以直接取，不需要做位运算
    return isa.cls;
}


inline bool 
objc_object::hasIndexedIsa()
{
    return false;
}


inline Class 
objc_object::getIsa() 
{
#if SUPPORT_TAGGED_POINTERS
    if (isTaggedPointer()) {
        // 检验对象是否是 tagged pointer 的算法
        uintptr_t slot = ((uintptr_t)this >> TAG_SLOT_SHIFT) & TAG_SLOT_MASK;
        return objc_tag_classes[slot];
    }
#endif
    return ISA();
}


inline void 
objc_object::initIsa(Class cls)
{
    assert(!isTaggedPointer()); 
    isa = (uintptr_t)cls; 
}


inline void 
objc_object::initClassIsa(Class cls)
{
    initIsa(cls);
}


inline void 
objc_object::initProtocolIsa(Class cls)
{
    initIsa(cls);
}


inline void 
objc_object::initInstanceIsa(Class cls, bool)
{
    initIsa(cls);
}


inline void 
objc_object::initIsa(Class cls, bool, bool)
{ 
    initIsa(cls);
}


inline Class 
objc_object::changeIsa(Class cls)
{
    // This is almost always rue but there are 
    // enough edge cases that we can't assert it.
    // assert(cls->isFuture()  ||  
    //        cls->isInitializing()  ||  cls->isInitialized());

    assert(!isTaggedPointer()); 
    
    isa_t oldisa, newisa;
    newisa.cls = cls;
    do {
        oldisa = LoadExclusive(&isa.bits);
    } while (!StoreExclusive(&isa.bits, oldisa.bits, newisa.bits));
    
    if (oldisa.cls  &&  oldisa.cls->instancesHaveAssociatedObjects()) {
        cls->setInstancesHaveAssociatedObjects();
    }
    
    return oldisa.cls;
}

    
inline bool 
objc_object::isTaggedPointer() 
{
#if SUPPORT_TAGGED_POINTERS
    // TAG_MASK 的定义就在当前文件里
    return ((uintptr_t)this & TAG_MASK);
#else
    return false;
#endif
}


inline bool
objc_object::hasAssociatedObjects()
{
    assert(!UseGC);

    return getIsa()->instancesHaveAssociatedObjects();
}


inline void
objc_object::setHasAssociatedObjects()
{
    assert(!UseGC);

    getIsa()->setInstancesHaveAssociatedObjects();
}


inline bool
objc_object::isWeaklyReferenced()
{
    assert(!isTaggedPointer());
    assert(!UseGC);

    return sidetable_isWeaklyReferenced();
}


inline void 
objc_object::setWeaklyReferenced_nolock()
{
    assert(!isTaggedPointer());
    assert(!UseGC);

    sidetable_setWeaklyReferenced_nolock();
}


inline bool
objc_object::hasCxxDtor()
{
    assert(!isTaggedPointer());
    return isa.cls->hasCxxDtor();
}


inline bool 
objc_object::rootIsDeallocating()
{
    assert(!UseGC);

    if (isTaggedPointer()) return false;
    return sidetable_isDeallocating();
}


inline void 
objc_object::clearDeallocating()
{
    sidetable_clearDeallocating();
}


inline void
objc_object::rootDealloc()
{
    if (isTaggedPointer()) return;
    object_dispose((id)this);
}


// Equivalent to calling [this retain], with shortcuts if there is no override
inline id 
objc_object::retain()
{
    // UseGC is allowed here, but requires hasCustomRR.
    assert(!UseGC  ||  ISA()->hasCustomRR());
    assert(!isTaggedPointer());

    if (! ISA()->hasCustomRR()) {
        return sidetable_retain();
    }

    return ((id(*)(objc_object *, SEL))objc_msgSend)(this, SEL_retain);
}


// Base retain implementation, ignoring overrides.
// This does not check isa.fast_rr; if there is an RR override then 
// it was already called and it chose to call [super retain].
inline id 
objc_object::rootRetain()
{
    assert(!UseGC);

    if (isTaggedPointer()) return (id)this;
    return sidetable_retain();
}


// Equivalent to calling [this release], with shortcuts if there is no override
inline void
objc_object::release()
{
    // UseGC is allowed here, but requires hasCustomRR.
    assert(!UseGC  ||  ISA()->hasCustomRR());
    assert(!isTaggedPointer());

    if (! ISA()->hasCustomRR()) {
        sidetable_release();
        return;
    }
    
    ((void(*)(objc_object *, SEL))objc_msgSend)(this, SEL_release);
}


// Base release implementation, ignoring overrides.
// Does not call -dealloc.
// Returns true if the object should now be deallocated.
// This does not check isa.fast_rr; if there is an RR override then 
// it was already called and it chose to call [super release].
    
// NOT SUPPORT_NONPOINTER_ISA 版本的 rootRelease 真简单啊
// 引用计数全都存在 side table 里，需要做的逻辑就少太多了
inline bool 
objc_object::rootRelease()
{
    assert(!UseGC);

    if (isTaggedPointer()) return false;
    // 将其从 side table 中删除，并 dealloc
    return sidetable_release(true);
}

inline bool 
objc_object::rootReleaseShouldDealloc()
{
    if (isTaggedPointer()) return false;
    // 将其从 side table 中删除，但不 dealloc
    return sidetable_release(false);
}


// Equivalent to [this autorelease], with shortcuts if there is no override
inline id 
objc_object::autorelease()
{
    // UseGC is allowed here, but requires hasCustomRR.
    assert(!UseGC  ||  ISA()->hasCustomRR());

    if (isTaggedPointer()) return (id)this;
    if (! ISA()->hasCustomRR()) return rootAutorelease();

    return ((id(*)(objc_object *, SEL))objc_msgSend)(this, SEL_autorelease);
}


// Base autorelease implementation, ignoring overrides.
inline id 
objc_object::rootAutorelease()
{
    assert(!UseGC);

    if (isTaggedPointer()) return (id)this;
    // Optimized adj.最佳的，准备最佳的返回，看不懂什么鬼
    if (prepareOptimizedReturn(ReturnAtPlus1)) return (id)this;

    return rootAutorelease2();
}


// Base tryRetain implementation, ignoring overrides.
// This does not check isa.fast_rr; if there is an RR override then 
// it was already called and it chose to call [super _tryRetain].
inline bool 
objc_object::rootTryRetain()
{
    assert(!UseGC);

    if (isTaggedPointer()) return true;
    return sidetable_tryRetain();
}


inline uintptr_t 
objc_object::rootRetainCount()
{
    assert(!UseGC);

    if (isTaggedPointer()) return (uintptr_t)this;
    return sidetable_retainCount();
}


// not SUPPORT_NONPOINTER_ISA

#endif


#if SUPPORT_RETURN_AUTORELEASE

/***********************************************************************
  Fast handling of return through Cocoa's +0 autoreleasing convention（约定、习俗）.
  The caller and callee（被调用者） cooperate to keep the returned object
  out of the autorelease pool and eliminate（消除） redundant（多余的） retain/release pairs.

  An optimized callee looks at the caller's instructions following the 
  return. If the caller's instructions are also optimized then the callee 
  skips all retain count operations: no autorelease, no retain/autorelease.
  Instead it saves the result's current retain count (+0 or +1) in 
  thread-local storage. If the caller does not look optimized then 
  the callee performs autorelease or retain/autorelease as usual.

  An optimized caller looks at the thread-local storage. If the result 
  is set then it performs any retain or release needed to change the 
  result from the retain count left by the callee to the retain count 
  desired by the caller. Otherwise the caller assumes the result is 
  currently at +0 from an unoptimized callee and performs any retain 
  needed for that case.

  There are two optimized callees:
    objc_autoreleaseReturnValue
      result is currently +1. The unoptimized path autoreleases it.
    objc_retainAutoreleaseReturnValue
      result is currently +0. The unoptimized path retains and autoreleases it.

  There are two optimized callers:
    objc_retainAutoreleasedReturnValue
      caller wants the value at +1. The unoptimized path retains it.
    objc_unsafeClaimAutoreleasedReturnValue
      caller wants the value at +0 unsafely. The unoptimized path does nothing.

  Example:

    Callee:
      // compute ret at +1
      return objc_autoreleaseReturnValue(ret);
    
    Caller:
      ret = callee();
      ret = objc_retainAutoreleasedReturnValue(ret);
      // use ret at +1 here

    Callee sees the optimized caller, sets TLS, and leaves the result at +1.
    Caller sees the TLS, clears it, and accepts the result at +1 as-is.

  The callee's recognition of the optimized caller is architecture-dependent.
  i386 and x86_64: Callee looks for `mov rax, rdi` followed by a call or 
    jump instruction to objc_retainAutoreleasedReturnValue or 
    objc_unsafeClaimAutoreleasedReturnValue. 
  armv7: Callee looks for a magic nop `mov r7, r7` (frame pointer register). 
  arm64: Callee looks for a magic nop `mov x29, x29` (frame pointer register). 

  Tagged pointer objects do participate in the optimized return scheme, 
  because it saves message sends. They are not entered in the autorelease 
  pool in the unoptimized case.
**********************************************************************/

/*
    方法返回值时的 autorelease 机制
    
    那么这里有一个问题：为什么方法返回值的时候需要用到 autorelease 机制呢？
    
    这涉及到两个角色的问题。一个角色是调用方法接收返回值的接收方。当参数被作为返回值 return 之后，接收方如果要接着使用它就需要强引用它，使它 retainCount +1，用完后再清理，使它 retainCount -1。有持有就有清理，这是接收方的责任。另一个角色就是返回对象的方法，即提供方。在方法中创建了对象并作为返回值时，一方面你创建了这个对象你就得负责释放它，有创建就有释放，这是创建者的责任。另一方面你得保证返回时对象没被释放以便方法外的接收方能拿到有效的对象，否则你返回的是 nil，有何意义呢。所以就需要找一个合理的机制既能延长这个对象的生命周期，又能保证对其释放。这个机制就是 autorelease 机制。
    
    当对象作为参数从方法返回时，会被放到正在使用的 Autorelease Pool 中，由这个 Autorelease Pool 强引用这个对象而不是立即释放，从而延长了对象的生命周期，Autorelease Pool 自己销毁的时候会把它里面的对象都顺手清理掉，从而保证了对象会被释放。但是这里也引出另一个问题：既然会延长对象的生命周期到 Autorelease Pool 被销毁的时候，那么 Autorelease Pool 的生命周期是多久呢？会不会在 Autorelease Pool 都销毁了，接收方还没接收到对象呢？
    
    Autorelease Pool 是与线程一一映射的，这就是说一个 autoreleased 的对象的延迟释放是发生在它所在的 Autorelease Pool 对应的线程上的。因此，在方法返回值的这个场景中，如果 Autorelease Pool 的 drain 方法没有在接收方和提供方交接的过程中触发，那么 autoreleased 对象是不会被释放的（除非严重错乱的使用线程）。
    
    通常，Autorelease Pool 的销毁会被安排在很好的时间点上：
    
    Run Loop 会在每次 loop 到尾部时销毁 Autorelease Pool。
    GCD 的 dispatched blocks 会在一个 Autorelease Pool 的上下文中执行，这个 Autorelease Pool 不时的就被销毁了（依赖于实现细节）。NSOperationQueue 也是类似。
    其他线程则会各自对他们对应的 Autorelease Pool 的生命周期负责。
    至此，我们知道了为何方法返回值需要 autorelease 机制，以及这一机制是如何保障接收方能从提供方那里获得依然鲜活的对象。

    在 MRC 时代，当我们自己创建了对象并把它作为方法的返回值返回出去时，需要手动调用对象的 autorelease 方法，如上节所讲的利用 autorelease 机制正确返回对象。到了 ARC 时代，ARC 需要保持对 MRC 代码的兼容，这就意味着 MRC 的实现和 ARC 的实现可以相互替换，而对象接收方和对象提供方无需知道对方是 MRC 实现还是 ARC 实现也能正确工作。比如，当基于 MRC 实现的代码调用你的一个 ARC 实现的方法来获取一个对象，那么你的方法必须同样采用上文所讲的 autorelease 机制来返回对象以确保对象接收方能正确获得对象。所以，即使在 ARC 模式下对象的 autorelease 方法不再能被显示调用，但是 autorelease 的机制仍然是在默默的工作着，只是编译器在帮你实践这一机制。
    
  ARC 提出了巧妙的运行时优化方案来跳过 autorelease 机制。这个过程是这样的：当方法的调用方和实现方的代码都是基于 ARC 实现的时候，在方法 return 的时候，ARC 会调用 objc_autoreleaseReturnValue() 替代前面说的 autorelease。在调用方持有方法返回对象的时候（也就是做 retain 的时候），ARC 会调用 objc_retainAutoreleasedReturnValue()。在调用 objc_autoreleaseReturnValue() 时，它会在栈上查询 return address 来确定 return value 是否会被传给 objc_retainAutoreleasedReturnValue()。如果没传，那么它就会走前文所讲的 autorelease 的过程。如果传了（这表明返回值能顺利从提供方交接给接收方），那么它就跳过 autorelease 并同时修改 return address 来跳过 objc_retainAutoreleasedReturnValue()，从而一举消除了 autorelease 和 retain 的过程。这个方案可以在 MRC-to-ARC 调用、ARC-to-ARC 调用以及 ARC-to-MRC 调用中正确工作，并在符合条件的一些 ARC-to-ARC 调用中消除 autorelease 机制。
*/
    
# if __x86_64__

static ALWAYS_INLINE bool 
callerAcceptsOptimizedReturn(const void * const ra0)
{
    const uint8_t *ra1 = (const uint8_t *)ra0;
    const uint16_t *ra2;
    const uint32_t *ra4 = (const uint32_t *)ra1;
    const void **sym;

#define PREFER_GOTPCREL 0
#if PREFER_GOTPCREL
    // 48 89 c7    movq  %rax,%rdi
    // ff 15       callq *symbol@GOTPCREL(%rip)
    if (*ra4 != 0xffc78948) {
        return false;
    }
    if (ra1[4] != 0x15) {
        return false;
    }
    ra1 += 3;
#else
    // 48 89 c7    movq  %rax,%rdi
    // e8          callq symbol
    if (*ra4 != 0xe8c78948) {
        return false;
    }
    ra1 += (long)*(const int32_t *)(ra1 + 4) + 8l;
    ra2 = (const uint16_t *)ra1;
    // ff 25       jmpq *symbol@DYLDMAGIC(%rip)
    if (*ra2 != 0x25ff) {
        return false;
    }
#endif
    ra1 += 6l + (long)*(const int32_t *)(ra1 + 2);
    sym = (const void **)ra1;
    if (*sym != objc_retainAutoreleasedReturnValue  &&  
        *sym != objc_unsafeClaimAutoreleasedReturnValue) 
    {
        return false;
    }

    return true;
}

// __x86_64__
# elif __arm__

static ALWAYS_INLINE bool 
callerAcceptsOptimizedReturn(const void *ra)
{
    // if the low bit is set, we're returning to thumb mode
    if ((uintptr_t)ra & 1) {
        // 3f 46          mov r7, r7
        // we mask off the low bit via subtraction
        if (*(uint16_t *)((uint8_t *)ra - 1) == 0x463f) {
            return true;
        }
    } else {
        // 07 70 a0 e1    mov r7, r7
        if (*(uint32_t *)ra == 0xe1a07007) {
            return true;
        }
    }
    return false;
}

// __arm__
# elif __arm64__

// 判断调用者是否能接受优化的返回值（避开 autorelease）
static ALWAYS_INLINE bool 
callerAcceptsOptimizedReturn(const void *ra)
{
    // fd 03 1d aa    mov fp, fp
    if (*(uint32_t *)ra == 0xaa1d03fd) {
        return true;
    }
    return false;
}

// __arm64__
# elif __i386__  &&  TARGET_IPHONE_SIMULATOR

static inline bool 
callerAcceptsOptimizedReturn(const void *ra)
{
    return false;
}

// __i386__  &&  TARGET_IPHONE_SIMULATOR
# else

#warning unknown architecture

static ALWAYS_INLINE bool 
callerAcceptsOptimizedReturn(const void *ra)
{
    return false;
}

// unknown architecture
# endif


static ALWAYS_INLINE ReturnDisposition 
getReturnDisposition()
{
    return (ReturnDisposition)(uintptr_t)tls_get_direct(RETURN_DISPOSITION_KEY);
}


static ALWAYS_INLINE void 
setReturnDisposition(ReturnDisposition disposition)
{
    tls_set_direct(RETURN_DISPOSITION_KEY, (void*)(uintptr_t)disposition);
}


// Try to prepare for optimized return with the given disposition (+0 or +1).
// Returns true if the optimized path is successful.
// Otherwise the return value must be retained and/or autoreleased as usual.
    
// 准备优化返回值，如果成功了就返回true
// 失败的话，就返回false，返回值就只能按原来的套路 - autorelease 防止对象在调用方拿到返回值前就被释放
static ALWAYS_INLINE bool 
prepareOptimizedReturn(ReturnDisposition disposition)
{
    assert(getReturnDisposition() == ReturnAtPlus0);

    if (callerAcceptsOptimizedReturn(__builtin_return_address(0))) {
        if (disposition) {
            setReturnDisposition(disposition);
        }
        return true;
    }

    return false;
}


// Try to accept an optimized return.
// Returns the disposition of the returned object (+0 or +1).
// An un-optimized return is +0.
static ALWAYS_INLINE ReturnDisposition 
acceptOptimizedReturn()
{
    ReturnDisposition disposition = getReturnDisposition();
    setReturnDisposition(ReturnAtPlus0);  // reset to the unoptimized state
    return disposition;
}


// SUPPORT_RETURN_AUTORELEASE
#else
// not SUPPORT_RETURN_AUTORELEASE


static ALWAYS_INLINE bool
prepareOptimizedReturn(ReturnDisposition disposition __unused)
{
    return false;
}


static ALWAYS_INLINE ReturnDisposition 
acceptOptimizedReturn()
{
    return ReturnAtPlus0;
}


// not SUPPORT_RETURN_AUTORELEASE
#endif


// _OBJC_OBJECT_H_
#endif
