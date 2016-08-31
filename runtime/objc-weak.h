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

#ifndef _OBJC_WEAK_H_
#define _OBJC_WEAK_H_

#include <objc/objc.h>
#include "objc-config.h"

__BEGIN_DECLS

/*
The weak table is a hash table governed by a single spin lock.
An allocated blob of memory, most often an object, but under GC any such 
allocation, may have its address stored in a __weak marked storage location 
through use of compiler generated write-barriers or hand coded uses of the 
register weak primitive. Associated with the registration can be a callback 
block for the case when one of the allocated chunks of memory is reclaimed. 
The table is hashed on the address of the allocated memory.  When __weak 
marked memory changes its reference, we count on the fact that we can still 
see its previous reference.

So, in the hash table, indexed by the weakly referenced item, is a list of 
all locations where this address is currently being stored.
 
For ARR, we also keep track of whether an arbitrary object is being 
deallocated by briefly placing it in the table just prior to invoking 
dealloc, and removing it via objc_clear_deallocating just prior to memory 
reclamation.

*/

/// The address of a __weak object reference
typedef objc_object ** weak_referrer_t;

#if __LP64__
#define PTR_MINUS_1 63
#else
#define PTR_MINUS_1 31
#endif

/**
 * The internal structure stored in the weak references table. 
 * It maintains and stores
 * a hash set of weak references pointing to an object.
 * If out_of_line==0, the set is instead a small inline array.
 */
// weak_table_t 中存的实体，存了指向一个对象的弱引用的哈希集合
#define WEAK_INLINE_COUNT 4
struct weak_entry_t {
    DisguisedPtr<objc_object> referent; // 被指向的对象
    union {
        struct {
            weak_referrer_t *referrers; // 一个数组，里面存的是指向 referent 的对象们的地址（二级指针），referrers是这个数组的首地址，用 calloc 在堆上分配的，所以需要需要手动 free
            uintptr_t        out_of_line : 1; // 变量名是 out_of_line ，占 1 个 bit
            uintptr_t        num_refs : PTR_MINUS_1; // 数组中有几个元素，即 referent 有几个弱引用
            uintptr_t        mask;
            uintptr_t        max_hash_displacement;
        };
        struct {
            // out_of_line=0 is LSB of one of these (don't care which)
            weak_referrer_t  inline_referrers[WEAK_INLINE_COUNT];
            
            // 如果 out_of_line == 0，结构体里就只存一个数组，
            // 一样，数组里存指向 referent 的对象们的地址，数组最多可存放 4 个元素
            // 栈上分配，不需要手动 free
        };
    };
};

/**
 * The global weak references table. Stores object ids as keys,
 * and weak_entry_t structs as their values.
 */
// 全局的弱引用表
struct weak_table_t {
    weak_entry_t *weak_entries; // 一个数组，数组每个元素是 weak_entry_t 结构体，里面存了弱引用对象，以及指向它的弱引用们
    size_t    num_entries; // 实体的数量
    uintptr_t mask;
    uintptr_t max_hash_displacement;
};

/// Adds an (object, weak pointer) pair to the weak table.
// 在 weak_table 中注册 referrer 对 referent 的弱引用
id weak_register_no_lock(weak_table_t *weak_table, id referent, 
                         id *referrer, bool crashIfDeallocating);

/// Removes an (object, weak pointer) pair from the weak table.
// 解除 referrer 指针对 referent 的弱引用
void weak_unregister_no_lock(weak_table_t *weak_table, id referent, id *referrer);

#if DEBUG
/// Returns true if an object is weakly referenced somewhere.
bool weak_is_registered_no_lock(weak_table_t *weak_table, id referent);
#endif

/// Assert a weak pointer is valid and retain the object during its use.
// 我猜是查找 referrer 所指向的 referent
// referrer 存有对象，但并不代表 referrer 对这个对象有弱引用，所以需要去 weak table 中查是否真的有弱引用关系
id weak_read_no_lock(weak_table_t *weak_table, id *referrer);

/// Called on object destruction. Sets all remaining weak pointers to nil.
// 将对象的弱引用清空，并将指向它的 __weak pointer 变成 nil
// 在 sidetable_clearDeallocating 和 clearDeallocating_slow 被调用
void weak_clear_no_lock(weak_table_t *weak_table, id referent);

__END_DECLS

#endif /* _OBJC_WEAK_H_ */
