/*
 * Copyright (c) 2010-2011 Apple Inc. All rights reserved.
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

#include "objc-weak.h"

#include <stdint.h>
#include <stdbool.h>
#include <sys/types.h>
#include <libkern/OSAtomic.h>

// 计算 entry 中有多少个 referrer
#define TABLE_SIZE(entry) (entry->mask ? entry->mask + 1 : 0)

// 向 entry 中添加 referrer
static void append_referrer(weak_entry_t *entry, objc_object **new_referrer);

BREAKPOINT_FUNCTION(
    void objc_weak_error(void)
);

/** 
 * Unique hash function for object pointers only.
 * 
 * @param key The object pointer
 * 
 * @return Size unrestricted hash of pointer.
 */
// 返回地址的 hash 值
static inline uintptr_t hash_pointer(objc_object *key) {
    return ptr_hash((uintptr_t)key);
}

/** 
 * Unique hash function for weak object pointers only.
 * 
 * @param key The weak object pointer. 
 * 
 * @return Size unrestricted hash of pointer.
 */
static inline uintptr_t w_hash_pointer(objc_object **key) {
    return ptr_hash((uintptr_t)key);
}

/** 
 * Grow the entry's hash table of referrers. Rehashes each
 * of the referrers.
 * 
 * @param entry Weak pointer hash set for a particular object.
 */
// 给 entry 扩容，然后插入 new_referrer
__attribute__((noinline, used))
static void grow_refs_and_insert(weak_entry_t *entry, 
                                 objc_object **new_referrer)
{
    assert(entry->out_of_line);

    size_t old_size = TABLE_SIZE(entry);
    // 如果原来有 size ，就扩容一倍，否则初始 size 为 8
    size_t new_size = old_size ? old_size * 2 : 8;

    size_t num_refs = entry->num_refs;
    weak_referrer_t *old_refs = entry->referrers;
    entry->mask = new_size - 1;
    
    // 在堆上分配一片新的内存用于存放 referrers
    entry->referrers = (weak_referrer_t *)
        calloc(TABLE_SIZE(entry), sizeof(weak_referrer_t));
    entry->num_refs = 0;
    entry->max_hash_displacement = 0;
    
    // 将原来的 referrer 都拷贝到新的 entry 上
    for (size_t i = 0; i < old_size && num_refs > 0; i++) {
        if (old_refs[i] != nil) {
            append_referrer(entry, old_refs[i]);
            num_refs--;
        }
    }
    // Insert
    // 插入新的 referrer
    append_referrer(entry, new_referrer);
    // 将原来的 referrers 所占的内存释放，因为是在堆上分配的内存，所以必须手动释放
    if (old_refs) {
        free(old_refs);
    }
}

/** 
 * Add the given referrer to set of weak pointers in this entry.
 * Does not perform duplicate checking (b/c weak pointers are never
 * added to a set twice). 
 *
 * @param entry The entry holding the set of weak pointers. 
 * @param new_referrer The new weak pointer to be added.
 */
static void append_referrer(weak_entry_t *entry, objc_object **new_referrer)
{
    // out_of_line == 0 的情况
    if (! entry->out_of_line) {
        // Try to insert inline.
        // inline_referrers 还放得下，就放在 inline_referrers 里
        for (size_t i = 0; i < WEAK_INLINE_COUNT; i++) {
            if (entry->inline_referrers[i] == nil) {
                entry->inline_referrers[i] = new_referrer;
                return;
            }
        }

        // inline_referrers 里放不下了，只能放在 referrers 数组里
        // Couldn't insert inline. Allocate out of line.
        // 为 referrers 数组在堆上分配空间
        weak_referrer_t *new_referrers = (weak_referrer_t *)
            calloc(WEAK_INLINE_COUNT, sizeof(weak_referrer_t));
        // This constructed table is invalid, but grow_refs_and_insert
        // will fix it and rehash it.
        //
        // 靠，知道是错的还这样写.....真任性
        
        // 将 inline_referrers 存的 4 个对象拷贝到 new_referrers 中
        for (size_t i = 0; i < WEAK_INLINE_COUNT; i++) {
            new_referrers[i] = entry->inline_referrers[i];
        }
        entry->referrers = new_referrers;
        entry->num_refs = WEAK_INLINE_COUNT;
        entry->out_of_line = 1;
        entry->mask = WEAK_INLINE_COUNT-1;
        entry->max_hash_displacement = 0;
    }

    assert(entry->out_of_line);

    // 如果使用超过 3/4，就扩容以后再插入
    // 当 out_of_line == 0 并且已经满了的情况下，这段一定走，所以上面错误的部分会在 grow_refs_and_insert 中被纠正
    if (entry->num_refs >= TABLE_SIZE(entry) * 3/4) {
        return grow_refs_and_insert(entry, new_referrer);
    }
    size_t index = w_hash_pointer(new_referrer) & (entry->mask);
    size_t hash_displacement = 0;
    // 找到可以存放 new_referrer 的索引位置
    while (entry->referrers[index] != NULL) {
        index = (index+1) & entry->mask;
        hash_displacement++;
    }
    if (hash_displacement > entry->max_hash_displacement) {
        entry->max_hash_displacement = hash_displacement;
    }
    // 将 index 处的对象替换成 new_referrer
    weak_referrer_t &ref = entry->referrers[index];
    ref = new_referrer;
    // 总数加一
    entry->num_refs++;
}

/** 
 * Remove old_referrer from set of referrers, if it's present.
 * Does not remove duplicates, because duplicates should not exist. 
 * 
 * @todo this is slow if old_referrer is not present. Is this ever the case? 
 *
 * @param entry The entry holding the referrers.
 * @param old_referrer The referrer to remove. 
 */
// 将 old_referrer 从 entry 中移除
static void remove_referrer(weak_entry_t *entry, objc_object **old_referrer)
{
    // out_of_line == 0 的情况
    if (! entry->out_of_line) {
        // 因为最多只能存 4 个，所以直接循环查找就好了，效率不低
        for (size_t i = 0; i < WEAK_INLINE_COUNT; i++) {
            // 找到后，将那个索引处的值置为 nil
            if (entry->inline_referrers[i] == old_referrer) {
                entry->inline_referrers[i] = nil; // 但是 old_referrer 并不会变
                return;
            }
        }
        // 还真造出了这个错，__weak 变量必须注册，不然不会有 weak table
        // 比如：
        //        id a = [NSObject new];
        //        id b = [NSObject new];
        //        id c;
        //        printf("a = %p\n", a);
        //        printf("b = %p\n", b);
        //        printf("c = %p\n", c); // c = 0x0
        //        printf("--------\n");
        //        objc_storeWeak(&c, a);
        //        printf("a = %p\n", a);
        //        printf("b = %p\n", b);
        //        printf("c = %p\n", c);
        //        printf("--------\n");
        //        objc_storeWeak(&c, b); // 报错
        //        printf("a = %p\n", a);
        //        printf("b = %p\n", b);
        //        printf("c = %p\n", c);
        _objc_inform("Attempted to unregister unknown __weak variable "
                     "at %p. This is probably incorrect use of "
                     "objc_storeWeak() and objc_loadWeak(). "
                     "Break on objc_weak_error to debug.\n", 
                     old_referrer);
        objc_weak_error();
        return;
    }

    // out_of_line == 1 的情况
    size_t index = w_hash_pointer(old_referrer) & (entry->mask);
    // 通过 hash 的方法找到 old_referrer 所在的索引
    size_t hash_displacement = 0;
    while (entry->referrers[index] != old_referrer) {
        index = (index+1) & entry->mask;
        hash_displacement++;
        if (hash_displacement > entry->max_hash_displacement) {
            _objc_inform("Attempted to unregister unknown __weak variable "
                         "at %p. This is probably incorrect use of "
                         "objc_storeWeak() and objc_loadWeak(). "
                         "Break on objc_weak_error to debug.\n", 
                         old_referrer);
            objc_weak_error();
            return;
        }
    }
    // 将index处的值置为 nil
    entry->referrers[index] = nil;
    // 总数减一
    entry->num_refs--;
}

/** 
 * Add new_entry to the object's table of weak references.
 * Does not check whether the referent is already in the table.
 */
// 将 new_entry 添加进 weak_table 中，不要和 append_referrer 搞混了
static void weak_entry_insert(weak_table_t *weak_table, weak_entry_t *new_entry)
{
    weak_entry_t *weak_entries = weak_table->weak_entries;
    assert(weak_entries != nil);

    // 通过 hash 决定 索引
    size_t index = hash_pointer(new_entry->referent) & (weak_table->mask);
    size_t hash_displacement = 0;
    
    // 如果该索引中已经有 entry，那么这个索引就不能用了，就找下一个索引
    while (weak_entries[index].referent != nil) {
        index = (index+1) & weak_table->mask;
        hash_displacement++;
    }

    // 将 new_entry 放入指定的索引中
    weak_entries[index] = *new_entry;
    weak_table->num_entries++;

    if (hash_displacement > weak_table->max_hash_displacement) {
        weak_table->max_hash_displacement = hash_displacement;
    }
}

// 调整 weak table 的容量为 new_size
static void weak_resize(weak_table_t *weak_table, size_t new_size)
{
    size_t old_size = TABLE_SIZE(weak_table);

    weak_entry_t *old_entries = weak_table->weak_entries;
    // 在堆中分配新的区域
    weak_entry_t *new_entries = (weak_entry_t *)
        calloc(new_size, sizeof(weak_entry_t));

    weak_table->mask = new_size - 1; // 靠 mask 竟然是 size - 1
    weak_table->weak_entries = new_entries;
    weak_table->max_hash_displacement = 0;
    weak_table->num_entries = 0; // 先置0，下面边插入边加 // restored by weak_entry_insert below
    
    if (old_entries) {
        weak_entry_t *entry;
        weak_entry_t *end = old_entries + old_size;
        // 循环将 old_entries 中的 enrty 插入到新的 weak table 中的新 new_entries 中
        for (entry = old_entries; entry < end; entry++) {
            // entry 里的 referent 不为空，即 entry 里确实有数据，才将其插入新 weak table 中
            // 如果 entry 被清空过，entry->referent 会变成 0x0，见 weak_entry_remove
            if (entry->referent) {
                weak_entry_insert(weak_table, entry);
            }
        }
        // 将原来的 old_entries 释放
        free(old_entries);
    }
}

// Grow the given zone's table of weak references if it is full.
// weak table 扩大容量
static void weak_grow_maybe(weak_table_t *weak_table)
{
    size_t old_size = TABLE_SIZE(weak_table);

    // Grow if at least 3/4 full.
    // 容量使用超过 3/4 ，就需要扩容
    if (weak_table->num_entries >= old_size * 3 / 4) {
        // 如果原来不等于0，就扩大一倍，否则初始为 64
        weak_resize(weak_table, old_size ? old_size*2 : 64);
    }
}

// Shrink the table if it is mostly empty.
// 缩小容量
static void weak_compact_maybe(weak_table_t *weak_table)
{
    size_t old_size = TABLE_SIZE(weak_table);

    // Shrink if larger than 1024 buckets and at most 1/16 full.
    // 如果 old_size >= 1024 并且使用量少于 1/16 ，就需要缩小容量
    if (old_size >= 1024  && old_size / 16 >= weak_table->num_entries) {
        // 缩小为原来的 1/8
        weak_resize(weak_table, old_size / 8);
        // leaves new table no more than 1/2 full
    }
}


/**
 * Remove entry from the zone's table of weak references.
 */
// 将 entry 从 weak_table 中移除
static void weak_entry_remove(weak_table_t *weak_table, weak_entry_t *entry)
{
    // remove entry
    // 如果 out_of_line == 1，还得手动 free 内存
    if (entry->out_of_line) {
        free(entry->referrers);
    }
    // 我猜是将 entry 所在部分的内存清空
    // 原型：extern void bzero（void *s, int n）;
    // 参数说明：s 要置零的数据的起始地址； n 要置零的数据字节个数。
    // 用法：#include <string.h>
    // 功能：置字节字符串s的前n个字节为零且包括'\0'。
    // 与 memset 的区别是只能清零，memset 可以指定值
    bzero(entry, sizeof(*entry));
    
    // entry 所在的内存清空以后，referent 所在的内存也全变成了 0x0，0x0 与 nil 是等价的
    // 经过实验 NSLog(@"%p", nil); 打印出的也是 0x0

    // weak_table 中 entry 数量减一
    weak_table->num_entries--;

    // 看看需不需要调整 weak table 的容量
    weak_compact_maybe(weak_table);
}


/** 
 * Return the weak reference table entry for the given referent. 
 * If there is no entry for referent, return NULL. 
 * Performs a lookup.
 *
 * @param weak_table 
 * @param referent The object. Must not be nil.
 * 
 * @return The table of weak referrers to this object. 
 */
// 找到弱引用表 weak_table 中指定的对象 referent 所对应的 weak_entry_t
static weak_entry_t *
weak_entry_for_referent(weak_table_t *weak_table, objc_object *referent)
{
    // 不能是 nil
    assert(referent);

    // weak_table 中存的实体数组
    weak_entry_t *weak_entries = weak_table->weak_entries;

    if (!weak_entries) {
        return nil;
    }

    // 通过 Hash 的方法找到 referent 所在的索引，不过实在看不懂
    size_t index = hash_pointer(referent) & weak_table->mask;
    size_t hash_displacement = 0;
    while (weak_table->weak_entries[index].referent != referent) {
        index = (index+1) & weak_table->mask;
        hash_displacement++;
        if (hash_displacement > weak_table->max_hash_displacement) {
            return nil;
        }
    }
    
    // 返回找到的 weak_entry_t，这里可以证明 weak_entries 确实是一个数组
    return &weak_table->weak_entries[index];
}

/** 
 * Unregister an already-registered weak reference.
 * This is used when referrer's storage is about to go away, but referent
 * isn't dead yet. (Otherwise, zeroing referrer later would be a
 * bad memory access.)
 * Does nothing if referent/referrer is not a currently active weak reference.
 * Does not zero referrer.
 * 
 * FIXME currently requires old referent value to be passed in (lame)
 * FIXME unregistration should be automatic if referrer is collected
 * 
 * @param weak_table The global weak table.
 * @param referent The object.
 * @param referrer The weak reference.
 */
// 解除 referrer_id 指针对 referent_id 的弱引用
// 这个方法只在 storeWeak 中用到，用于解除 __weak pointer 对旧值的弱引用
// 与 weak_register_no_lock 相反
void
weak_unregister_no_lock(weak_table_t *weak_table, // 弱引用表
                        id referent_id, // 指针指向的旧值
                        id *referrer_id) // 指针
{
    objc_object *referent = (objc_object *)referent_id;
    objc_object **referrer = (objc_object **)referrer_id; // id * 等价于 objc_object **，即一个指向 objc_object 类型的二级指针

    weak_entry_t *entry;

    // 如果旧值是 nil，那么压根儿不需要解除引用
    if (!referent) return;

    // 找到 referent 对应的 weak entry
    if ((entry = weak_entry_for_referent(weak_table, referent))) {
        
        // 将 referrer 从 entry 里移除
        remove_referrer(entry, referrer);
        // 判断 entry 里现在是否是空的
        bool empty = true;
        if (entry->out_of_line  &&  entry->num_refs != 0) {
            empty = false;
        }
        else {
            // 如果 out_of_line == 0，就只能循环看数组里是否有值
            for (size_t i = 0; i < WEAK_INLINE_COUNT; i++) {
                if (entry->inline_referrers[i]) {
                    empty = false; 
                    break;
                }
            }
        }

        // 如果 entry 里已经空了，就将 entry 从 weak_table 里移除，可以节省空间
        if (empty) {
            weak_entry_remove(weak_table, entry);
        }
    }

    // 这个函数只是将 weak table 中 referrer_id 对 referent_id 的弱引用记录移除
    // 但 referrer_id 实际指向的对象(存储的地址)并没有变，还是原来的值
    // 为什么不置为 nil 呢，说是 objc_storeWeak()（ 其实是 storeWeak() ） 需要值不变
    
    // Do not set *referrer = nil. objc_storeWeak() requires that the 
    // value not change.
}

/** 
 * Registers a new (object, weak pointer) pair. Creates a new weak
 * object entry if it does not exist.
 * 
 * @param weak_table The global weak table.
 * @param referent The object pointed to by the weak reference.
 * @param referrer The weak pointer address.
 */
// 在 weak_table 中注册 referrer_id 对 referent_id 的弱引用
// 这个方法也只在 storeWeak 中用到，用于添加 __weak pointer 对新值的弱引用
// 与 weak_unregister_no_lock 相反
id 
weak_register_no_lock(weak_table_t *weak_table, id referent_id, 
                      id *referrer_id, bool crashIfDeallocating)
{
    objc_object *referent = (objc_object *)referent_id;
    objc_object **referrer = (objc_object **)referrer_id;

    if (!referent  ||  referent->isTaggedPointer()) {
        return referent_id;
    }

    // ensure that the referenced object is viable
    bool deallocating;
    if (!referent->ISA()->hasCustomRR()) {
        deallocating = referent->rootIsDeallocating();
    }
    else {
        BOOL (*allowsWeakReference)(objc_object *, SEL) = 
            (BOOL(*)(objc_object *, SEL))
            object_getMethodImplementation((id)referent, 
                                           SEL_allowsWeakReference);
        if ((IMP)allowsWeakReference == _objc_msgForward) {
            return nil;
        }
        deallocating =
            ! (*allowsWeakReference)(referent, SEL_allowsWeakReference);
    }

    // 如果想要指向的对象正在析构，是不能继续的
    if (deallocating) {
        if (crashIfDeallocating) {
            _objc_fatal("Cannot form weak reference to instance (%p) of "
                        "class %s. It is possible that this object was "
                        "over-released, or is in the process of deallocation.",
                        (void*)referent, object_getClassName((id)referent));
        } else {
            return nil;
        }
    }

    // now remember it and where it is being stored
    weak_entry_t *entry;
    // 找到 referent 所在的 entry
    if ((entry = weak_entry_for_referent(weak_table, referent))) {
        // 将 referrer 添加进这个 entry 中，这样 referrer 就成为 referent 的弱引用之一了
        append_referrer(entry, referrer);
    }
    // 如果没有找到对应的 entry ，那么说明 referent 还没有弱引用，就为其新建一个 entry
    else {
        weak_entry_t new_entry;
        new_entry.referent = referent;
        new_entry.out_of_line = 0;
        new_entry.inline_referrers[0] = referrer;
        // 数组中 4 个referrer全部初始化为 nil
        for (size_t i = 1; i < WEAK_INLINE_COUNT; i++) {
            new_entry.inline_referrers[i] = nil;
        }
        // 检查一下需不需要扩容
        weak_grow_maybe(weak_table);
        // 将新建的 entry 插入 weak table 中
        weak_entry_insert(weak_table, &new_entry);
    }

    // 这个函数只是注册 referrer 和 referent 的联系，
    // 但是暂时不设置 referrer 指向的对象为 referent，这个步骤会在 objc_storeWeak 里做
    
    // Do not set *referrer. objc_storeWeak() requires that the 
    // value not change.

    return referent_id;
}


#if DEBUG
// 判断 referent 有没有被注册，即weak table中是否有它
bool
weak_is_registered_no_lock(weak_table_t *weak_table, id referent_id) 
{
    return weak_entry_for_referent(weak_table, (objc_object *)referent_id);
}
#endif


/** 
 * Called by dealloc; nils out all weak pointers that point to the 
 * provided object so that they can no longer be used.
 * 
 * @param weak_table 
 * @param referent The object being deallocated. 
 */
// 将对象的弱引用清空，并将指向它的 __weak pointer 变成 nil
// 在 sidetable_clearDeallocating 和 clearDeallocating_slow 被调用
void 
weak_clear_no_lock(weak_table_t *weak_table, id referent_id) 
{
    objc_object *referent = (objc_object *)referent_id;

    // 找到 referent 所在的 entry
    weak_entry_t *entry = weak_entry_for_referent(weak_table, referent);
    if (entry == nil) {
        // 一般是不可能发生的，除非 CF/objc 库写错了
        /// XXX shouldn't happen, but does with mismatched CF/objc
        //printf("XXX no entry for clear deallocating %p\n", referent);
        return;
    }

    // zero out references
    weak_referrer_t *referrers;
    size_t count;
    
    // out_of_line == 1，referrer 存在 referrers 中
    if (entry->out_of_line) {
        referrers = entry->referrers;
        count = TABLE_SIZE(entry);
    }
    // out_of_line == 0，referrer 存在 inline_referrers 中
    else {
        referrers = entry->inline_referrers;
        count = WEAK_INLINE_COUNT;
    }
    
    for (size_t i = 0; i < count; ++i) {
        objc_object **referrer = referrers[i];
        if (referrer) {
            // 将 referrer 指向 nil  标记一下，__weak pointer 就是在这里变成 nil 的 ！！！！！！
            if (*referrer == referent) {
                *referrer = nil;
            }
            else if (*referrer) {
                _objc_inform("__weak variable at %p holds %p instead of %p. "
                             "This is probably incorrect use of "
                             "objc_storeWeak() and objc_loadWeak(). "
                             "Break on objc_weak_error to debug.\n", 
                             referrer, (void*)*referrer, (void*)referent);
                objc_weak_error();
            }
        }
    }
    
    // 将 entry 从 weak_table 中移除
    weak_entry_remove(weak_table, entry);
}


/** 
 * This function gets called when the value of a weak pointer is being 
 * used in an expression. Called by objc_loadWeakRetained() which is
 * ultimately called by objc_loadWeak(). The objective is to assert that
 * there is in fact a weak pointer(s) entry for this particular object being
 * stored in the weak-table, and to retain that object so it is not deallocated
 * during the weak pointer's usage.
 * 
 * @param weak_table 
 * @param referrer The weak pointer address. 
 */
/*
  Once upon a time we eagerly cleared *referrer if we saw the referent 
  was deallocating. This confuses code like NSPointerFunctions which 
  tries to pre-flight the raw storage and assumes if the storage is 
  zero then the weak system is done interfering. That is false: the 
  weak system is still going to check and clear the storage later. 
  This can cause objc_weak_error complaints and crashes.
  So we now don't touch the storage until deallocation completes.
*/
// 我猜是查找 referrer 所指向的 referent
// referrer 存有对象，但并不代表 referrer 对这个对象有弱引用，所以需要去 weak table 中查是否真的有弱引用关系
id 
weak_read_no_lock(weak_table_t *weak_table, id *referrer_id) 
{
    objc_object **referrer = (objc_object **)referrer_id;
    objc_object *referent = *referrer;
    if (referent->isTaggedPointer()) {
        return (id)referent;
    }

    weak_entry_t *entry;
    if (referent == nil  ||  
        !(entry = weak_entry_for_referent(weak_table, referent))) 
    {
        return nil;
    }

    if (! referent->ISA()->hasCustomRR()) {
        if (! referent->rootTryRetain()) {
            return nil;
        }
    }
    else {
        BOOL (*tryRetain)(objc_object *, SEL) = (BOOL(*)(objc_object *, SEL))
            object_getMethodImplementation((id)referent, 
                                           SEL_retainWeakReference);
        if ((IMP)tryRetain == _objc_msgForward) {
            return nil;
        }
        if (! (*tryRetain)(referent, SEL_retainWeakReference)) {
            return nil;
        }
    }

    return (id)referent;
}

