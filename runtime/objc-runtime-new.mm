/*
 * Copyright (c) 2005-2009 Apple Inc.  All Rights Reserved.
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
* objc-runtime-new.m
* Support for new-ABI classes and images.
**********************************************************************/

#if __OBJC2__

#include "objc-private.h"
#include "objc-runtime-new.h"
#include "objc-file.h"
#include "objc-cache.h"
#include <Block.h>
#include <objc/message.h>
#include <mach/shared_region.h>

// 将 Protocol * 类型强转为 protocol_t * 类型
#define newprotocol(p) ((protocol_t *)p)

static void disableTaggedPointers();
static void detach_class(Class cls, bool isMeta);
static void free_class(Class cls);
static Class setSuperclass(Class cls, Class newSuper);
// realize 指定的 class
static Class realizeClass(Class cls);
static method_t *getMethodNoSuper_nolock(Class cls, SEL sel);
static method_t *getMethod_nolock(Class cls, SEL sel);
static IMP addMethod(Class cls, SEL name, IMP imp, const char *types, bool replace);
static NXHashTable *realizedClasses(void);
static bool isRRSelector(SEL sel);
static bool isAWZSelector(SEL sel);
static bool methodListImplementsRR(const method_list_t *mlist);
static bool methodListImplementsAWZ(const method_list_t *mlist);
static void updateCustomRR_AWZ(Class cls, method_t *meth);
static method_t *search_method_list(const method_list_t *mlist, SEL sel);
static void flushCaches(Class cls);
#if SUPPORT_FIXUP
static void fixupMessageRef(message_ref_t *msg);
#endif

static bool MetaclassNSObjectAWZSwizzled; // 记录 NSObject 元类中的 AWZ 方法是否被 swizzled 了
                                          // AWZ 方法是类方法，所以在元类中
                                          // Method Swizzling 方法混合/方法调配
                                          // 在 updateCustomRR_AWZ() 中记录，在 objc_class::setInitialized() 中使用

static bool ClassNSObjectRRSwizzled; // 记录 NSObject 类中的 RR 方法是否被 swizzled 了
                                     // RR 方法是实例方法，所以在实例类中
                                     // 在 updateCustomRR_AWZ() 中记录，在 objc_class::setInitialized() 中使用

#define SDK_FORMAT "%hu.%hhu.%hhu"
#define FORMAT_SDK(v) \
    (unsigned short)(((uint32_t)(v))>>16),  \
    (unsigned  char)(((uint32_t)(v))>>8),   \
    (unsigned  char)(((uint32_t)(v))>>0)

// 一个 IMP，本身不干任何事，只是返回 self
// 只在 methodizeClass() 中用到，给根元类的 SEL_initialize 指定了对应的 IMP，即 objc_noop_imp
// 即给根元类发送 SEL_initialize 消息，不会走到它的 +initialize，而是走 objc_noop_imp，啥也不干
// noop n.等待;无操作
id objc_noop_imp(id self, SEL _cmd __unused) {
    return self;
}


/***********************************************************************
* Lock management
**********************************************************************/
rwlock_t runtimeLock; // runtime 的读写锁
rwlock_t selLock;
mutex_t cacheUpdateLock;
recursive_mutex_t loadMethodLock;

#if SUPPORT_QOS_HACK
pthread_priority_t BackgroundPriority = 0;
pthread_priority_t MainPriority = 0;
# if DEBUG
static __unused void destroyQOSKey(void *arg) {
    _objc_fatal("QoS override level at thread exit is %zu instead of zero", 
                (size_t)(uintptr_t)arg);
}
# endif
#endif

void lock_init(void)
{
#if SUPPORT_QOS_HACK
    BackgroundPriority = _pthread_qos_class_encode(QOS_CLASS_BACKGROUND, 0, 0);
    MainPriority = _pthread_qos_class_encode(qos_class_main(), 0, 0);
# if DEBUG
    pthread_key_init_np(QOS_KEY, &destroyQOSKey);
# endif
#endif
}


/***********************************************************************
* Non-pointer isa decoding
**********************************************************************/
#if SUPPORT_NONPOINTER_ISA

const uintptr_t objc_debug_isa_class_mask  = ISA_MASK;
const uintptr_t objc_debug_isa_magic_mask  = ISA_MAGIC_MASK;
const uintptr_t objc_debug_isa_magic_value = ISA_MAGIC_VALUE;

// die if masks overlap
STATIC_ASSERT((ISA_MASK & ISA_MAGIC_MASK) == 0);

// die if magic is wrong
STATIC_ASSERT((~ISA_MAGIC_MASK & ISA_MAGIC_VALUE) == 0);

// die if virtual address space bound goes up
STATIC_ASSERT((~ISA_MASK & MACH_VM_MAX_ADDRESS) == 0  ||  
              ISA_MASK + sizeof(void*) == MACH_VM_MAX_ADDRESS);

#else

// These variables exist but enforce pointer alignment only.
const uintptr_t objc_debug_isa_class_mask  = (~WORD_MASK);
const uintptr_t objc_debug_isa_magic_mask  = WORD_MASK;
const uintptr_t objc_debug_isa_magic_value = 0;

#endif


typedef locstamped_category_list_t category_list; // 分类列表结构体类型


/*
  Low two bits of mlist->entsize is used as the fixed-up marker.
 
  PREOPTIMIZED VERSION:
    Method lists from shared cache are 1 (uniqued) or 3 (uniqued and sorted).
    (Protocol method lists are not sorted because of their extra parallel data)
    Runtime fixed-up method lists get 3.
  UN-PREOPTIMIZED VERSION:
    Method lists from shared cache are 1 (uniqued) or 3 (uniqued and sorted)
    Shared cache's sorting and uniquing are not trusted, but do affect the 
    location of the selector name string.
    Runtime fixed-up method lists get 2.

  High two bits of protocol->flags is used as the fixed-up marker.
  PREOPTIMIZED VERSION:
    Protocols from shared cache are 1<<30.
    Runtime fixed-up protocols get 1<<30.
  UN-PREOPTIMIZED VERSION:
  Protocols from shared cache are 1<<30.
    Shared cache's fixups are not trusted.
    Runtime fixed-up protocols get 3<<30.
 
 --------------------------------------
 翻译一下，可以更好地理解：
 
 I. 
    mlist->entsize 的最低的 2 位被用作 fixed-up 的标记（可以看 method_list_t 的声明，可以看到 0x3 这个数，
 0x3 就是 0b11 就是 2 位被留做了 fixed-up 的标记）
 
 预优化版本：
    Method lists 来自 shared cache(shared cache 和动态库有关) 的话，就是 0b01 (uniqued 唯一的) 或者 0b11 (uniqued and sorted 唯一并且有序的)
    (Protocol method lists 协议方法列表不是排好序的，因为它们有 extra parallel data 额外的并行数据)
    运行时 fixed-up 的方法列表取得的是 0b11
 非预优化版本：
    Method lists 来自 shared cache 的话，就是 0b01 (uniqued 唯一的) 或者 0b11 (uniqued and sorted 唯一并且有序的)
    Shared cache 的排序和唯一标识是不可信的，但是对于定位 selector 的名称字符串有效
    运行时 fixed-up 的方法列表取得的是 0b10
 
 II. 
    protocol->flags 最高的 2 位被用作 fixed-up 的标记
 预优化版本：
    来自 shared cache 的协议们是 1<<30 (因为在高位，所以左移 30 位，也就是说最高的 2 位是 0b01)
    运行时 fixed-up 的协议取得的是 1<<30 (最高的两位是 0b01)
 非预优化版本：
    来自 shared cache 的 Protocols 协议们是 1<<30 (最高的两位是 0b01)
    shared cache 的 fixups 是不可信的
    运行时 fixed-up 的协议们取得的是 3<<30 (最高的两位是 0b11)
 
*/

static uint32_t fixed_up_method_list = 3; // 3 就是 0b11，即两个标志位都是 1，就表示是 fixedup 的
static uint32_t fixed_up_protocol = PROTOCOL_FIXED_UP_1; // 最高的两位是 0b01

// 禁用了 shared cache 的优化
void
disableSharedCacheOptimizations(void)
{
    fixed_up_method_list = 2;   // fixed_up_method_list 变为 0b10，
                                // 这与上面的 Method lists 的非预优化版本在运行时取得的 fixed-up 值一致
    fixed_up_protocol = PROTOCOL_FIXED_UP_1 | PROTOCOL_FIXED_UP_2;
                                // fixed_up_protocol 变为最高位是 0b01|0b10 = 0b11
                                // 这与上面的 Protocols 的非预优化版本在运行时取得的 fixed-up 值一致
}

// 查看 method_list_t 是否是经过 FixedUp 的
bool method_list_t::isFixedUp() const {
    // 这个信息存在了 method_list_t 的 flag 里（method_list_t 继承自 entsize_list_tt）
    // 如果取出的 flag
    return flags() == fixed_up_method_list;
}

// 设置该 method_list_t 是 fixed-up 的
void method_list_t::setFixedUp() {
    runtimeLock.assertWriting(); // 看写锁是否已经被正确地加锁，因为后面需要修改值，所以需要加写锁
    assert(!isFixedUp()); // 如果这时它已经是 fixed-up 的话，那调用方就有问题
    // 改变 entsizeAndFlags 的值，新值是 entsize() | fixed_up_method_list
    // 也就是 entsize() | 0b11，将 entsizeAndFlags 的最低的两位设为 0b11，标记为已经被 FixedUp 了
    entsizeAndFlags = entsize() | fixed_up_method_list;
}

// 查看 protocol_t 协议是否是 fixed-up 的
bool protocol_t::isFixedUp() const {
    // flags & PROTOCOL_FIXED_UP_MASK 是取到标识 fixed-up 的位
    // 然后与 fixed_up_protocol 比较，fixed_up_protocol 是当前（预优化 or not）经过 fixed-up 的协议应该是什么样的值
    return (flags & PROTOCOL_FIXED_UP_MASK) == fixed_up_protocol;
}

// 设置协议是 fixed-up 的
void protocol_t::setFixedUp() {
    runtimeLock.assertWriting(); // 看写锁是否已经被正确加锁
    assert(!isFixedUp()); // 如果这时它已经是 fixed-up 的话，那调用方就有问题
    // 先将最高的两位清空，然后赋值为 fixed_up_protocol
    flags = (flags & ~PROTOCOL_FIXED_UP_MASK) | fixed_up_protocol;
}

// 取得 cls 类中分类方法列表的尾部，即 method_array_t 中最后一个分类方法列表
method_list_t **method_array_t::endCategoryMethodLists(Class cls) 
{
    method_list_t **mlists = beginLists();
    method_list_t **mlistsEnd = endLists();
    
    // 如果 lists 的头尾相同，或者 cls->data()->ro->baseMethods() 是空的，也就是 cls 没有 baseMethods
    // 就说明 cls 类的所有方法都是分类方法
    if (mlists == mlistsEnd  ||  !cls->data()->ro->baseMethods()) 
    {
        // No methods, or no base methods. 
        // Everything here is a category method.
        return mlistsEnd;
    }
    
    // Have base methods. Category methods are 
    // everything except the last method list.
    
    // 如果有 base methods，那么则除了最后一个方法列表，其他方法列表都是分类方法列表
    return mlistsEnd - 1;
}

// 取得 sel 的名字，因为 sel 本质上就是 char * 字符串，所以可以直接转换
static const char *sel_cname(SEL sel)
{
    return (const char *)(void *)sel;
}

// 取得一个 protocol_list_t 占用的内存大小
// #疑问：这个函数与 protocol_list_t 结构体中的 byteSize() 有什么分别呢
static size_t protocol_list_size(const protocol_list_t *plist)
{
    // protocol_list_t 只存了 protocol_ref_t list[0] 数组的首地址，
    // 所以其他的内存需要用 plist->count * sizeof(protocol_t *) 另外计算
    return sizeof(protocol_list_t) + plist->count * sizeof(protocol_t *);
}

// 尝试释放指针 p 指向的内存
static void try_free(const void *p) 
{
    if (p && malloc_size(p)) { // 如果 p 不是空，且 p 指向的内存的大小大于 0
        free((void *)p); // 就将那块内存释放
    }
}


// 内部函数，为类开辟内存空间，即为 objc_class 对象开辟内存空间
// 但是如果父类是 swift 类，就需要做特殊处理，因为子类需要继承父类的 extraBytes
// supercls : 父类，如果是 nil，就当作 oc 类处理
// extraBytes : 额外的字节，这些字节可以用来存储除了类中定义之外的，额外的实例变量
// 该函数被 objc_allocateClassPair() 和 objc_duplicateClass() 调用
static Class 
alloc_class_for_subclass(Class supercls, size_t extraBytes)
{
    if (!supercls  ||  !supercls->isSwift()) { // 如果没有父类 或者 父类不是 swift 类
        // 就直接调用 _calloc_class 开辟内存，总大小 = objc_class的大小 + 额外需要分配的大小
        return _calloc_class(sizeof(objc_class) + extraBytes);
    }

    // Superclass is a Swift class. New subclass must duplicate its extra bits.
    // 如果父类是一个 swift 类的话，子类必须复制父类的 extra bits

    // Allocate the new class, with space for super's prefix and suffix
    // and self's extraBytes.
    swift_class_t *swiftSupercls = (swift_class_t *)supercls; // 父类，swift_class_t 继承自 objc_class，
                                                              // 所以可以强制转换
    size_t superSize = swiftSupercls->classSize; // 父类的大小
    void *superBits = swiftSupercls->baseAddress(); // 父类数据的起始地址（前缀的起始地址？）
    void *bits = malloc(superSize + extraBytes); // 在堆中开辟 父类大小 + 自身 extraBytes 大小的内存空间
                                                 // 用来存放新类的数据

    // Copy all of the superclass's data to the new class.
    memcpy(bits, superBits, superSize); // 将父类数据（从 superBits 开始，大小为 superSize）复制到 bits 中

    // Erase the objc data and the Swift description in the new class.
    // 取得新类的地址，从 bits 开始，长度为 classAddressOffset 的部分是前缀，跳过前缀，才是原来的 objc_class 部分的
    swift_class_t *swcls = (swift_class_t *)
        ((uint8_t *)bits + swiftSupercls->classAddressOffset);
    bzero(swcls, sizeof(objc_class)); // 将 swcls 中 objc_class 部分都清零
    swcls->description = nil;

    // Mark this class as Swift-enhanced.
    swcls->bits.setIsSwift(); // 设置该类是 swift 类
    
    return (Class)swcls;
}


/***********************************************************************
* object_getIndexedIvars.
**********************************************************************/
// 当创建一个 Objective-C对象时，runtime会在实例变量存储区域后面再分配一点额外的空间，
// 用 object_getIndexedIvars 获取这块额外空间的起始地址，然后就可以索引实例变量（ivars）
void *object_getIndexedIvars(id obj)
{
    uint8_t *base = (uint8_t *)obj;

    if (!obj) {
        return nil;
    }
    if (obj->isTaggedPointer()) { // taggedPointer 本来就不是真正的类，所以不存在什么 extraBytes
        return nil;
    }

    if (!obj->isClass()) { // 如果不是类，就是单纯的实例，那么从 base 开始，向后偏移实例变量的大小，就是额外空间的大小
        return base + obj->ISA()->alignedInstanceSize();
    }

    Class cls = (Class)obj;
    if (!cls->isSwift()) { // 如果不是 swift 的类，那么 base 开始，向后偏移 objc_class 的大小，就是额外空间的大小
        return base + sizeof(objc_class);
    }
    
    // 如果是 swift 的类，那么就要复杂一点了，swift 类有前缀数据，所以向前偏移 swcls->classAddressOffset，
    // 是前缀的起始地址，从前缀起始地址开始向后偏移整个类的大小，就是额外空间的大小
    swift_class_t *swcls = (swift_class_t *)cls;
    return base - swcls->classAddressOffset + word_align(swcls->classSize);
}


/***********************************************************************
* make_ro_writeable
* Reallocates rw->ro if necessary to make it writeable.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
// 重新为 rw->ro 在堆中分配空间，使其可写（因为原来是编译的时候写在 DATA 数据区中的常量，是只读的）
/*
 比如下面这个 AXPerson 类的 ro，注意看其中的 section ("__DATA,__objc_const")
 
static struct _class_ro_t _OBJC_CLASS_RO_$_AXPerson __attribute__ ((used, section ("__DATA,__objc_const"))) = {
    0, __OFFSETOFIVAR__(struct AXPerson, _name), sizeof(struct AXPerson_IMPL),
    (unsigned int)0,
    0,
    "AXPerson",
    (const struct _method_list_t *)&_OBJC_$_INSTANCE_METHODS_AXPerson,
    0,
    (const struct _ivar_list_t *)&_OBJC_$_INSTANCE_VARIABLES_AXPerson,
    0,
    (const struct _prop_list_t *)&_OBJC_$_PROP_LIST_AXPerson,
};
 */
static class_ro_t *make_ro_writeable(class_rw_t *rw)
{
    runtimeLock.assertWriting(); // runtimeLock 需要被提前上好写锁，因为要操作 objc_class，所以为了保证线程安全，
                                 // 必须要上锁

    if (rw->flags & RW_COPIED_RO) { // 如果 class_rw_t->ro 是 class_ro_t 堆拷贝过来的
                                    // 那么 ro 就已经是可读可写的了，所以不用再做操作
        // already writeable, do nothing
    } else {
        class_ro_t *ro = (class_ro_t *)
            memdup(rw->ro, sizeof(*rw->ro)); // 否则，用 memdup 方法，在堆中分配内存，然后将原来的 rw->ro，拷贝到堆上
        rw->ro = ro; // rw->ro 指向新的堆上的 ro
        rw->flags |= RW_COPIED_RO; // 将 rw->ro，标记为堆拷贝的，下回就不需要再拷贝了
    }
    return (class_ro_t *)rw->ro; // 返回新的 ro
}


/***********************************************************************
* unattachedCategories
* Returns the class => categories map of unattached categories.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
// 取得一个存放没有被 attached 的分类们的数据结构
// 这个数据结构是一个静态变量，所以每次返回的都是同一个
// key : 类   value : 分类们
static NXMapTable *unattachedCategories(void)
{
    runtimeLock.assertWriting(); // runtimeLock 需要被上写锁

    static NXMapTable *category_map = nil; // 静态变量

    if (category_map) { // 如果有值，就直接返回
        return category_map;
    }

    // fixme initial map size
    // 否则，创建一个
    category_map = NXCreateMapTable(NXPtrValueMapPrototype, 16);

    return category_map;
}


/***********************************************************************
* addUnattachedCategoryForClass
* Records an unattached category.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
// 添加一个 unattached 的分类到 cls 类上，
// 即把这个分类添加到 cls 对应的所有 unattached 的分类的列表中，见 unattachedCategories()
// 调用者：_read_images()
static void addUnattachedCategoryForClass(category_t *cat, Class cls, header_info *catHeader)
{
    runtimeLock.assertWriting();

    // DO NOT use cat->cls! cls may be cat->cls->isa instead
    NXMapTable *cats = unattachedCategories(); // 取得存储所有没有被 attached 的分类的列表
    category_list *list;

    // 从所有 unattached 的分类列表中取得 cls 类对应的所有没有被 attach 的分类列表
    list = (category_list *)NXMapGet(cats, cls);
    if (!list) { // 如果 cls 没有未  attach 的分类
        // 就开辟出一个单位的空间，用来放新来的这个分类
        list = (category_list *)
            calloc(sizeof(*list) + sizeof(list->list[0]), 1);
    } else {
        // 否则开辟出比原来多一个单位的空间，用来放新来的这个分类，因为 realloc ，所以原来的数据会被拷贝过来
        list = (category_list *)
            realloc(list, sizeof(*list) + sizeof(list->list[0]) * (list->count + 1));
    }
    // 将新来的分类 cat 添加刚刚开辟的位置上
    list->list[list->count++] = (locstamped_category_t){cat, catHeader};
    // 将新的 list 重新插入 cats 中，会覆盖老的 list
    NXMapInsert(cats, cls, list);
}


/***********************************************************************
* removeUnattachedCategoryForClass
* Removes an unattached category.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
// 将分类 cat 从 cls 类的 unattached 分类列表中移除
static void removeUnattachedCategoryForClass(category_t *cat, Class cls)
{
    runtimeLock.assertWriting();

    // DO NOT use cat->cls! cls may be cat->cls->isa instead
    NXMapTable *cats = unattachedCategories(); // 取得存储所有没有被 attached 的分类的列表
    category_list *list;

    // 从所有 unattached 的分类列表中取得 cls 类对应的所有没有被 attach 的分类列表
    list = (category_list *)NXMapGet(cats, cls);
    if (!list) return; // 如果类列表不存在，就直接返回

    uint32_t i;
    for (i = 0; i < list->count; i++) { // 遍历列表，找到匹配的分类
        if (list->list[i].cat == cat) {
            // shift entries to preserve list order 保持列表的顺序
            
            // 原型：void * memmove( void* dest, const void* src, size_t count );
            // memmove 用于从 src 拷贝 count 个字节到 dest，如果目标区域和源区域有重叠的话，
            // memmove 能够保证源串在被覆盖之前将重叠区域的字节拷贝到目标区域中
            // 这里是将 list 中从 i+1 位置开始的所有元素向前挪一个单位，这样原来 i 处的分类就被覆盖了
            memmove(&list->list[i], &list->list[i+1], 
                    (list->count-i-1) * sizeof(list->list[i]));
            
            list->count--; // 列表的数目减 1
            return;
        }
    }
}


/***********************************************************************
* unattachedCategoriesForClass
* Returns the list of unattached categories for a class, and 
* deletes them from the list. 
* The result must be freed by the caller. 
* Locking: runtimeLock must be held by the caller.
 
 返回 cls 类的 unattached 分类列表，并且将其从 unattachedCategories 中删除
 调用者必须负责 unattached 分类列表 的释放
 第二个参数 realizing 压根儿没用
 调用者：methodizeClass() / remethodizeClass()
**********************************************************************/
static category_list *
unattachedCategoriesForClass(Class cls, bool realizing)
{
    runtimeLock.assertWriting(); // 必须事先加写锁
    return (category_list *)NXMapRemove(unattachedCategories(), cls);
}


/***********************************************************************
* removeAllUnattachedCategoriesForClass
* Deletes all unattached categories (loaded or not) for a class.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
// 移除 cls 的所有未 attach 的分类（无论是否 load）
// 调用者：detach_class()
static void removeAllUnattachedCategoriesForClass(Class cls)
{
    runtimeLock.assertWriting();

    // 将 category_map 中 cls 类对应的分类列表移除，并返回它
    void *list = NXMapRemove(unattachedCategories(), cls);
    if (list) free(list); // 如果存在这个列表，就将其释放了
}


/***********************************************************************
* classNSObject
* Returns class NSObject.
* Locking: none
**********************************************************************/
// 取得 NSObject 类
// 调用者：setInitialized() / updateCustomRR_AWZ()
static Class classNSObject(void)
{
    // NSObject 类本质上也是个 objc_class 对象，而且有且只有一个，名字就叫 OBJC_CLASS_$_NSObject
    // 它可能是编译器定的，不知道与 NSObject.h 中的 NSObject 有什么联系
    // 我猜 NSObject.h 应该是能被编译成类的，而不是摆着看看的吧
    extern objc_class OBJC_CLASS_$_NSObject;
    return (Class)&OBJC_CLASS_$_NSObject;
}


/***********************************************************************
* printReplacements
* Implementation of PrintReplacedMethods / OBJC_PRINT_REPLACED_METHODS.
* Warn about methods from cats that override other methods in cats or cls.
* Assumes no methods from cats have been added to cls yet.
**********************************************************************/
static void printReplacements(Class cls, category_list *cats)
{
    uint32_t c;
    bool isMeta = cls->isMetaClass();

    if (!cats) return;

    // Newest categories are LAST in cats
    // Later categories override earlier ones.
    for (c = 0; c < cats->count; c++) {
        category_t *cat = cats->list[c].cat;

        method_list_t *mlist = cat->methodsForMeta(isMeta);
        if (!mlist) continue;

        for (const auto& meth : *mlist) {
            SEL s = sel_registerName(sel_cname(meth.name));

            // Don't warn about GC-ignored selectors
            if (ignoreSelector(s)) continue;

            // Search for replaced methods in method lookup order.
            // Complain about the first duplicate only.

            // Look for method in earlier categories
            for (uint32_t c2 = 0; c2 < c; c2++) {
                category_t *cat2 = cats->list[c2].cat;

                const method_list_t *mlist2 = cat2->methodsForMeta(isMeta);
                if (!mlist2) continue;

                for (const auto& meth2 : *mlist2) {
                    SEL s2 = sel_registerName(sel_cname(meth2.name));
                    if (s == s2) {
                        logReplacedMethod(cls->nameForLogging(), s, 
                                          cls->isMetaClass(), cat->name, 
                                          meth2.imp, meth.imp);
                        goto complained;
                    }
                }
            }

            // Look for method in cls
            for (const auto& meth2 : cls->data()->methods) {
                SEL s2 = sel_registerName(sel_cname(meth2.name));
                if (s == s2) {
                    logReplacedMethod(cls->nameForLogging(), s, 
                                      cls->isMetaClass(), cat->name, 
                                      meth2.imp, meth.imp);
                    goto complained;
                }
            }

        complained:
            ;
        }
    }
}

// 查看类 cls 是否处于没有被 load 的 bundle 中
static bool isBundleClass(Class cls)
{
    return cls->data()->ro->flags & RO_FROM_BUNDLE;
}

// fixup 指定的方法列表
// bundleCopy : 是否从 bundle 中拷贝
// sort : 是否排序，排序是按照比较 method_t->name 进行的，SEL 字符串地址小的放前面
// 被 prepareMethodLists() 和 fixupProtocolMethodList() 函数调用
static void 
fixupMethodList(method_list_t *mlist, bool bundleCopy, bool sort)
{
    runtimeLock.assertWriting(); // 看 runtimeLock 是否已经被正确得上了写锁
    assert(!mlist->isFixedUp()); // 如果已经是 fixed-up 的了，那么调用方就有错

    // fixme lock less in attachMethodLists ?
    sel_lock(); // selLock 上写锁
    
    // Unique selectors in list.
    for (auto& meth : *mlist) { // 遍历 mlist
        const char *name = sel_cname(meth.name); // 取得方法的名字，就是 SEL，看 method_t 
        
        SEL sel = sel_registerNameNoLock(name, bundleCopy); // 注册名字，会对 SEL 做一些处理
        meth.name = sel; // 将新的名字赋值给 method_t
        
        if (ignoreSelector(sel)) { // 如果 SEL 需要被忽略，就将它的 IMP 设置为 _objc_ignored_method
            meth.imp = (IMP)&_objc_ignored_method;
        }
    }
    
    sel_unlock(); // selLock 释放写锁

    // Sort by selector address.
    if (sort) { // 如果需要排序
        // 实例化了一个排序器， SortBySELAddress 是 method_t 结构体中声明的结构体
        method_t::SortBySELAddress sorter;
        // 用排序器进行排序
        std::stable_sort(mlist->begin(), mlist->end(), sorter);
    }
    
    // Mark method list as uniqued and sorted
    mlist->setFixedUp(); // 设置 mlist 已经是 fixed-up 的了
}

// 准备 方法列表 的函数，参数是一组方法列表，主要工作是将方法列表 fixup 了，然后检查是否有自定义 AWZ/RR
// addedLists : 方法列表数组的首地址
// addedCount : 方法列表数组中元素的数量
// baseMethods : 是否是基本方法，就是 class_ro_t 中的 baseMethodList
// methodsFromBundle : 方法是否来自未加载的 bundle
// 该函数被 addMethod() / attachCategories() / methodizeClass() 函数调用
static void 
prepareMethodLists(Class cls, method_list_t **addedLists, int addedCount, 
                   bool baseMethods, bool methodsFromBundle)
{
    runtimeLock.assertWriting(); // 看下 runtimeLock 是否已经被正确得加了写锁

    if (addedCount == 0) return; // 如果方法列表数量为0，啥都不用干

    // Don't scan redundantly
    // 记录是否扫描自定义 RR/AWZ，如果没有 GC，且 cls 中原来没有自定义 RR/AWZ 才需要扫描 RR/AWZ
    bool scanForCustomRR  = !UseGC && !cls->hasCustomRR();
    bool scanForCustomAWZ = !UseGC && !cls->hasCustomAWZ();

    // There exist RR/AWZ special cases for some class's base methods. 
    // But this code should never need to scan base methods for RR/AWZ: 
    // default RR/AWZ cannot be set before setInitialized().
    // Therefore we need not handle any special cases here.
    
    // 或许有特殊情况，某些类的基本方法中存在自定义 RR
    // 但是该函数不用扫描基本方法的是否存在自定义 RR/AWZ
    // 在 setInitialized() 函数前不能设置默认的 RR/AWZ
    // 因此我们不需要处理这些特殊情况
    
    if (baseMethods) { // 如果是基本方法的话，就一定不能扫描自定义 RR/AWZ
        assert(!scanForCustomRR  &&  !scanForCustomAWZ);
    }

    // Add method lists to array.
    // Reallocate un-fixed method lists.
    // The new methods are PREPENDED to the method list array.

    // 遍历数组，将没有 fixup 的方法列表 fixup 了，并且可能扫描是否有自定义 RR/AWZ
    for (int i = 0; i < addedCount; i++) {
        method_list_t *mlist = addedLists[i];
        assert(mlist);

        // Fixup selectors if necessary
        if (!mlist->isFixedUp()) { // 如果方法列表没有被 fixed-up，就将它 fixup
            fixupMethodList(mlist, methodsFromBundle, true/*sort*/); // 指定必须排序
        }

        // Scan for method implementations tracked by the class's flags
        // 扫描方法列表中是否有自定义 RR
        if (scanForCustomRR  &&  methodListImplementsRR(mlist)) {
            cls->setHasCustomRR(); // 设置 cls 类有自定义 RR
            scanForCustomRR = false; // 找到一个自定义 RR 后，就不继续扫描自定义 RR 了，因为已经确定它有自定义 RR 了，再找也是白费
        }
        // 扫描方法列表中是否有自定义 AWZ
        if (scanForCustomAWZ  &&  methodListImplementsAWZ(mlist)) {
            cls->setHasCustomAWZ(); // 设置 cls 类有自定义 AWZ
            scanForCustomAWZ = false; // 找到一个自定义 AWZ 后，就不继续扫描自定义 AWZ 了
        }
    }
}


// Attach method lists and properties and protocols from categories to a class.
// Assumes the categories in cats are all loaded and sorted by load order, 
// oldest categories first.
// 从分类列表中添加方法列表、属性和协议到 cls 类中，
// 假定 cats 中的分类都已经被加载，并且按照加载的顺序排好序了，老的分类排前面，新的排后面
// cats : 分类列表，每个元素都是一个分类；
// flush_caches : 是否清空 cls 类的方法缓存，如果是 YES，会调用 flushCaches() 函数清空缓存
// 调用者：methodizeClass() / remethodizeClass()
static void 
attachCategories(Class cls, category_list *cats, bool flush_caches)
{
    if (!cats) return; // 如果列表是 nil，直接返回
    
    // 打印一些信息
    if (PrintReplacedMethods) {
        printReplacements(cls, cats);
    }

    bool isMeta = cls->isMetaClass(); // 记录 cls 类是否是元类

    // fixme rearrange to remove these intermediate allocations
    
    // 在堆中为方法列表数组、属性列表数组、协议列表数组分配足够大内存，注意，它们都是二维数组
    // 后面会将所有分类中的方法列表、属性列表、协议列表的首地址放到里面
    method_list_t **mlists = (method_list_t **)
        malloc(cats->count * sizeof(*mlists));
    property_list_t **proplists = (property_list_t **)
        malloc(cats->count * sizeof(*proplists));
    protocol_list_t **protolists = (protocol_list_t **)
        malloc(cats->count * sizeof(*protolists));

    // Count backwards through cats to get newest categories first
    int mcount = 0; // 记录方法的数量
    int propcount = 0; // 记录属性的数量
    int protocount = 0; // 记录协议的数量
    int i = cats->count; // 从后开始，保证先取最新的分类
    bool fromBundle = NO; // 记录是否是从 bundle 中取的
    while (i--) { // 从后往前遍历
        
        auto& entry = cats->list[i]; // 分类，locstamped_category_t 类型

        // 取出分类中的方法列表；如果是元类，取得的是类方法列表；否则取得的是实例方法列表
        method_list_t *mlist = entry.cat->methodsForMeta(isMeta);
        if (mlist) {
            mlists[mcount++] = mlist; // 将方法列表放入 mlists 方法列表数组中
            fromBundle |= entry.hi->isBundle(); // 分类的头部信息中存储了是否是 bundle，将其记住
        }

        // 取出分类中的属性列表，如果是元类，取得是nil
        property_list_t *proplist = entry.cat->propertiesForMeta(isMeta);
        if (proplist) {
            proplists[propcount++] = proplist; // 将属性列表放入 proplists 属性列表数组中
        }

        // 取出分类中遵循的协议列表
        protocol_list_t *protolist = entry.cat->protocols;
        if (protolist) {
            protolists[protocount++] = protolist; // 将协议列表放入 protolists 协议列表数组中
        }
    }

    auto rw = cls->data(); // 取出 cls 的 class_rw_t 数据

    // 准备 mlists 中的方法列表们
    prepareMethodLists(cls, mlists, mcount/*方法列表的数量*/, NO/*不是基本方法*/, fromBundle/*是否来自bundle*/);
    rw->methods.attachLists(mlists, mcount); // 将准备完毕的新方法列表们添加到 rw 中的方法列表数组中
    free(mlists); // 释放 mlists
    if (flush_caches  &&  mcount > 0) { // 如果需要清空方法缓存，并且刚才确实有方法列表添加进 rw 中，
                                        // 不然没有新方法加进来，就没有必要清空，清空是为了避免无法命中缓存的错误
                                        // 因为缓存位置是按照 hash 的方法确定的，详情见 cache_t::find() 函数
        flushCaches(cls); // 清空 cls 类 / cls 类的元类 / cls 类的子孙类 的方法缓存
    }

    rw->properties.attachLists(proplists, propcount); // 将新属性列表添加到 rw 中的属性列表数组中
    free(proplists); // 释放 proplists

    rw->protocols.attachLists(protolists, protocount); // 将新协议列表添加到 rw 中的协议列表数组中
    free(protolists); // 释放 protolists
}


/***********************************************************************
* methodizeClass
* Fixes up cls's method list, protocol list, and property list.
* Attaches any outstanding categories.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
// 1. fix-up cls 类的方法列表、协议列表、属性列表（但是看代码，被 fix-up 的只有方法列表啊）
//    将 cls 类的所有没有被 attach 的分类 attach 到 cls 上
// 2. 即将分类中的方法、属性、协议添加到 methods、 properties 和 protocols 中
//    runtimeLock 读写锁必须被调用者上写锁，保证线程安全
// 调用者：realizeClass()
// methodize 美 ['meθədaiz] vt. 使…有条理；为…定顺序
static void methodizeClass(Class cls)
{
    runtimeLock.assertWriting(); // 看调用者是否已经正确地将 runtimeLock 上了写锁

    bool isMeta = cls->isMetaClass(); // 记录 cls 类是否是元类
    auto rw = cls->data(); // 取得 cls 中的 rw，因为在 realizeClass() 中已经处理好了 cls->data()，
                           // 所以里面现在存的确定是 rw，而不是 ro
    auto ro = rw->ro; // 取得 rw->ro

    // Methodizing for the first time
    if (PrintConnecting) {
        _objc_inform("CLASS: methodizing class '%s' %s", 
                     cls->nameForLogging(), isMeta ? "(meta)" : "");
    }

    // Install methods and properties that the class implements itself.
    // 取得 ro 中的 baseMethodList，在将其 prepare 后，插入 rw 的方法列表数组中
    method_list_t *list = ro->baseMethods();
    if (list) {
        prepareMethodLists(cls, &list, 1, YES, isBundleClass(cls));
        rw->methods.attachLists(&list, 1);
    }

    // 将 ro 中的 baseProperties 插入 rw 中的属性列表数组中
    property_list_t *proplist = ro->baseProperties;
    if (proplist) {
        rw->properties.attachLists(&proplist, 1);
    }

    // 将 ro 中的 baseProtocols 插入 rw 中的协议列表数组中
    protocol_list_t *protolist = ro->baseProtocols;
    if (protolist) {
        rw->protocols.attachLists(&protolist, 1);
    }

    // Root classes get bonus method implementations if they don't have 
    // them already. These apply before category replacements.
    if (cls->isRootMetaclass()) { // 如果是根元类
        // root metaclass
        // 给根元类的 SEL_initialize 指定了对应的 IMP objc_noop_imp
        // 即给根元类发送 SEL_initialize 消息，不会走到它的 +initialize，而是走 objc_noop_imp，里面啥也不干
        addMethod(cls, SEL_initialize, (IMP)&objc_noop_imp, "", NO);
    }

    // Attach categories.
    // 给 cls 类附加分类，unattachedCategoriesForClass 会返回 cls 类的没有被附加的类
    category_list *cats = unattachedCategoriesForClass(cls, true /*realizing 其实这个参数压根没用*/);
    // 从分类列表中添加方法列表、属性和协议到 cls 类中
    // attachCategories 要求分类列表中是排好序的，老的分类排前面，新的排后面，那么排序是在哪里做的呢？？？？
    // 自问自答：见 addUnattachedCategoryForClass() 函数，新的 unattached 的分类本来就是插入到列表末尾的
    //         所以压根儿不用再另外排序
    attachCategories(cls, cats, false /*不清空缓存 因为这时候压根连缓存都没有 don't flush caches*/);

    if (PrintConnecting) {
        if (cats) {
            for (uint32_t i = 0; i < cats->count; i++) {
                _objc_inform("CLASS: attached category %c%s(%s)", 
                             isMeta ? '+' : '-', 
                             cls->nameForLogging(), cats->list[i].cat->name);
            }
        }
    }
    
    if (cats) {
        free(cats); // 将分类列表释放，见 unattachedCategoriesForClass，
                    // 里面着重强调了调用方需要负责释放分类列表
    }

#if DEBUG
    // Debug: sanity-check all SELs; log method list contents
    for (const auto& meth : rw->methods) {
        if (PrintConnecting) {
            _objc_inform("METHOD %c[%s %s]", isMeta ? '+' : '-', 
                         cls->nameForLogging(), sel_getName(meth.name));
        }
        assert(ignoreSelector(meth.name)  ||  
               sel_registerName(sel_getName(meth.name)) == meth.name); 
    }
#endif
}


/***********************************************************************
* remethodizeClass
* Attach outstanding categories to an existing class.
* Fixes up cls's method list, protocol list, and property list.（有没有 fixup 另说，但确实添加方法、协议、属性了）
* Updates method caches for cls and its subclasses.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
// 再次 methodize 类 cls，会重新 attachCategories 一次未被 attach 的分类们
// 而未被 attach 的分类是在 addUnattachedCategoryForClass() 中被添加的
// 该函数被 _read_images() 函数调用
static void remethodizeClass(Class cls)
{
    category_list *cats;
    bool isMeta;

    runtimeLock.assertWriting(); // 看 runtimeLock 是否已经被正确得加上了写锁

    isMeta = cls->isMetaClass();

    // Re-methodizing: check for more categories
    // 取得 cls 类的未被 attach 的分类列表
    if ((cats = unattachedCategoriesForClass(cls, false/*not realizing*/))) {
        
        if (PrintConnecting) {
            _objc_inform("CLASS: attaching categories to class '%s' %s", 
                         cls->nameForLogging(), isMeta ? "(meta)" : "");
        }
        // 将分类列表 attach 附加到 cls 类上，因为这不是第一次 methodize，所以需要清空缓存，因为原来的缓存也已经废了
        attachCategories(cls, cats, true /* 清空方法缓存 flush caches*/);
        free(cats); // 将 cats 释放，原因见 unattachedCategoriesForClass()
    }
}


/***********************************************************************
* nonMetaClasses
* Returns the secondary metaclass => class map
* Used for some cases of +initialize and +resolveClassMethod:.
* This map does not contain all class and metaclass pairs. It only 
* contains metaclasses whose classes would be in the runtime-allocated 
* named-class table, but are not because some other class with the same name 
* is in that table.
* Classes with no duplicates are not included.
* Classes in the preoptimized named-class table are not included.
* Classes whose duplicates are in the preoptimized table are not included.
* Most code should use getNonMetaClass() instead of reading this table.
* Locking: runtimeLock must be read- or write-locked by the caller
 
 nonMetaClasses 非元类的类，即传说中的 secondary table 二级映射表（一级是 gdb_objc_realized_classes）
 一些情况下被用于 +initialize 和 +resolveClassMethod:
 这个映射并不包括所有的类-元类对，它只包括一些元类，那些元类的实例类将会在 runtime-allocated named-class 表中（#疑问：这又是什么鬼），但并不是因为一些同名的其他类在那个表中
 不包括 no duplicates 没有副本的类（没有副本的类被存在了 gdb_objc_realized_classes 中）
 不包括不在 preoptimized named-class 表中的类
 不包括副本处于 preoptimized 表中的类
 绝大多数代码应该使用 getNonMetaClass() 代替直接读取这个表 (getNonMetaClass() 中确实调用了 nonMetaClasses())
 runtimeLock 必须被调用者事先上好读锁或者写锁
 该函数被 addNonMetaClass() / getNonMetaClass() / removeNonMetaClass() 函数调用
**********************************************************************/
static NXMapTable *nonmeta_class_map = nil; // 静态变量，存储 metacls - cls 映射的

static NXMapTable *nonMetaClasses(void)
{
    runtimeLock.assertLocked(); // 需要被调用方事先加锁

    if (nonmeta_class_map) return nonmeta_class_map; // 如果非空就直接返回

    // nonmeta_class_map is typically small
    // INIT_ONCE_PTR 会进行判断，如果空的话，就创建一个
    INIT_ONCE_PTR(nonmeta_class_map, 
                  NXCreateMapTable(NXPtrValueMapPrototype, 32), 
                  NXFreeMapTable(v));

    // 这个宏展开后是这个样子的：
    /*
    do {
        if (nonmeta_class_map) break; // 如果已经有值，就结束外层循环
        __typeof__(nonmeta_class_map) v = NXCreateMapTable(NXPtrValueMapPrototype, 32);
        while (!nonmeta_class_map) {
            // 查看二级指针 var 指向的值是否等于0，如果等于，就将 create 指向的值赋给 var，结束里层循环，否则继续尝试
            if (OSAtomicCompareAndSwapPtrBarrier(0, (void*)v, (void**)&nonmeta_class_map)){
                goto done_1;
            }
        }
        NXFreeMapTable(v); // #疑问：按照逻辑，里层循环会直接跳到 done，压根儿不可能走到这行
    done_1:; // done 里啥都没做
    } while (0);
    */
    
    return nonmeta_class_map;
}


/***********************************************************************
* addNonMetaClass
* Adds metacls => cls to the secondary metaclass map
* Locking: runtimeLock must be held by the caller
 
 添加一个 metacls -> cls 的映射到 secondary metaclass map(二级元类映射表)
 cls 类不能是元类，即一定是实例类，cls 的元类对应的实例类不能有旧值
 该函数只被 addNamedClass 函数调用
**********************************************************************/
static void addNonMetaClass(Class cls)
{
    runtimeLock.assertWriting(); // 需要事先加写锁
    
    void *old;
    old = NXMapInsert(nonMetaClasses(), cls->ISA(), cls);
                // 将 cls->ISA() 即 cls 的元类 与 cls 类插入 nonMetaClasses 表中
                // key : cls 的元类，value : cls 类

    assert(!cls->isMetaClass()); // cls 绝不能是元类
    assert(cls->ISA()->isMetaClass()); // cls 的 isa 必须是元类
    assert(!old); // cls 的元类对应实例类不能有旧值
}

// 从 nonMetaClasses（二级映射表）中移除指定的非元类
static void removeNonMetaClass(Class cls)
{
    runtimeLock.assertWriting(); // 需要事先加写锁
    NXMapRemove(nonMetaClasses(), cls->ISA()); // 移除。其中 key 是 cls 的元类
}


static bool scanMangledField(const char *&string, const char *end, 
                             const char *&field, int& length)
{
    // Leading zero not allowed.
    if (*string == '0') return false;

    length = 0;
    field = string;
    while (field < end) {
        char c = *field;
        if (!isdigit(c)) break;
        field++;
        if (__builtin_smul_overflow(length, 10, &length)) return false;
        if (__builtin_sadd_overflow(length, c - '0', &length)) return false;
    }

    string = field + length;
    return length > 0  &&  string <= end;
}


/***********************************************************************
* copySwiftV1DemangledName
* Returns the pretty form of the given Swift-v1-mangled class or protocol name. 
* Returns nil if the string doesn't look like a mangled Swift v1 name.
* The result must be freed with free().
**********************************************************************/
// 取得指定的 Swift-v1-mangled 的类或协议的 demangled name，
// 因为 swift 的类或协议的名字 会被重整为 swift 形式的名字，而现在，就是取得它们取消重整后的名字
// 如果指定的类或协议压根儿就不是 swift 的，就会返回 nil，
// 返回的结果字符串是堆上的，所以需要调用方释放
static char *copySwiftV1DemangledName(const char *string, bool isProtocol = false)
{
    if (!string) return nil;

    // Swift mangling prefix.
    if (strncmp(string, isProtocol ? "_TtP" : "_TtC", 4) != 0) return nil;
    string += 4;

    const char *end = string + strlen(string);

    // Module name.
    const char *prefix;
    int prefixLength;
    if (strncmp(string, "Ss", 2) == 0) {
        prefix = "Swift";
        prefixLength = 5;
        string += 2;
    } else {
        if (! scanMangledField(string, end, prefix, prefixLength)) return nil;
    }

    // Class or protocol name.
    const char *suffix;
    int suffixLength;
    if (! scanMangledField(string, end, suffix, suffixLength)) return nil;

    if (isProtocol) {
        // Remainder must be "_".
        if (strcmp(string, "_") != 0) return nil;
    } else {
        // Remainder must be empty.
        if (string != end) return nil;
    }

    char *result;
    asprintf(&result, "%.*s.%.*s", prefixLength,prefix, suffixLength,suffix);
    return result;
}


/***********************************************************************
* copySwiftV1MangledName
* Returns the Swift 1.0 mangled form of the given class or protocol name. 
* Returns nil if the string doesn't look like an unmangled Swift name.
* The result must be freed with free().
 
 将给定的类名或者协议名处理成 Swift 1.0 的 mangled name(重整名字) 的格式
 如果 string 与 unmangled(重整前) 的格式不符合，就返回 nil，
 结果是在堆中分配的，所以调用方需要负责 free 它
 调用者：getClass() / getProtocol()
**********************************************************************/
static char *copySwiftV1MangledName(const char *string, bool isProtocol = false)
{
    if (!string) return nil;

    size_t dotCount = 0;
    size_t dotIndex;
    const char *s;
    for (s = string; *s; s++) {
        if (*s == '.') {
            dotCount++;
            dotIndex = s - string;
        }
    }
    size_t stringLength = s - string;

    if (dotCount != 1  ||  dotIndex == 0  ||  dotIndex >= stringLength-1) {
        return nil;
    }
    
    const char *prefix = string;
    size_t prefixLength = dotIndex;
    const char *suffix = string + dotIndex + 1;
    size_t suffixLength = stringLength - (dotIndex + 1);
    
    char *name;

    if (prefixLength == 5  &&  memcmp(prefix, "Swift", 5) == 0) {
        asprintf(&name, "_Tt%cSs%zu%.*s%s", 
                 isProtocol ? 'P' : 'C', 
                 suffixLength, (int)suffixLength, suffix, 
                 isProtocol ? "_" : "");
    } else {
        asprintf(&name, "_Tt%c%zu%.*s%zu%.*s%s", 
                 isProtocol ? 'P' : 'C', 
                 prefixLength, (int)prefixLength, prefix, 
                 suffixLength, (int)suffixLength, suffix, 
                 isProtocol ? "_" : "");
    }
    return name;
}


/***********************************************************************
* getClass
* Looks up a class by name. The class MIGHT NOT be realized.
* Demangled Swift names are recognized.
* Locking: runtimeLock must be read- or write-locked by the caller.
**********************************************************************/

// This is a misnomer（用词不当、误称）: gdb_objc_realized_classes is actually a list of
// named classes not in the dyld shared cache, whether realized or not.

// 这是一个误称（知道是误称还不改？？）：gdb_objc_realized_classes 事实上是一个装了不在 dyld 的 shared cache 中的类的
// named classes 的列表，无论是否是 realized 的，见 _read_images()
// key: name  value: Class
// 我猜，这个应该就是相对于 nonmeta_class_map 的一级映射表吧，见 getNonMetaClass()
// 它是在 _read_images() 中被创建(初始化)的
NXMapTable *gdb_objc_realized_classes;  // exported for debuggers in objc-gdb.h

// 根据名字查找类，这个类可能没有被 realize 过
// 该函数被 getClass() 函数调用
static Class getClass_impl(const char *name)
{
    runtimeLock.assertLocked(); // 必须事先被加锁

    // allocated in _read_images 
    assert(gdb_objc_realized_classes); // gdb_objc_realized_classes 是在 _read_images() 函数中被初始化的(分配内存)

    // Try runtime-allocated table
    // 从 gdb_objc_realized_classes 根据 key 即 name 查找类
    Class result = (Class)NXMapGet(gdb_objc_realized_classes, name);
    if (result) {
        return result; // 找到了，就将其返回
    }

    // Try table from dyld shared cache
    // 如果在 gdb_objc_realized_classes 中找不到，就去预优化的类中找找看（跟 dyld shared cache 有关）
    return getPreoptimizedClass(name);
}

// 根据 name 查找类，实际上调用的还是 getClass_impl，但是需要对 swift 的类做一些处理
static Class getClass(const char *name)
{
    runtimeLock.assertLocked(); // 必须事先被加锁

    // Try name as-is
    Class result = getClass_impl(name); // 先直接用 name 查找
    if (result) {
        return result; // 找到直接返回
    }

    // 如果找不到，就处理成 swift 类的 mangled name 试试
    
    // Try Swift-mangled equivalent of the given name.
    if (char *swName = copySwiftV1MangledName(name)) { // 尝试转成 swift mangled name，函数里判断 name 是否符合
                                                       // swift unmangled name(重整前的名字) 的格式，如果符合就返回 mangled name，
                                                       // 否则返回 nil
        result = getClass_impl(swName); // 用 mangled name 再去找
        free(swName); // 将 swName 释放，原因见 copySwiftV1MangledName()
        return result; // 不用再判断 result 是否有值，直接将它返回
    }

    return nil; // 如果连 swift 类都不是，就返回 nil
}


/***********************************************************************
* addNamedClass
* Adds name => cls to the named non-meta class map.
* Warns about duplicate class names and keeps the old mapping.
* Locking: runtimeLock must be held by the caller
 
 添加 name -> cls 对到 named non-meta class map（gdb_objc_realized_classes）中
 警告有副本，但是会保持老的映射，即会有多份，
 新的映射被存在了 secondary metaclass map(二级元类映射表) 表中，见 addNonMetaClass()，
 replacing : 被代替的老的 cls (见 readClass()) 如果有旧映射，但是与 replacing 不符合，还是会保留旧映射，
             否则新值会将 gdb_objc_realized_classes 中的旧映射覆盖
 调用者：objc_duplicateClass() / objc_registerClassPair() / readClass()
**********************************************************************/
static void addNamedClass(Class cls, const char *name, Class replacing = nil)
{
    runtimeLock.assertWriting();
    
    Class old;
    // 先根据 name 查找是否有对应的旧类，如果有，并且 old 与 replacing 不同
    // 则报警告，但是会保持老的映射，插入新的映射
    if ((old = getClass(name))  &&  old != replacing) {
        
        inform_duplicate(name, old, cls); // 给出警告：名字为 name 的类有两份实现，但只有一份会被使用

        // getNonMetaClass uses name lookups. Classes not found by name 
        // lookup must be in the secondary meta->nonmeta table.
        addNonMetaClass(cls); // 将 cls 存入 matacls->cls 的二级映射表中
    } else {
        // 如果没有旧值，或者指定要覆盖旧值（replacing == old），就将新的 name->cls 对插入 gdb_objc_realized_classes
        NXMapInsert(gdb_objc_realized_classes, name, cls);
    }
    assert(!(cls->data()->flags & RO_META)); // cls 不能是元类

    // wrong: constructed classes are already realized when they get here
    // assert(!cls->isRealized());
}


/***********************************************************************
* removeNamedClass
* Removes cls from the name => cls map.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
// 移除 named class（#疑问：难道 named class 只是指这个类在表中存有 类名->类 的映射？）
static void removeNamedClass(Class cls, const char *name)
{
    runtimeLock.assertWriting();
    assert(!(cls->data()->flags & RO_META)); // cls 不能是元类
    if (cls == NXMapGet(gdb_objc_realized_classes, name)) { // 先看 gdb_objc_realized_classes 中有没有
        NXMapRemove(gdb_objc_realized_classes, name); // 有的话，将其移除
    } else {
        // cls has a name collision with another class - don't remove the other
        // but do remove cls from the secondary metaclass->class map.
        // cls 类和另一个类有名字冲突，不移除另一个类
        // 只将 cls 类从二级 metaclass->class 映射表中移除
        removeNonMetaClass(cls);
    }
}


/***********************************************************************
* realizedClasses
* Returns the class list for realized non-meta classes.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static NXHashTable *realized_class_hash = nil; // 记录所有经过 realized 的非元类
                                               // 它是在 _read_images() 中被创建(初始化)的

// 取得存有所有经过 realized 的非元类的哈希表
static NXHashTable *realizedClasses(void)
{
    runtimeLock.assertLocked(); // 检查是否已经加上锁

    // allocated in _read_images
    assert(realized_class_hash); // realized_class_hash 是在 _read_images() 中被分配内存的，所以这里只是检查是否
                                 // 确实已经被分配了内存

    return realized_class_hash;
}


/***********************************************************************
* realizedMetaclasses
* Returns the class list for realized metaclasses.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static NXHashTable *realized_metaclass_hash = nil; // 记录所有经过 realized 的元类
                                                // 它是在 _read_images() 中被创建(初始化)的

// 取得存有所有经过 realized 的元类的哈希表
// 该函数被 addRealizedMetaclass()/flushCaches()/removeRealizedMetaclass()函数调用
static NXHashTable *realizedMetaclasses(void)
{    
    runtimeLock.assertLocked();

    // allocated in _read_images
    assert(realized_metaclass_hash);

    return realized_metaclass_hash;
}


/***********************************************************************
* addRealizedClass
* Adds cls to the realized non-meta class hash.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
// 添加一个经过 realized 的非元类到 realized_class_hash 哈希表中，
// 还会顺便将其添加到已注册的类的哈希表中(objc-auto.mm 中的 AllClasses)，
// 但是不能有旧值，即 cls 类不能重复添加
// 该函数被 objc_duplicateClass()/objc_registerClassPair()/realizeClass() 函数调用
static void addRealizedClass(Class cls)
{
    runtimeLock.assertWriting();
    void *old;
    old = NXHashInsert(realizedClasses(), cls); // 将 cls 插入 realized_class_hash 哈希表中
    objc_addRegisteredClass(cls); // 将 cls 添加到已注册类的哈希表中(objc-auto.mm 中的 AllClasses)
    
    assert(!cls->isMetaClass()); // cls 不能是元类
    assert(!old); // 不能有旧值
}


/***********************************************************************
* removeRealizedClass
* Removes cls from the realized non-meta class hash.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
// 将 cls 类从 realized_class_hash 表中移除
// 还会顺便将 cls 从 已注册类的哈希表中移除(objc-auto.mm 中的 AllClasses)
// 该函数被 detach_class() 函数调用
static void removeRealizedClass(Class cls)
{
    runtimeLock.assertWriting();
    if (cls->isRealized()) { // 如果 cls 没有经过 realize，那么它是不会出现在 realized_class_hash 中的，所以也不用移除
        assert(!cls->isMetaClass()); // cls 不能是元类
        NXHashRemove(realizedClasses(), cls); // 将 cls 类从 realized_class_hash 表中移除
        objc_removeRegisteredClass(cls); // 顺便将 cls 从 已注册类的哈希表中移除(objc-auto.mm 中的 AllClasses)
    }
}


/***********************************************************************
* addRealizedMetaclass
* Adds cls to the realized metaclass hash.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
// 添加 cls 元类到 realized_metaclass_hash 哈希表中
// 不能有旧值，即不能重复添加
// 该函数被 objc_registerClassPair() 和 realizeClass() 函数调用
static void addRealizedMetaclass(Class cls)
{
    runtimeLock.assertWriting();
    void *old;
    old = NXHashInsert(realizedMetaclasses(), cls); // 将 cls 元类添加到 realized_metaclass_hash 哈希表中
    assert(cls->isMetaClass()); // cls 必须是元类
    assert(!old); // 不能有旧值
}


/***********************************************************************
* removeRealizedMetaclass
* Removes cls from the realized metaclass hash.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
// 将 cls 从 realized_metaclass_hash 哈希表中移除
// caller : detach_class()
static void removeRealizedMetaclass(Class cls)
{
    runtimeLock.assertWriting();
    if (cls->isRealized()) { // 如果 cls 没有经过 realize，那么它是不会
                             // 出现在 realized_metaclass_hash 中的，所以也不用移除
        assert(cls->isMetaClass()); // cls 必须是元类
        NXHashRemove(realizedMetaclasses(), cls); // 将 cls 从 realized_metaclass_hash 哈希表中移除
    }
}


/***********************************************************************
* futureNamedClasses
* Returns the classname => future class map for unrealized future classes.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static NXMapTable *future_named_class_map = nil; // 存有 classname -> future class 映射的映射表

// 取得 future_named_class_map 映射表
// callers : _objc_allocateFutureClass() / addFutureNamedClass()
static NXMapTable *futureNamedClasses()
{
    runtimeLock.assertWriting(); // 必须事先加写锁
    
    if (future_named_class_map) { // 如果非空，就直接返回
        return future_named_class_map;
    }

    // 否则创建一个
    // future_named_class_map is big enough for CF's classes and a few others
    future_named_class_map = 
        NXCreateMapTable(NXStrValueMapPrototype, 32);

    return future_named_class_map;
}


/***********************************************************************
* addFutureNamedClass
* Installs cls as the class structure to use for the named class if it appears.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
// 添加 future 的类 cls 到 future_named_class_map 映射表中
// caller : _objc_allocateFutureClass()
static void addFutureNamedClass(const char *name, Class cls)
{
    void *old;

    runtimeLock.assertWriting(); // 必须事先加写锁

    if (PrintFuture) {
        _objc_inform("FUTURE: reserving %p for %s", (void*)cls, name);
    }

    class_rw_t *rw = (class_rw_t *)calloc(sizeof(class_rw_t), 1); // 为 cls 开辟 rw
    class_ro_t *ro = (class_ro_t *)calloc(sizeof(class_ro_t), 1); // 为 cls 开辟 ro
    ro->name = strdup(name); // 在堆中拷贝 name 字符串
    rw->ro = ro;        // rw->ro 指向新 ro
    cls->setData(rw);   // 将 rw 放入 cls 中
    cls->data()->flags = RO_FUTURE;  // 将 cls 标记为是 future 的

    // 将 name->cls 映射插入 future_named_class_map 映射表中
    // NXMapKeyCopyingInsert 和 NXMapInsert 用处一样，但是会先在堆中复制 key（为了安全）
    old = NXMapKeyCopyingInsert(futureNamedClasses(), name, cls);
    
    assert(!old); // 不能有旧值
}


/***********************************************************************
* popFutureNamedClass
* Removes the named class from the unrealized future class list, 
* because it has been realized.
* Returns nil if the name is not used by a future class.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
// 将指定 name 对应的 future 类从 future_named_class_map 中移除
// 因为 这个类 已经被 realized 过了，它已经不再处于 future 状态
// 返回 name 对应的 future class，如果没有对应的 future class，就返回 nil
// caller : readClass()
static Class popFutureNamedClass(const char *name)
{
    runtimeLock.assertWriting();

    Class cls = nil;

    if (future_named_class_map) { // 如果 future_named_class_map 非空
        // 利用 key name 将 future class 从 future_named_class_map 移除
        // NXMapKeyFreeingRemove 与 NXMapRemove 功能一样，但是会释放 key，因为 key 是在堆中分配的，原因见 NXMapKeyCopyingInsert()
        cls = (Class)NXMapKeyFreeingRemove(future_named_class_map, name);
        
        // 如果 name 确实有对应的 future class，并且当前 future_named_class_map 已经空了
        // 就将 future_named_class_map 释放
        if (cls && NXCountMapTable(future_named_class_map) == 0) {
            NXFreeMapTable(future_named_class_map);
            future_named_class_map = nil; // 防止野指针
        }
    }

    return cls;
}


/***********************************************************************
* remappedClasses
* Returns the oldClass => newClass map for realized future classes.
* Returns the oldClass => nil map for ignored weak-linked classes.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
// 重映射的类
// 若是已经被 realized 的 future 的类，返回 oldClass -> newClass 的映射
// 若是 ignored weak-linked（被忽略的弱连接？）的类，就返回 oldClass -> nil 的映射
// create : 如果 remapped_class_map 为空的话，是否创建
// 调用者 ：addRemappedClass() / noClassesRemapped() / remapClass()
static NXMapTable *remappedClasses(bool create)
{
    // 存储 remapped 类的映射表，key : oldClass  value : newClass or nil
    static NXMapTable *remapped_class_map = nil;

    runtimeLock.assertLocked(); // runtimeLock 必须事先被加锁（写锁 or 读锁）

    if (remapped_class_map) return remapped_class_map; // 若不为空，直接返回
    
    if (!create) return nil; // 为空，但是指定不创建，则返回 nil

    // remapped_class_map is big enough to hold CF's classes and a few others
    
    // 有关 INIT_ONCE_PTR 可以看 nonMetaClasses()，里面也用到了 INIT_ONCE_PTR
    INIT_ONCE_PTR(remapped_class_map, 
                  NXCreateMapTable(NXPtrValueMapPrototype, 32), 
                  NXFreeMapTable(v));

    return remapped_class_map;
}


/***********************************************************************
* noClassesRemapped
* Returns YES if no classes have been remapped
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
// remapped_class_map 是否是空的
// 调用者：_read_images()
static bool noClassesRemapped(void)
{
    runtimeLock.assertLocked();

    // 如果 remapped_class_map == nil ，则它是空的，这默认了它非空的时候，一定有元素，这有利于优化速度
    bool result = (remappedClasses(NO) == nil);
#if DEBUG
    // Catch construction of an empty table, which defeats optimization.
    NXMapTable *map = remappedClasses(NO);
    if (map) assert(NXCountMapTable(map) > 0); // DEBUG 模式下，检查一下 map 非空的时候，元素数目是否真的一定 >0
#endif
    return result;
}


/***********************************************************************
* addRemappedClass
* newcls is a realized future class, replacing oldcls.
* OR newcls is nil, replacing ignored weak-linked class oldcls.
* Locking: runtimeLock must be write-locked by the caller
**********************************************************************/
// 添加一个 remapped 的类到 remapped_class_map 映射表中
// newcls 是一个已经被 realized 的 future 类，oldcls 是老的 future 类
// 或者 newcls 是 nil，oldcls 是 ignored weak-linked 类（被忽略的、弱链接的类 #疑问：什么意思？？）
// 调用者 ：readClass()
static void addRemappedClass(Class oldcls, Class newcls)
{
    runtimeLock.assertWriting(); // runtimeLock 必须事先被加上写锁

    if (PrintFuture) {
        _objc_inform("FUTURE: using %p instead of %p for %s", 
                     (void*)newcls, (void*)oldcls, oldcls->nameForLogging());
    }

    void *old;
    // 将 oldcls 为 key，newcls 为 value 插入到 remapped_class_map 映射表 中，
    // remappedClasses(YES) 中 YES 是指定如果 remapped_class_map 为空的话，就创建一个
    old = NXMapInsert(remappedClasses(YES), oldcls, newcls);
    
    assert(!old); // old 不能为空
}


/***********************************************************************
* remapClass
* Returns the live class pointer for cls, which may be pointing to 
* a class struct that has been reallocated.
* Returns nil if cls is ignored because of weak linking.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
// 返回 cls 类的 live class（活动的类）指针，这个指针可能指向一个已经被 reallocated 的结构体（#疑问：什么意思？？）
// 若 cls 是 weak linking（弱连接），则 cls 会被忽略，而返回 nil
// 调用者 ：_class_remap() / missingWeakSuperclass() / realizeClass() /
//         remapClass() / remapClassRef()
static Class remapClass(Class cls)
{
    runtimeLock.assertLocked();

    Class c2; // 这里没有初始化为 nil，有没有可能指向一块垃圾内存？？

    if (!cls) return nil; // 如果 cls 是 nil，则直接返回 nil

    NXMapTable *map = remappedClasses(NO); // 取得 remapped_class_map 映射表，若为空，不创建
    // 如果 map 非空，或者 cls 不是一个 key，NX_MAPNOTAKEY(not a key)，即 cls 压根儿不在 remapped_class_map 映射表里
    // 则将 cls 返回
    if (!map  ||  NXMapMember(map, cls, (void**)&c2) == NX_MAPNOTAKEY) {
        return cls;
    } else {
        return c2;  // 1. 如果 map 是空，则返回的 c2 == nil（#疑问：有没有可能是垃圾内存？？），因为 || 的断路特点，后面的代码不会执行
                    // 2. 如果 map 不为空，并且 cls 确实是 remapped_class_map 中的 key，则 c2 就是取得的 value
                    //      但是其中 key 如果是 ignored weak-linked class 的话，c2 就是 nil
    }
}

// 与上面的函数一样，只是参数类型是 classref_t
static Class remapClass(classref_t cls)
{
    return remapClass((Class)cls);
}

// 作用与上面一样，但是调用者比较特殊，所以在函数体里加了读锁
// 调用者 ：_objc_exception_do_catch()
Class _class_remap(Class cls)
{
    rwlock_reader_t lock(runtimeLock);
    return remapClass(cls);
}

/***********************************************************************
* remapClassRef
* Fix up a class ref, in case the class referenced has been reallocated 
* or is an ignored weak-linked class.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
// fix-up 一个类引用，万一这个类引用指向的类已经被 reallocated(重新分配？) 或者它是一个 ignored weak-linked 类
// 从重映射类表中用 *clsref 为 key 取出新类，如果 *clsref 不等于新类，则将新类赋给 *clsref
// clsref 是一个二级指针，它指向一个类的指针
// 调用者 ：_read_images()
static void remapClassRef(Class *clsref)
{
    runtimeLock.assertLocked();

    Class newcls = remapClass(*clsref); // 用 *clsref 为 key 从重映射类表中取出新类
    if (*clsref != newcls) { // 如果 *clsref 不等于新类，则将新类赋给 *clsref
        *clsref = newcls;
    }
}


/***********************************************************************
* getNonMetaClass
* Return the ordinary class for this class or metaclass. 
* `inst` is an instance of `cls` or a subclass thereof, or nil. 
* Non-nil inst is faster.
* Used by +initialize. 
* Locking: runtimeLock must be read- or write-locked by the caller
 
 返回这个元类的 ordinary class（也就是实例类）
 inst 是这个元类的实例 或者 这个元类的实例的子类，也可能是 nil
 inst 不是 nil 的话，会快一点
 这个方法被用在 +initialize 中（间接调用，其实是被 _class_getNonMetaClass 调用）
**********************************************************************/
// 取得 metacls 的 nonMetaClass，每个元类都有一个实例类
// http://7ni3rk.com1.z0.glb.clouddn.com/Runtime/class-diagram.jpg
// 如果不是元类，就直接返回它本身
// 如果它是元类，就找它的实例类
// 静态方法，内部使用，不让外部调用
// 调用者 ：_class_getNonMetaClass()
static Class getNonMetaClass(Class metacls, id inst)
{
    // 一些全局的变量
    static int total, named, secondary, sharedcache;
    
    // total 好像是记录直到现在，总共已经 Initialize 了几个类
    // named 是记录通过名字查找了几次
    
    // 判断 runtimeLock 有没有被正确地加锁
    runtimeLock.assertLocked();

    // realize 这个类
    realizeClass(metacls);

    // 总数 ++
    total++;

    // return cls itself if it's already a non-meta class
    // 如果它已经不是 meta class，就直接返回它本身
    if (!metacls->isMetaClass()) {
        return metacls;
    }

    // metacls really is a metaclass
    // 如果 metacls 已经是一个元类，就走下面的步骤
    
    // special case for root metaclass
    // where inst == inst->ISA() == metacls is possible
    // 特殊情况，如果 metacls 就是根元类，根元类的 isa->cls 是它自己
    if (metacls->ISA() == metacls) {
        
        Class cls = metacls->superclass; // 取得根元类的父类，根元类的父类是 NSObject 类
        
        assert(cls->isRealized());     // 如果 cls 到这里还没有 Realized，说明前面的步骤有错
        
        assert(!cls->isMetaClass());   // 如果 cls 是元类，说明有错，cls 是 NSObject，肯定不是元类
        
        assert(cls->ISA() == metacls); // 如果 cls 的 isa->cls 不是根元类，说明前面的步骤有错
        
        if (cls->ISA() == metacls) {   // 确认 cls 类 isa->cls 是 metacls，然后返回 cls，也就是 NSObject
            return cls;
        }
    }

    // use inst if available
    // 如果 inst 非空，就利用 inst 来查找，会快点
    if (inst) {
        // 直接将 inst 转为 Class 类型
        Class cls = (Class)inst;
        
        // realize cls
        realizeClass(cls); // 将 cls 类 realize 了
        
        // cls may be a subclass - find the real class for metacls
        // cls 可能是子类，向上一直找到 metacls 的 real class
        // 循环，直到 cls == nil , 或者 cls 的 isa->cls == metacls，
        // 也就是找到一个类，这个类的元类是 metacls
        while (cls  &&  cls->ISA() != metacls) {
            // 一直向上追溯
            cls = cls->superclass;
            // 将沿途的所有类都 realize
            realizeClass(cls);
        }
        // 如果找到了，说明 inst 确实我们需要找的那个类的子类
        if (cls) {
            assert(!cls->isMetaClass()); // 如果是元类，就报错，因为我们找的不是元类
            assert(cls->ISA() == metacls); // 确定 cls 的元类确实是 metacls
            return cls; // 将找到的 cls 返回
        }
#if DEBUG
        // 如果是 DEBUG 的话，直接挂掉，cls 压根儿就不是 metacls 的实例类
        _objc_fatal("cls is not an instance of metacls");
#else
        // release build: be forgiving and fall through to slow lookups
        // 如果 RELEASE 的话，原谅这个错误，然后下面继续用比较慢的办法查找
#endif
    }
  
    // try name lookup  试着通过名字查找
    {
        // 根据元类中的 mangledName 去 gdb_objc_realized_classes 中查找类
        Class cls = getClass(metacls->mangledName());
        if (cls->ISA() == metacls) { // 如果这个 cls 的元类确实是 metacls 就将其 realize 后返回
            named++; // 计数，看总数里有多少次是通过 name 查找，成功找到的
            if (PrintInitializing) {
                _objc_inform("INITIALIZE: %d/%d (%g%%) "
                             "successful by-name metaclass lookups",
                             named, total, named*100.0/total);
            }
            // 将 cls realize 了以后返回它
            realizeClass(cls);
            return cls;
        }
    }

    // try secondary table 通过 secondary table (二级映射表)查找，有关 secondary table 见 nonMetaClasses()
    {
        // 查找 nonmeta_class_map 看是否有 metacls 对应的实例类
        Class cls = (Class)NXMapGet(nonMetaClasses(), metacls);
        if (cls) {
            secondary++; // 计数，看总数里有多少次是通过 secondary table 成功找到的
            if (PrintInitializing) {
                _objc_inform("INITIALIZE: %d/%d (%g%%) "
                             "successful secondary metaclass lookups",
                             secondary, total, secondary*100.0/total);
            }
            // 再验证下 cls 的元类是否是 metacls
            assert(cls->ISA() == metacls);
            // 将 cls realize 了以后返回它
            realizeClass(cls);
            return cls;
        }
    }

    // try any duplicates in the dyld shared cache
    // 通过 dyld shared cache 查找所有副本
    {
        Class cls = nil;

        int count; // 作为输入参数
        // 通过 metacls->mangledName() 拷贝出所有对应的预优化的类
        Class *classes = copyPreoptimizedClasses(metacls->mangledName(),&count);
        // 如果 classes 数组确实有值
        if (classes) {
            // 遍历 classes 数组，查找是否有一个类的元类是 metacls
            for (int i = 0; i < count; i++) {
                if (classes[i]->ISA() == metacls) {
                    cls = classes[i];
                    break;
                }
            }
            // 无论是否找到，都必须将 classes 数组释放
            free(classes);
        }

        // 如果找到了
        if (cls) {
            sharedcache++; // 计数，看总数里有多少次是通过 dyld shared cache 成功找到的
            if (PrintInitializing) {
                _objc_inform("INITIALIZE: %d/%d (%g%%) "
                             "successful shared cache metaclass lookups",
                             sharedcache, total, sharedcache*100.0/total);
            }

            // 将 cls realize 了以后返回它
            realizeClass(cls);
            return cls;
        }
    }

    // 无论是否是 DEBUG 模式，到了这里，就说明发生了致命的错误
    // metacls 没有对应的实例类，就没法儿玩了
    _objc_fatal("no class for metaclass %p", (void*)metacls);
}


/***********************************************************************
* _class_getNonMetaClass
* Return the ordinary class for this class or metaclass. 
* Used by +initialize. 
* Locking: acquires runtimeLock
**********************************************************************/
// 取得 cls 类的实例类（就是非元类）
// 如果它已经不是 meta class，就直接返回它本身
// 如果它是 meta class，就找它的实例类
// obj 是这个元类的实例 或者 这个元类的实例的子类，也可能是 nil
// obj 不是 nil 的话，会快一点
// 调用者 ： _class_resolveClassMethod() / lookUpImpOrForward() /
//            lookUpImpOrForward() / storeWeak<>()
Class _class_getNonMetaClass(Class cls, id obj)
{
    rwlock_writer_t lock(runtimeLock); // 加读锁
    
    // 调用 getNonMetaClass 取得 cls 的实例类
    cls = getNonMetaClass(cls, obj);
    
    assert(cls->isRealized()); // cls 类必须是已经被 realized 的类
    
    return cls;
}


/***********************************************************************
* addSubclass
* Adds subcls as a subclass of supercls.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
// 给 supercls 类添加一个子类 subcls
// 调用者：objc_duplicateClass() / objc_initializeClassPair_internal() /
//         realizeClass() / setSuperclass()
static void addSubclass(Class supercls, Class subcls)
{
    runtimeLock.assertWriting(); // 需要事先加写锁

    if (supercls  &&  subcls) {
        assert(supercls->isRealized()); // 父类和子类都必须已经被 realized
        assert(subcls->isRealized());
        // 类的继承是多叉树的结构，所以先将 subcls 的 nextSiblingClass 指针指向 supercls 的 firstSubclass
        // 即 subcls 的兄弟类是 supercls 的第一个子类
        subcls->data()->nextSiblingClass = supercls->data()->firstSubclass;
        // 然后将 subcls 设为 supercls 的第一个子类
        supercls->data()->firstSubclass = subcls;

        /* 如下图
         
                 supercls
              /     |      \
            ↓/      |       \
        subcls -> subcls2 -> subcls3 -> nil    子类是一个链表
         
         */
        
        // 子类是否有 C++构造器、C++析构器、自定义 RR、自定义 AWZ 都是继承自父类，与父类保持一致
        
        if (supercls->hasCxxCtor()) {
            subcls->setHasCxxCtor();
        }

        if (supercls->hasCxxDtor()) {
            subcls->setHasCxxDtor();
        }

        if (supercls->hasCustomRR()) {
            subcls->setHasCustomRR(true);
        }

        if (supercls->hasCustomAWZ()) {
            subcls->setHasCustomAWZ(true);
        }

        if (supercls->requiresRawIsa()) {
            subcls->setRequiresRawIsa(true);
        }
    }
}


/***********************************************************************
* removeSubclass
* Removes subcls as a subclass of supercls.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
// 移除 supercls 的子类 subcls
// 调用者：detach_class() / setSuperclass()
static void removeSubclass(Class supercls, Class subcls)
{
    runtimeLock.assertWriting();
    assert(supercls->isRealized()); // 父类和子类必须是已经被 realized 的，这不是废话么，添加子类的时候已经检查过了呀
    assert(subcls->isRealized());
    assert(subcls->superclass == supercls); // subcls 必须确实是 supercls 的子类

    Class *cp;
    for (cp = &supercls->data()->firstSubclass; // cp 首先指向 supercls 的第一个子类，然后沿着子类的链表一路寻找，
                                                // 直到找到 subcls 类
         *cp  &&  *cp != subcls;
         cp = &(*cp)->data()->nextSiblingClass)
        ;
    assert(*cp == subcls);
    *cp = subcls->data()->nextSiblingClass; // 将 subcls 的下一个兄弟类赋给 *cp，即 下一个兄弟类代替了 subcls 的位置
                                            // subcls 在这里不能被销毁，因为其他地方还要用它，见 detach_class()
    
                                    // 如下图，就是单纯的链表移除节点的操作
                                    // A  ->  B  ->  C  ->  D  ->  nil
                                    //        |             ↑
                                    //        ---------------
}



/***********************************************************************
* protocols
* Returns the protocol name => protocol map for protocols.
* Locking: runtimeLock must read- or write-locked by the caller
**********************************************************************/
// 获得 协议名 -> 协议 的映射表
// 调用者：_read_images() / getProtocol() / objc_copyProtocolList() / objc_registerProtocol()
static NXMapTable *protocols(void)
{
    static NXMapTable *protocol_map = nil; // 存储 协议名 -> 协议 映射的数据结构
    
    runtimeLock.assertLocked();

    // 有关 INIT_ONCE_PTR 见 nonMetaClasses()，里面也用到了
    // INIT_ONCE_PTR 会进行判断，如果空的话，就创建一个
    INIT_ONCE_PTR(protocol_map, 
                  NXCreateMapTable(NXStrValueMapPrototype, 16), 
                  NXFreeMapTable(v) );

    return protocol_map;
}


/***********************************************************************
* getProtocol
* Looks up a protocol by name. Demangled Swift names are recognized.
* Locking: runtimeLock must be read- or write-locked by the caller.
**********************************************************************/
// 从 protocol_map 中根据协议名 name 查找对应的协议
// 调用者：objc_allocateProtocol() / objc_getProtocol() /
//           readProtocol() / remapProtocol()
static Protocol *getProtocol(const char *name)
{
    runtimeLock.assertLocked(); // 需要事先加锁

    // Try name as-is.
    // 先用直接用 name 查找
    Protocol *result = (Protocol *)NXMapGet(protocols(), name);
    if (result) return result;

    // Try Swift-mangled equivalent of the given name.
    // 如果 name 找不到，那么可能这是一个 swift 的协议，就将其重整为 swift 协议的格式
    // 如果不符合 swift 重整前名字的格式的话，copySwiftV1MangledName 会返回 nil
    if (char *swName = copySwiftV1MangledName(name, true/*isProtocol*/)) {
        result = (Protocol *)NXMapGet(protocols(), swName);  // 用 swName 再查找一次
        free(swName);  // 将 swName 释放，原因见 copySwiftV1MangledName()
        return result;
    }

    return nil;
}


/***********************************************************************
* remapProtocol
* Returns the live protocol pointer for proto, which may be pointing to 
* a protocol struct that has been reallocated.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
// 获得重映射的协议，protocol_ref_t 是未重映射的协议类型（其实和 protocol_t * 一样）
// 调用者：太多了，不写了
static protocol_t *remapProtocol(protocol_ref_t proto)
{
    runtimeLock.assertLocked();

    // 用 proto 协议 重整后的名字 查找对应的新协议
    protocol_t *newproto = (protocol_t *)
        getProtocol(((protocol_t *)proto)->mangledName);
    
    return newproto ? newproto : (protocol_t *)proto; // 如果存在新协议，就返回，否则依然返回 proto
}


/***********************************************************************
* remapProtocolRef
* Fix up a protocol ref, in case the protocol referenced has been reallocated.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static size_t UnfixedProtocolReferences; // 记录 unfixed 协议的数量

// fix-up 一个协议的引用（指向协议指针的二级指针），以防这个协议已经被 reallocated 了
// 调用者：_read_images()
static void remapProtocolRef(protocol_t **protoref)
{
    runtimeLock.assertLocked();

    // 调用 remapProtocol，获得 *protoref 协议 被重映射后的 新协议
    protocol_t *newproto = remapProtocol((protocol_ref_t)*protoref);
    if (*protoref != newproto) { // 如果 *protoref 与新协议不一致，就将新协议赋给 *protoref
        *protoref = newproto;
        UnfixedProtocolReferences++; // unfixed 的协议数量加 1
    }
}


/***********************************************************************
* moveIvars
* Slides a class's ivars to accommodate the given superclass size.
* Also slides ivar and weak GC layouts if provided.
* Ivars are NOT compacted to compensate for a superclass that shrunk.
* Locking: runtimeLock must be held by the caller.
 
 调整一个类的成员变量的偏移量 以适应父类的大小，有时父类插入了新的成员变量，子类的成员变量就需要动态地偏移，
 但是需要明确的是，它只改变了成员变量中记录的偏移量，即编译期写的偏移量有可能是错的，这里只重新记录了它在结构体中的位置，
 这样的好处是，偏移量不必在编译器中写死；
 #疑问：成员变量的真实位置会改变吗？？ivarBitmap 究竟是干嘛的，看字面意思，好像是改变了内存布局
 Also slides ivar and weak GC layouts if provided. #疑问：难以理解
 成员变量并不会因为父类的压缩而压缩自身的大小（难道意思是如果是父类减少成员变量，子类不必调整？）
 调用者：reconcileInstanceVariables()
**********************************************************************/
static void moveIvars(class_ro_t *ro, uint32_t superSize, /*父类的大小*/
                      layout_bitmap *ivarBitmap, layout_bitmap *weakBitmap)
{
    runtimeLock.assertWriting();

    uint32_t diff;

    assert(superSize > ro->instanceStart); // superSize 必须大于 ro 的起点，即 superclass 排前面
    diff = superSize - ro->instanceStart; // superclass 到 ro 起点的距离

    if (ro->ivars) { // 如果 ro 中有成员变量
        // Find maximum alignment in this class's ivars
        // 遍历所有成员变量，找到最大的 alignment
        uint32_t maxAlignment = 1;
        for (const auto& ivar : *ro->ivars) {
            if (!ivar.offset) continue;  // anonymous bitfield

            uint32_t alignment = ivar.alignment();
            if (alignment > maxAlignment) maxAlignment = alignment;
        }

        // Compute a slide value that preserves that alignment
        // 然后根据最大的 alignment 计算所需要 slide 的值
        uint32_t alignMask = maxAlignment - 1;
        if (diff & alignMask) diff = (diff + alignMask) & ~alignMask;

        // Slide all of this class's ivars en masse
        // 遍历所有成员变量，计算出每个成员变量新的偏移量
        for (const auto& ivar : *ro->ivars) {
            if (!ivar.offset) continue;  // anonymous bitfield #疑问：原来没有偏移量？什么意思？

            uint32_t oldOffset = (uint32_t)*ivar.offset; // 旧的偏移量
            uint32_t newOffset = oldOffset + diff; // slide 到新的偏移量位置
            *ivar.offset = newOffset;

            if (PrintIvars) {
                _objc_inform("IVARS:    offset %u -> %u for %s "
                             "(size %u, align %u)", 
                             oldOffset, newOffset, ivar.name, 
                             ivar.size, ivar.alignment());
            }
        }
        
        // #疑问：下面完全看不懂

        // Slide GC layouts
        uint32_t oldOffset = ro->instanceStart;
        uint32_t newOffset = ro->instanceStart + diff;

        if (ivarBitmap) {
            layout_bitmap_slide(ivarBitmap, 
                                oldOffset >> WORD_SHIFT, 
                                newOffset >> WORD_SHIFT);
        }
        if (weakBitmap) {
            layout_bitmap_slide(weakBitmap, 
                                oldOffset >> WORD_SHIFT, 
                                newOffset >> WORD_SHIFT);
        }
    }

    *(uint32_t *)&ro->instanceStart += diff;
    *(uint32_t *)&ro->instanceSize += diff;

    if (!ro->ivars) {
        // No ivars slid, but superclass changed size. 
        // Expand bitmap in preparation for layout_bitmap_splat().
        if (ivarBitmap) layout_bitmap_grow(ivarBitmap, ro->instanceSize >> WORD_SHIFT);
        if (weakBitmap) layout_bitmap_grow(weakBitmap, ro->instanceSize >> WORD_SHIFT);
    }
}


/***********************************************************************
* getIvar
* Look up an ivar by name.
* Locking: runtimeLock must be read- or write-locked by the caller.
**********************************************************************/
// 在 cls 类中查找 name 对应的成员变量（在 ro 中查找）
// 调用者 ：_class_getVariable() / class_addIvar()
static ivar_t *getIvar(Class cls, const char *name)
{
    runtimeLock.assertLocked();

    const ivar_list_t *ivars;
    
    assert(cls->isRealized()); // 类必须已经是已经 realized 的
    
    if ((ivars = cls->data()->ro->ivars)) { // 如果有成员变量
        for (auto& ivar : *ivars) { // 就遍历成员变量列表
            if (!ivar.offset) continue;  // anonymous bitfield

            // ivar.name may be nil for anonymous bitfields etc.
            if (ivar.name  &&  0 == strcmp(name, ivar.name)) { // 找到名字为 name 的成员变量，将其返回
                return &ivar;
            }
        }
    }

    return nil; // 找不到的话，返回 nil
}

// 调整 cls 类的成员变量
// #疑问：太难懂，以后再回来看
static void reconcileInstanceVariables(Class cls, Class supercls, const class_ro_t*& ro) 
{
    class_rw_t *rw = cls->data();

    assert(supercls);
    assert(!cls->isMetaClass());

    /* debug: print them all before sliding
    if (ro->ivars) {
        for (const auto& ivar : *ro->ivars) {
            if (!ivar.offset) continue;  // anonymous bitfield

            _objc_inform("IVARS: %s.%s (offset %u, size %u, align %u)", 
                         ro->name, ivar.name, 
                         *ivar.offset, ivar.size, ivar.alignment());
        }
    }
    */

    // Non-fragile ivars - reconcile this class with its superclass
    layout_bitmap ivarBitmap;
    layout_bitmap weakBitmap;
    bool layoutsChanged = NO;
    bool mergeLayouts = UseGC;
    const class_ro_t *super_ro = supercls->data()->ro;
    
    if (DebugNonFragileIvars) {
        // Debugging: Force non-fragile ivars to slide.
        // Intended to find compiler, runtime, and program bugs.
        // If it fails with this and works without, you have a problem.
        
        // Operation: Reset everything to 0 + misalignment. 
        // Then force the normal sliding logic to push everything back.
        
        // Exceptions: root classes, metaclasses, *NSCF* classes, 
        // __CF* classes, NSConstantString, NSSimpleCString
        
        // (already know it's not root because supercls != nil)
        const char *clsname = cls->mangledName();
        if (!strstr(clsname, "NSCF")  &&  
            0 != strncmp(clsname, "__CF", 4)  &&  
            0 != strcmp(clsname, "NSConstantString")  &&  
            0 != strcmp(clsname, "NSSimpleCString")) 
        {
            uint32_t oldStart = ro->instanceStart;
            uint32_t oldSize = ro->instanceSize;
            class_ro_t *ro_w = make_ro_writeable(rw);
            ro = rw->ro;
            
            // Find max ivar alignment in class.
            // default to word size to simplify ivar update
            uint32_t alignment = 1<<WORD_SHIFT;
            if (ro->ivars) {
                for (const auto& ivar : *ro->ivars) {
                    if (ivar.alignment() > alignment) {
                        alignment = ivar.alignment();
                    }
                }
            }
            uint32_t misalignment = ro->instanceStart % alignment;
            uint32_t delta = ro->instanceStart - misalignment;
            ro_w->instanceStart = misalignment;
            ro_w->instanceSize -= delta;
            
            if (PrintIvars) {
                _objc_inform("IVARS: DEBUG: forcing ivars for class '%s' "
                             "to slide (instanceStart %zu -> %zu)", 
                             cls->nameForLogging(), (size_t)oldStart, 
                             (size_t)ro->instanceStart);
            }
            
            if (ro->ivars) {
                for (const auto& ivar : *ro->ivars) {
                    if (!ivar.offset) continue;  // anonymous bitfield
                    *ivar.offset -= delta;
                }
            }
            
            if (mergeLayouts) {
                layout_bitmap layout;
                if (ro->ivarLayout) {
                    layout = layout_bitmap_create(ro->ivarLayout, 
                                                  oldSize, oldSize, NO);
                    layout_bitmap_slide_anywhere(&layout, 
                                                 delta >> WORD_SHIFT, 0);
                    ro_w->ivarLayout = layout_string_create(layout);
                    layout_bitmap_free(layout);
                }
                if (ro->weakIvarLayout) {
                    layout = layout_bitmap_create(ro->weakIvarLayout, 
                                                  oldSize, oldSize, YES);
                    layout_bitmap_slide_anywhere(&layout, 
                                                 delta >> WORD_SHIFT, 0);
                    ro_w->weakIvarLayout = layout_string_create(layout);
                    layout_bitmap_free(layout);
                }
            }
        }
    }

    if (ro->instanceStart >= super_ro->instanceSize  &&  !mergeLayouts) {
        // Superclass has not overgrown its space, and we don't 
        // need to rebuild GC layouts. We're done here.
        return;
    }
    // fixme can optimize for "class has no new ivars", etc

    if (mergeLayouts) {
        // WARNING: gcc c++ sets instanceStart/Size=0 for classes with  
        //   no local ivars, but does provide a layout bitmap. 
        //   Handle that case specially so layout_bitmap_create doesn't die
        //   The other ivar sliding code below still works fine, and 
        //   the final result is a good class.
        if (ro->instanceStart == 0  &&  ro->instanceSize == 0) {
            // We can't use ro->ivarLayout because we don't know
            // how long it is. Force a new layout to be created.
            if (PrintIvars) {
                _objc_inform("IVARS: instanceStart/Size==0 for class %s; "
                             "disregarding ivar layout", cls->nameForLogging());
            }
            ivarBitmap = layout_bitmap_create_empty(super_ro->instanceSize, NO);
            weakBitmap = layout_bitmap_create_empty(super_ro->instanceSize, YES);
            layoutsChanged = YES;
        } 
        else {
            ivarBitmap = 
                layout_bitmap_create(ro->ivarLayout, 
                                     ro->instanceSize, 
                                     ro->instanceSize, NO);
            weakBitmap = 
                layout_bitmap_create(ro->weakIvarLayout, 
                                     ro->instanceSize,
                                     ro->instanceSize, YES);
        }
    }
    
    // 当子类的 instanceStart 小于父类的 instanceSize 时,说明需要调整
    if (ro->instanceStart < super_ro->instanceSize) {
        // Superclass has changed size. This class's ivars must move.
        // Also slide layout bits in parallel.
        // This code is incapable of compacting the subclass to 
        //   compensate for a superclass that shrunk, so don't do that.
        
        // 父类的大小改变了，该类的成员变量必须移动，layout bits 也需要移动
        // 这段代码在父类压缩的时候，并不会压缩子类的大小
        
        if (PrintIvars) {
            _objc_inform("IVARS: sliding ivars for class %s "
                         "(superclass was %u bytes, now %u)", 
                         cls->nameForLogging(), ro->instanceStart, 
                         super_ro->instanceSize);
        }
        
        // 重新为 rw->ro 在堆中分配空间，使其可写
        class_ro_t *ro_w = make_ro_writeable(rw);
        ro = rw->ro;
        
        // 重新计算成员变量的偏移量
        moveIvars(ro_w, super_ro->instanceSize, 
                  mergeLayouts ? &ivarBitmap : nil, 
                  mergeLayouts ? &weakBitmap : nil);
        gdb_objc_class_changed(cls, OBJC_CLASS_IVARS_CHANGED, ro->name);
        layoutsChanged = YES;
    } 
    
    if (mergeLayouts) {
        // Check superclass's layout against this class's layout.
        // This needs to be done even if the superclass is not bigger.
        layout_bitmap superBitmap;
        
        superBitmap = layout_bitmap_create(super_ro->ivarLayout, 
                                           super_ro->instanceSize, 
                                           super_ro->instanceSize, NO);
        layoutsChanged |= layout_bitmap_splat(ivarBitmap, superBitmap, 
                                              ro->instanceStart);
        layout_bitmap_free(superBitmap);
        
        // check the superclass' weak layout.
        superBitmap = layout_bitmap_create(super_ro->weakIvarLayout, 
                                           super_ro->instanceSize, 
                                           super_ro->instanceSize, YES);
        layoutsChanged |= layout_bitmap_splat(weakBitmap, superBitmap, 
                                              ro->instanceStart);
        layout_bitmap_free(superBitmap);
        
        // Rebuild layout strings if necessary.
        if (layoutsChanged) {
            if (PrintIvars) {
                _objc_inform("IVARS: gc layout changed for class %s", 
                             cls->nameForLogging());
            }
            class_ro_t *ro_w = make_ro_writeable(rw);
            ro = rw->ro;
            if (DebugNonFragileIvars) {
                try_free(ro_w->ivarLayout);
                try_free(ro_w->weakIvarLayout);
            }
            ro_w->ivarLayout = layout_string_create(ivarBitmap);
            ro_w->weakIvarLayout = layout_string_create(weakBitmap);
        }
        
        layout_bitmap_free(ivarBitmap);
        layout_bitmap_free(weakBitmap);
    }
}


/***********************************************************************
* realizeClass
* Performs first-time initialization on class cls, 
* including allocating its read-write data.
* Returns the real class structure for the class. 
* Locking: runtimeLock must be write-locked by the caller
 
 realize 指定的 cls 类，
 包括开辟它的 read-write data，也就是 rw，见 class_rw_t 结构体，
 返回类的 real class structure，可能意思是 cls 在这个函数中被填充所有必要的信息，
 从编译期的只有 RO，变成一个真正的可以用的类，
 函数中会将它的父类和元类也 realize 了，
 当然这会造成递归，会把 cls 往上所有没 realize 的祖宗类和 cls 的元类往上所有没有被 realize 的元类都 realize 了
 这个函数还会调用 methodizeClass 函数将分类中的方法列表、属性列表、协议列表加载到 methods、 properties 和 protocols 列表数组中
 
 调用本函数的函数有：
    _read_images()
    getNonMetaClass()
    look_up_class()
    lookUpImpOrForward()
    objc_class::demangledName()
    objc_readClassPair()
    prepare_load_methods()
    realizeAllClassesInImage()
**********************************************************************/
// realize 指定的 class
static Class realizeClass(Class cls)
{
    runtimeLock.assertWriting(); // 看 runtimeLock 是否正确得加了写锁

    const class_ro_t *ro;
    class_rw_t *rw;
    Class supercls;
    Class metacls;
    bool isMeta;

    if (!cls) return nil;
    
    // 如果类已经被 realize 过，就不用 realize 了
    if (cls->isRealized()) {
        return cls;
    }
    
    assert(cls == remapClass(cls)); // remapClass(cls) 得到的是 cls 对应的重映射类，
                                    // 如果 cls 不存在于 remapped_class_map 映射表，得到的才是 cls 本身，
                                    // 所以这里断言 cls == remapClass(cls) 就是看 cls 是否存在于 remapped_class_map 映射表
                                    // 不存在，就是正确；存在，就是错误
                                    // 不存在，则 cls 既不是 realized future class，也不是 ignored weak-linked class
                                    // 见 remappedClasses()

    // fixme verify class is not in an un-dlopened part of the shared cache?

//    从 class_data_bits_t 调用 data 方法，将结果从 class_rw_t 强制转换为 class_ro_t 指针
//    初始化一个 class_rw_t 结构体
//    设置结构体中 ro 的值以及 flag
//    最后设置正确的 data。
    
    ro = (const class_ro_t *)cls->data(); // 因为在 realized 之前，objc_class 中的 class_data_bits_t bits 里
                                          // 本质上存的是 class_ro_t，所以这里只需要转成 class_ro_t 类型就可以了
                                          // 但 future 的类是例外!!!
    if (ro->flags & RO_FUTURE) {
        // 如果 ro 的 flag 里记录了这是一个 future 的类，那么 objc_class 中的 class_data_bits_t bits 里存的是 class_rw_t
        // rw 数据已经被分配好内存了
        // This was a future class. rw data is already allocated.
        rw = cls->data();  // 取出 rw
        ro = cls->data()->ro; // 取出 ro
        cls->changeInfo(RW_REALIZED|RW_REALIZING, RW_FUTURE); // 清除 future 状态，RW_FUTURE 位的值置为 0
                                                              // 设置为 realized + realizing 状态
    } else {                                                  // RW_REALIZED 和 RW_REALIZING 位的值置为 1
        // Normal class. Allocate writeable class data.
        // 正常的类的话，就需要开辟内存
        rw = (class_rw_t *)calloc(sizeof(class_rw_t), 1);
        rw->ro = ro; // 将原来的 ro 赋给新 rw 中的 ro 字段
        rw->flags = RW_REALIZED|RW_REALIZING; // 设置为 realized + realizing 状态
        cls->setData(rw); // 将新的 rw 替换老的 rw
    }

    isMeta = ro->flags & RO_META; // cls 类是否是元类

    rw->version = isMeta ? 7 : 0;  // old runtime went up to 6
                            // 版本，元类是 7，普通类是 0

    if (PrintConnecting) {
        _objc_inform("CLASS: realizing class '%s' %s %p %p", 
                     cls->nameForLogging(), isMeta ? "(meta)" : "", 
                     (void*)cls, ro);
    }

    // Realize superclass and metaclass, if they aren't already.
    // This needs to be done after RW_REALIZED is set above, for root classes.
    
    // remapClass() 函数是如果参数是一个已经 realized 的 future 类，则返回的是新类，否则返回的是自己
    // 查看 cls 的父类对应的重映射的类，将其 realize 了
    supercls = realizeClass(remapClass(cls->superclass));
    // 查看 cls 的元类对应的重映射的类，将其 realize 了
    metacls = realizeClass(remapClass(cls->ISA()));

    // Update superclass and metaclass in case of remapping
    cls->superclass = supercls; // 更新 cls 的父类
    cls->initClassIsa(metacls); // 和元类

    // Reconcile instance variable offsets / layout.
    // This may reallocate class_ro_t, updating our ro variable.
    if (supercls  &&  !isMeta) { // 根据父类，调整 cls 类 ro 中实例变量的偏移量和布局
                                 // 可能重新分配 class_ro_t，更新 ro
        reconcileInstanceVariables(cls, supercls, ro);
    }

    // Set fastInstanceSize if it wasn't set already.
    cls->setInstanceSize(ro->instanceSize); // 设置成员变量的新的大小

    // Copy some flags from ro to rw
    // 从 ro 拷贝一些 flag 到 rw 中，可能是为了加快查找速度
    if (ro->flags & RO_HAS_CXX_STRUCTORS) { // 是否有 C++ 构造器/析构器
        cls->setHasCxxDtor(); // 设置有 C++ 析构器
        if (! (ro->flags & RO_HAS_CXX_DTOR_ONLY)) { // 不只有 C++ 析构器，那么就是也有 C++ 构造器，真绕啊
            cls->setHasCxxCtor();
        }
    }

    // Disable non-pointer isa for some classes and/or platforms.
#if SUPPORT_NONPOINTER_ISA  // 如果当前是支持 non-pointer isa 的，就根据环境变量看是否需要禁止 non-pointer isa，
                            // 而是将类和所有子类都设为必须使用 raw isa
    {
        bool disable = false;
        static bool hackedDispatch = false;
        
        if (DisableIndexedIsa) {
            // Non-pointer isa disabled by environment or GC or app SDK version
            disable = true;
        }
        else if (!hackedDispatch  &&  !(ro->flags & RO_META)  &&  
                 0 == strcmp(ro->name, "OS_object")) 
        {
            // hack for libdispatch et al - isa also acts as vtable pointer
            hackedDispatch = true;
            disable = true;
        }
        
        if (disable) {
            cls->setRequiresRawIsa(false/*inherited*/);
        }
    }
#endif

    // Connect this class to its superclass's subclass lists
    if (supercls) {
        addSubclass(supercls, cls);
    }

    // 调用 methodizeClass 函数来将分类中的方法列表、属性列表、协议列表加载到 methods、 properties 和 protocols 列表数组中
    // Attach categories
    methodizeClass(cls);

    if (!isMeta) { // 如果不是元类
        addRealizedClass(cls); // 就把它添加到 realized_class_hash 哈希表中
    } else {
        addRealizedMetaclass(cls); // 否则是元类，就把它添加到 realized_metaclass_hash 哈希表中
    }

    return cls;
}


/***********************************************************************
* missingWeakSuperclass
* Return YES if some superclass of cls was weak-linked and is missing.
**********************************************************************/
// 判断 cls 类的祖宗类中是否有类是 weak-linked 的，并且已经 missing(丢失？？)
// 这是一个递归函数
// 调用者：readClass()
static bool 
missingWeakSuperclass(Class cls)
{
    assert(!cls->isRealized()); // cls 不能是已经 realized 的类，因为 realized 的类一定是正常的

    if (!cls->superclass) { // 如果没有父类，则看它是否是根类，若是根类，那么就是正常的，否则它的父类就是丢了 = =
                            // 结束递归
        // superclass nil. This is normal for root classes only.
        return (!(cls->data()->flags & RO_ROOT));
    } else {
        // superclass not nil. Check if a higher superclass is missing.
        // 如果有父类，则递归调用一直向上查找祖宗类，看是否有丢的了
        Class supercls = remapClass(cls->superclass); // 取得重映射的父类，如果父类是 weak-link 的，
                                                      // 则 remapClass 会返回 nil
        assert(cls != cls->superclass); // 这两个断言很奇怪，完全想不到什么奇葩情况下这两个断言会不成立
        assert(cls != supercls);
        if (!supercls) return YES; // 如果父类是 weak-link 的，则 supercls 为 nil，返回 YES，结束递归
        if (supercls->isRealized()) return NO; // 如果父类已经被 realized，则直接返回 NO，因为 realized 的类一定是正常的
                                               // 结束递归
        return missingWeakSuperclass(supercls); // 否则递归寻找祖宗类们
    }
}


/***********************************************************************
* realizeAllClassesInImage
* Non-lazily realizes all unrealized classes in the given image.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
// 以非惰性的方式 realize 给定镜像中所有未被 realize 的类
// 调用者：realizeAllClasses()
static void realizeAllClassesInImage(header_info *hi)
{
    runtimeLock.assertWriting();

    size_t count, i;
    classref_t *classlist;

    if (hi->allClassesRealized) return; // 如果 hi 中已经标记了 所有的类已经全被 realized 了，就直接返回

    classlist = _getObjc2ClassList(hi, &count); // 获得 hi 中的所有 objective-2.0 的类，count 是类的数量

    // 遍历所有类，将每个类对应的重映射类都 realize 了
    for (i = 0; i < count; i++) {
        realizeClass(remapClass(classlist[i]));
    }

    hi->allClassesRealized = YES; // 标记该镜像中所有的类已经全被 realized 了
}


/***********************************************************************
* realizeAllClasses
* Non-lazily realizes all unrealized classes in all known images.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
// 以非惰性的方式 realize 所有已知镜像中的所有未被 realize 的类
// 调用者：_read_images() / objc_copyClassList() / objc_getClassList()
static void realizeAllClasses(void)
{
    runtimeLock.assertWriting();

    header_info *hi;
    // 遍历所有镜像，将每个镜像中的所有类都 realize 了
    for (hi = FirstHeader; hi; hi = hi->next) {
        realizeAllClassesInImage(hi);
    }
}


/***********************************************************************
* _objc_allocateFutureClass
* Allocate an unresolved future class for the given class name.
* Returns any existing allocation if one was already made.
* Assumes the named class doesn't exist yet.
* Locking: acquires runtimeLock
**********************************************************************/
// 为名字为 name 的 future class 分配内存，存进 future_named_class_map 映射表里，并返回这个 class
// 如果它已经在映射表里，那么已经分配过内存了，就直接返回
// 调用者：objc_getFutureClass()
Class _objc_allocateFutureClass(const char *name)
{
    rwlock_writer_t lock(runtimeLock); // 加写锁

    Class cls;
    NXMapTable *map = futureNamedClasses(); // 取得 future_named_class_map 映射表

    if ((cls = (Class)NXMapGet(map, name))) { // 从映射表中寻找 name 对应的 future 类
        // Already have a future class for this name.
        return cls; // 如果在映射表中找到了，就将其返回
    }

    cls = _calloc_class(sizeof(objc_class)); // 如果映射表中找不到，就在堆中分配一块内存，用来放 name 对应的 future 类
                                             // 这时这块内存里还都是 0，类中 rw/ro 的内存分配是在 addFutureNamedClass 中做的
    addFutureNamedClass(name, cls); // 添加 cls 类到 future_named_class_map 映射表中
                                    // 里面还会为 cls 中的 rw/ro 分配内存

    return cls;
}


/***********************************************************************
* objc_getFutureClass.  Return the id of the named class.
* If the class does not exist, return an uninitialized class 
* structure that will be used for the class when and if it 
* does get loaded.
* Not thread safe. 
 
 // 返回 name 对应的 future class，或者一个没有被初始化过的 class，见 _objc_allocateFutureClass()，确实没有初始化
 // 用于 CoreFoundation 的桥接
 // 千万不要自己调用这个函数
 // 不是线程安全的，因为没加锁
 // objc4库中没有地方调用过这个函数
**********************************************************************/
Class objc_getFutureClass(const char *name)
{
    Class cls;

    // YES unconnected, NO class handler
    // (unconnected is OK because it will someday be the real class)
    cls = look_up_class(name, YES, NO); // 根据 name 查找类，后两个参数压根儿没使用，不要纠结
    if (cls) {
        if (PrintFuture) {
            _objc_inform("FUTURE: found %p already in use for %s", 
                         (void*)cls, name);
        }

        return cls;
    }
    
    // No class or future class with that name yet. Make one.
    // fixme not thread-safe with respect to 
    // simultaneous library load or getFutureClass.
    
    // name 没有对应的 future class，那我们自己创建一个吧
    return _objc_allocateFutureClass(name);
}

// 判断 cls 类是否是一个 future class
BOOL _class_isFutureClass(Class cls)
{
    return cls  &&  cls->isFuture();
}


/***********************************************************************
* _objc_flush_caches
* Flushes all caches.
* (Historical behavior: flush caches for cls, its metaclass, 
* and subclasses thereof. Nil flushes all classes.)
* Locking: acquires runtimeLock
 
 清空所有缓存
 清空 cls 类 / cls 类的元类 / cls 类的子孙类 的方法缓存
 如果 cls 是 nil，就将所有类的缓存都清空 ！！！！
 调用者：_method_setImplementation() / _objc_flush_caches() / addMethod() /
          attachCategories() / method_exchangeImplementations() / setSuperclass()
**********************************************************************/
static void flushCaches(Class cls)
{
    runtimeLock.assertWriting(); // 看看 runtimeLock 是否正确得被加上写锁

    mutex_locker_t lock(cacheUpdateLock); // cacheUpdateLock 互斥锁加锁

    if (cls) { // 如果指定了需要清空方法缓存的 类
        
        // 深度遍历 cls 类及其所有子孙类，子类们被记录在 class_rw_t 中
        foreach_realized_class_and_subclass(cls, ^(Class c){
            // 将遍历的类的方法缓存清空
            cache_erase_nolock(c);
        });
        
        // 下面开始清空元类的方法缓存

        if (!cls->superclass) { // 如果没有父类，那么就是根类，因为只有根类没有父类，
                                // 很重要的一点是：元类们的祖宗也是根类；所以他们会在上面被遍历到
                                // 如果理解不了，就看配图中的 class-diagram.jpg
            // root; metaclasses are subclasses and were flushed above
        } else {
            // 如果 cls 不是根类，就深度遍历 cls 类的元类，以及元类的子孙类
            // 因为元类的父类还是元类（除了根元类），所以上面的遍历不会涉及到元类，因此这里需要额外再遍历一次元类
            foreach_realized_class_and_subclass(cls->ISA(), ^(Class c){
                // 将遍历到的元类的方法缓存清空
                cache_erase_nolock(c);
            });
        }
    }
    // 如果传进来的 cls 是 nil，就将所有类的缓存都清空 ！！！！
    else {
        Class c;
        // ----- 遍历普通类
        NXHashTable *classes = realizedClasses(); // 取得所有经过 realized 的非元类
        NXHashState state = NXInitHashState(classes); // 初始化 hash state，为后面的遍历做准备，估计跟迭代器差不多
        while (NXNextHashState(classes, &state, (void **)&c)) { // 遍历所有经过 realized 的非元类
            cache_erase_nolock(c); // 将类的方法缓存清空
        }
        // ----- 遍历元类
        classes = realizedMetaclasses(); // 取得所有经过 realized 的元类
        state = NXInitHashState(classes); // 初始化 hash state
        while (NXNextHashState(classes, &state, (void **)&c)) { // 遍历所有经过 realized 的元类
            cache_erase_nolock(c); // 将元类的方法缓存清空
        }
    }
}

// 清空 cls 类的方法缓存，如果 cls == nil，则将垃圾桶中的缓存都清空，并强制释放内存
// 调用者：instrumentObjcMessageSends() 
void _objc_flush_caches(Class cls)
{
    {
        rwlock_writer_t lock(runtimeLock); // runtimeLock 加写锁
        flushCaches(cls); // 清空 cls 类的方法缓存
    }

    if (!cls) { // 如果 cls 类为 nil
        // collectALot if cls==nil
        mutex_locker_t lock(cacheUpdateLock); // 互斥锁 cacheUpdateLock 加锁
        cache_collect(true); // 清空垃圾桶，参数 true 代表需要强制地释放内存
    }
}


/***********************************************************************
* map_images
* Process the given images which are being mapped in by dyld.
* Calls ABI-agnostic code after taking ABI-specific locks.
*
* Locking: write-locks runtimeLock
**********************************************************************/
// 处理给定的镜像，这些镜像被 dyld库 映射
// 这个函数其实是一个回调函数，被 dyld 库调用，参数中的镜像信息也是 dyld 库传进来的，详情见 _objc_init()
// 调用者 ：_objc_init()
const char *
map_2_images(enum dyld_image_states state, uint32_t infoCount,
             const struct dyld_image_info infoList[])
{
    rwlock_writer_t lock(runtimeLock); // runtimeLock 加写锁
    
    // 在 map_images_nolock 函数中，完成所有 class 的注册、fixup等工作，
    // 还包括初始化自动释放池、初始化 side table 等等工作
    return map_images_nolock(state, infoCount, infoList);
}


/***********************************************************************
* load_images
* Process +load in the given images which are being mapped in by dyld.
* Calls ABI-agnostic code after taking ABI-specific locks.
*
* Locking: write-locks runtimeLock and loadMethodLock
**********************************************************************/
// 加载镜像（这个函数会被调用多次，每次有新的镜像加载进来，都会回调这个函数）
// 处理镜像中的 +load 方法，这些镜像被 dyld 库映射，
// 这个函数和 map_2_images 一样，也是一个回调函数，被 dyld 库调用，
// 参数中的镜像信息也是 dyld 库传进来的，详情见 _objc_init()
// 如果在镜像中找到 +load 方法，会调用 call_load_methods 调用这些 +load 方法（说“这些”，因为有很多类）
// 调用者 ：_objc_init()
const char *
load_images(enum dyld_image_states state, uint32_t infoCount,
            const struct dyld_image_info infoList[])
{
    bool found;

    // Return without taking locks if there are no +load methods here.
    
    // 遍历镜像列表，查看镜像中是否存在 +load 方法
    // 有一个镜像中存在，就停止遍历
    // 整个过程不加锁
    found = false;
    for (uint32_t i = 0; i < infoCount; i++) {
        // 快速扫描镜像中是否有 +load 方法 (其实只查找了镜像中是否有类或分类）
        // imageLoadAddress 是镜像加载的内存地址
        if (hasLoadMethods((const headerType *)infoList[i].imageLoadAddress)) {
            found = true;
            break;
        }
    }
    if (!found) return nil; // 如果没有找到，就直接返回 nil

    recursive_mutex_locker_t lock(loadMethodLock); // loadMethodLock 递归互斥锁加锁
                                // 递归锁在同一线程上是可重入的，在不同线程上与普通互斥锁没有区别
                                // 可重入，就是同一线程上可以多次加锁，比如递归的时候
                                // 解锁与加锁的次数必须相同，加锁几次，就必须解锁几次
                                // 因为 load_images 中调用 +load 时，会导致其他镜像被 load，
                                // load_images 函数会在一个线程上被接连调用多次，如果不用递归锁的话，就会死锁
    
    // Discover load methods
    { // 加上括号，是为了 runtimeLock 锁，可以在这个块内自动释放，否则下次重入该函数时，会死锁
        
        rwlock_writer_t lock2(runtimeLock); // runtimeLock 加写锁
        
        // 做一些准备工作，将需要 +load 的类和分类分别存储到 loadable_classes、loadable_categories 中，
        // 在 call_load_methods() 中才有类可以调 +load
        // 并进一步确认是否真的有类或分类需要调用 +load
        found = load_images_nolock(state, infoCount, infoList);
    }

    // Call +load methods (without runtimeLock - re-entrant)
    
    // 不加 runtimeLock 锁，是因为 runtimeLock 与递归锁不一样，它是不可重入的，
    // 因为 load_images 中调用 +load 时，会导致其他镜像被 load，
    // 即 load_images 函数会在一个线程上被接连调用多次，如果加上 runtimeLock，就会造成死锁
    
    if (found) { // 确实有类或分类需要 +load
        call_load_methods(); // 就调用 +load
    }

    return nil;
}


/***********************************************************************
* unmap_image
* Process the given image which is about to be unmapped by dyld.
* mh is mach_header instead of headerType because that's what 
*   dyld_priv.h says even for 64-bit.
*
* Locking: write-locks runtimeLock and loadMethodLock
**********************************************************************/
// _objc_init() 中注册的用于 dyld 进行 ummap 镜像前，对镜像做了一些处理的函数，
// unmap，即 un-memory-mapped，这里应该就是取消内存映射，移除镜像的意思，
void 
unmap_image(const struct mach_header *mh, intptr_t vmaddr_slide)
{
    recursive_mutex_locker_t lock(loadMethodLock); // loadMethodLock 递归锁加锁
    rwlock_writer_t lock2(runtimeLock); // runtimeLock 加写锁
    unmap_image_nolock(mh); // 这个函数中会找到对应的镜像，销毁镜像中的分类和类，并将镜像从镜像列表中删除
}




/***********************************************************************
* readClass
* Read a class and metaclass as written by a compiler.
* Returns the new class pointer. This could be: 
* - cls
* - nil  (cls has a missing weak-linked superclass)
* - something else (space for this class was reserved by a future class)
*
* Locking: runtimeLock acquired by map_images or objc_readClassPair
 
 读取一个编译器写的 类 或 元类，
 返回新类的指针，有可能是：
    - cls
    - nil (cls 有一个 missing weak-linked 的父类)
    - 其他 (给一个 future 类预留的空间)
 调用者：_read_images()
**********************************************************************/
Class readClass(Class cls, bool headerIsBundle/*是否是 bundle*/, bool headerIsPreoptimized/*是否被预优化过*/)
{
    const char *mangledName = cls->mangledName(); // 取得 cls 的重整后的名字
    
    if (missingWeakSuperclass(cls)) { // 查看 cls 类的祖宗类中是否有类是 weak-linked 的，并且已经 missing
        // No superclass (probably weak-linked). 
        // Disavow any knowledge of this subclass.
        
        // 祖宗类里有 missing weak-linked 的
        // 则 cls 的所有信息也是不可信的，所以将其添加到重映射表里，映射为nil，即 cls -> nil
        
        if (PrintConnecting) {
            _objc_inform("CLASS: IGNORING class '%s' with "
                         "missing weak-linked superclass", 
                         cls->nameForLogging());
        }
        addRemappedClass(cls, nil); // 将其添加到重映射表里，映射为nil
        cls->superclass = nil; // 父类指针指向 nil
        return nil;
    }
    
    // Note: Class __ARCLite__'s hack does not go through here. 
    // Class structure fixups that apply to it also need to be 
    // performed in non-lazy realization below.
    
    // These fields should be set to zero because of the 
    // binding of _objc_empty_vtable, but OS X 10.8's dyld 
    // does not bind shared cache absolute symbols as expected.
    // This (and the __ARCLite__ hack below) can be removed 
    // once the simulator drops 10.8 support.
#if TARGET_IPHONE_SIMULATOR // 如果是模拟器的话，需要手动将 类和元类 的方法存储的 容量和占用量 清零
    if (cls->cache._mask) cls->cache._mask = 0;
    if (cls->cache._occupied) cls->cache._occupied = 0;
    if (cls->ISA()->cache._mask) cls->ISA()->cache._mask = 0;
    if (cls->ISA()->cache._occupied) cls->ISA()->cache._occupied = 0;
#endif

    Class replacing = nil; // 记录被代替的类
    
    // 将 mangledName 对应的 future 的类从 future_named_class_map 中移除
    // 如果它不是一个 future 类，则会返回 nil
    if (Class newCls = popFutureNamedClass(mangledName)) {
        // This name was previously allocated as a future class.
        // Copy objc_class to future class's struct.
        // Preserve future's rw data block.
        
        // 如果 newCls 有值，则 newcls 类是一个 future 类
        
        // 但是 newcls 不能是 swift 类，因为太大了？啥意思？swift类能有多大
        if (newCls->isSwift()) {
            _objc_fatal("Can't complete future class request for '%s' "
                        "because the real class is too big.", 
                        cls->nameForLogging());
        }
        
        class_rw_t *rw = newCls->data();     // 取得 newCls 中的 rw，rw 中除了 ro 外的其他数据是需要保留的
        const class_ro_t *old_ro = rw->ro;   // 旧的 ro
        memcpy(newCls, cls, sizeof(objc_class)); // 将 cls 中的数据完整得拷贝到 newCls 中
        rw->ro = (class_ro_t *)newCls->data();   // rw 中使用新的 ro
        newCls->setData(rw);        // 将 rw 赋给 newCls，那么 newCls 中使用的还是原来的 rw，只是其中的 ro 变了
        free((void *)old_ro->name); // 旧 ro 中的 name 是在堆上分配的，所以需要释放
        free((void *)old_ro);       // 将旧 ro 释放
        
        addRemappedClass(cls, newCls); // 将 cls -> newCls 的重映射添加到映射表中
        
        replacing = cls; // 记录下 cls 类被代替
        cls = newCls;   // 新类 newCls 赋给 cls
    }
    
    if (headerIsPreoptimized  &&  !replacing) { // 预优化过，且没有被代替
        // class list built in shared cache
        // fixme strict assert doesn't work because of duplicates
        // assert(cls == getClass(name));
        assert(getClass(mangledName));
    } else {
        // 否则将 mangledName -> cls 的映射添加到 gdb_objc_realized_classes 表中
        // 如果上 cls 被 newCls 代替了，那么 replacing 就是老的 cls，即在 gdb_objc_realized_classes 中
        // 也会将老的 cls 代替
        addNamedClass(cls, mangledName, replacing);
    }
    
    // for future reference: shared cache never contains MH_BUNDLEs
    if (headerIsBundle) {
        cls->data()->flags |= RO_FROM_BUNDLE;
        cls->ISA()->data()->flags |= RO_FROM_BUNDLE;
    }
    
    return cls;
}


/***********************************************************************
* readProtocol
* Read a protocol as written by a compiler.
**********************************************************************/
// 读取一个编译器写的协议
// 调用者：_read_images()
static void
readProtocol(protocol_t *newproto, Class protocol_class,
             NXMapTable *protocol_map, 
             bool headerIsPreoptimized, bool headerIsBundle)
{
    // This is not enough to make protocols in unloaded bundles safe, 
    // but it does prevent crashes when looking up unrelated protocols.
    // 如果镜像是 bundle，就使用 NXMapKeyCopyingInsert 函数，否则使用 NXMapInsert
    // NXMapKeyCopyingInsert 会在堆中拷贝 key
    auto insertFn = headerIsBundle ? NXMapKeyCopyingInsert : NXMapInsert;

    // 根据新协议的重整名称，去 protocol_map 映射表中查找老的协议
    protocol_t *oldproto = (protocol_t *)getProtocol(newproto->mangledName);

    if (oldproto) { // 如果存在老的协议，就只报个警告，因为不允许有重名的协议
        // Some other definition already won.
        if (PrintProtocols) {
            _objc_inform("PROTOCOLS: protocol at %p is %s  "
                         "(duplicate of %p)",
                         newproto, oldproto->nameForLogging(), oldproto);
        }
    }
    else if (headerIsPreoptimized) { // 如果不存在老的协议，但是镜像是经过预优化的
        // Shared cache initialized the protocol object itself, 
        // but in order to allow out-of-cache replacement we need 
        // to add it to the protocol table now.

        // 根据新协议的重整名称 查找 预优化的缓存协议
        // 但是 getPreoptimizedProtocol 现在一直返回 nil
        protocol_t *cacheproto = (protocol_t *)
            getPreoptimizedProtocol(newproto->mangledName);
        
        protocol_t *installedproto;
        if (cacheproto  &&  cacheproto != newproto) {
            // Another definition in the shared cache wins (because 
            // everything in the cache was fixed up to point to it).
            installedproto = cacheproto;
        }
        else { // 因为 cacheproto 永远是 nil，所以一直走 else 分支
            // This definition wins.
            installedproto = newproto;
        }
        
        assert(installedproto->getIsa() == protocol_class);
        assert(installedproto->size >= sizeof(protocol_t));
        
        // 将 新协议的重整名称 -> 新协议 的映射插入 protocol_map 映射表中
        insertFn(protocol_map, installedproto->mangledName, 
                 installedproto);
        
        if (PrintProtocols) {
            _objc_inform("PROTOCOLS: protocol at %p is %s", 
                         installedproto, installedproto->nameForLogging());
            if (newproto != installedproto) {
                _objc_inform("PROTOCOLS: protocol at %p is %s  "
                             "(duplicate of %p)", 
                             newproto, installedproto->nameForLogging(), 
                             installedproto);
            }
        }
    }
    else if (newproto->size >= sizeof(protocol_t)) { // 如果不存在老的协议，且没有经过预优化，且新协议的大小
                                                     // 比 protocol_t 的标准尺寸要大
        // New protocol from an un-preoptimized image
        // with sufficient storage. Fix it up in place.
        // fixme duplicate protocols from unloadable bundle
        newproto->initIsa(protocol_class);  // fixme pinned
        insertFn(protocol_map, newproto->mangledName, newproto); // 就将 新协议的重整名称 -> 新协议 的映射插入
                                                                 // protocol_map 映射表中
        if (PrintProtocols) {
            _objc_inform("PROTOCOLS: protocol at %p is %s",
                         newproto, newproto->nameForLogging());
        }
    }
    else { // 如果不存在老的协议，且没有经过预优化，且新协议的大小比 protocol_t 的标准尺寸要小
        
        // New protocol from an un-preoptimized image
        // with insufficient storage. Reallocate it.
        // fixme duplicate protocols from unloadable bundle
        
        // 取大的 size，这里按照上面的逻辑，应该是 sizeof(protocol_t)
        size_t size = max(sizeof(protocol_t), (size_t)newproto->size);
        // 新建一个 installedproto 协议，在堆中分配内存，并清零
        protocol_t *installedproto = (protocol_t *)calloc(size, 1);
        // 将 newproto 内存上的内容 拷贝到 installedproto 中
        memcpy(installedproto, newproto, newproto->size);
        // 将 installedproto->size 设为新的 size
        installedproto->size = (__typeof__(installedproto->size))size;
        
        installedproto->initIsa(protocol_class); // 设置 isa  // fixme pinned
        
        // 将 installedproto 插入 protocol_map 映射表中
        insertFn(protocol_map, installedproto->mangledName, installedproto);
        
        if (PrintProtocols) {
            _objc_inform("PROTOCOLS: protocol at %p is %s  ", 
                         installedproto, installedproto->nameForLogging());
            _objc_inform("PROTOCOLS: protocol at %p is %s  "
                         "(reallocated to %p)", 
                         newproto, installedproto->nameForLogging(), 
                         installedproto);
        }
    }
}

/***********************************************************************
* _read_images
* Perform initial processing of the headers in the linked 
* list beginning with headerList. 
*
* Called by: map_images_nolock
*
* Locking: runtimeLock acquired by map_images
**********************************************************************/

// 注释了，不然编译报错
//extern "C" int dyld_get_program_sdk_version();
#define DYLD_MACOSX_VERSION_10_11 MAC_OS_X_VERSION_10_11

// 读取镜像（即二进制文件）
// 该函数被 map_images_nolock() 调用
// hList 是指向一个 header 链表的指针，
// hList 中包含了很多被加载进来的库，比如 libdispatch.dylib、libxpc.dylib、libsystem_trace.dylib、
//         libsystem_network.dylib、CoreData、AudioToolBox 等等，
// 疑问：hCount 是什么？？hCount 并不是 hList 中元素数目，二者不相等？？
void _read_images(header_info **hList, uint32_t hCount)
{
    header_info *hi; // 用于遍历
    uint32_t hIndex; // header index，遍历 hList 时的索引
    size_t count;
    size_t i;
    Class *resolvedFutureClasses = nil; // 一个数组，在堆中分配，存放被 resolve 的 future 类
    size_t resolvedFutureClassCount = 0; // 记录被 resolve 的 future 类 的数目
    static bool doneOnce; // 用来标记只执行一次的操作
    TimeLogger ts(PrintImageTimes);

    runtimeLock.assertWriting();

#define EACH_HEADER \
    hIndex = 0;         \
    crashlog_header_name(nil) && hIndex < hCount && (hi = hList[hIndex]) && crashlog_header_name(hi); \
    hIndex++

    if (!doneOnce) { // 这个块里的代码只会执行一次
        doneOnce = YES;

#if SUPPORT_NONPOINTER_ISA  // 如果支持 non-pointer 的 isa

# if TARGET_OS_MAC  &&  !TARGET_OS_IPHONE // 
        // Disable non-pointer isa if the app is too old
        // (linked before OS X 10.11)
        if (dyld_get_program_sdk_version() < DYLD_MACOSX_VERSION_10_11) { // 如果 sdk 版本小于 10.11
            DisableIndexedIsa = true;
            if (PrintRawIsa) {
                _objc_inform("RAW ISA: disabling non-pointer isa because "
                             "the app is too old (SDK version " SDK_FORMAT ")",
                             FORMAT_SDK(dyld_get_program_sdk_version()));
            }
        }

        // Disable non-pointer isa if the app has a __DATA,__objc_rawisa section
        // New apps that load old extensions may need this.
        for (EACH_HEADER) { // 遍历 hList，如果 app 有一个 __DATA,__objc_rawisa section
                            // 就禁止 non-pointer isa
            if (hi->mhdr->filetype != MH_EXECUTE) continue;
            unsigned long size;
            if (getsectiondata(hi->mhdr, "__DATA", "__objc_rawisa", &size)) {
                DisableIndexedIsa = true;
                if (PrintRawIsa) {
                    _objc_inform("RAW ISA: disabling non-pointer isa because "
                                 "the app has a __DATA,__objc_rawisa section");
                }
            }
            break;  // assume only one MH_EXECUTE image
        }
# endif

        // Disable non-pointer isa for all GC apps.
        if (UseGC) { // GC，不用管它
            DisableIndexedIsa = true;
            if (PrintRawIsa) {
                _objc_inform("RAW ISA: disabling non-pointer isa because "
                             "the app is GC");
            }
        }

#endif

        if (DisableTaggedPointers) { // 是否需要禁止 tagged pointer
            disableTaggedPointers();
        }
        
        // Count classes. Size various table based on the total.
        // 计算类的总数
        int total = 0; // 总数
        int unoptimizedTotal = 0; // 未优化的类的总数，不包括处于 shared cache 中的类
        for (EACH_HEADER) { // 遍历 hList
            if (_getObjc2ClassList(hi, &count)) { // 获得 header 中所有 objective-2.0 类的列表
                total += (int)count; // 总数加 1
                if (!hi->inSharedCache) { // 如果 header 不在 shared cache 的话，未优化的类的总数加 1
                    unoptimizedTotal += count;
                }
            }
        }
        
        if (PrintConnecting) {
            _objc_inform("CLASS: found %d classes during launch", total);
        }

        // namedClasses (NOT realizedClasses)
        // Preoptimized classes don't go in this table.
        // 4/3 is NXMapTable's load factor
        
        // 分别创建 gdb_objc_realized_classes、realized_class_hash、realized_metaclass_hash 三个表
        
        // gdb_objc_realized_classes 中装的是不在 shared cache 中的类，所以如果经过了预优化，
        // 那么就只考虑未优化的那些类，即 unoptimizedTotal，否则考虑全部类 total
        int namedClassesSize = 
            (isPreoptimized() ? unoptimizedTotal : total) * 4 / 3;
        gdb_objc_realized_classes =
            NXCreateMapTable(NXStrValueMapPrototype, namedClassesSize);
        
        // realizedClasses and realizedMetaclasses - less than the full total
        realized_class_hash = 
            NXCreateHashTable(NXPtrPrototype, total / 8, nil);
        realized_metaclass_hash = 
            NXCreateHashTable(NXPtrPrototype, total / 8, nil);

        ts.log("IMAGE TIMES: first time tasks");
    }


    // Discover classes. Fix up unresolved future classes. Mark bundle classes.

    for (EACH_HEADER) { // 遍历 hList
        bool headerIsBundle = hi->isBundle(); // header 是否是 bundle 类型
        bool headerIsPreoptimized = hi->isPreoptimized(); // header 是否经过预优化

        // 取出 header 中的所有的 objective-c 2.0 的类
        classref_t *classlist = _getObjc2ClassList(hi, &count);
        for (i = 0; i < count; i++) { // 遍历类列表
            Class cls = (Class)classlist[i];
            // 读取该类，会做一些处理，取得新类(逻辑很复杂，完全懵圈)
            Class newCls = readClass(cls, headerIsBundle, headerIsPreoptimized);

            // 如果获得的是一个非空的新类
            if (newCls != cls  &&  newCls) {
                // Class was moved but not deleted. Currently this occurs 
                // only when the new class resolved a future class.
                // Non-lazily realize the class below.
                
                // 类被移动了，但是没有被删除，
                // 这只会发生在新类 resolve 了一个 future 类的情况下
                // 下面以非惰性的方法 realize 了 newCls
                
                // 为 resolvedFutureClasses 数组重新开辟一块更大的空间，并将原来的数据拷贝进来
                resolvedFutureClasses = (Class *)
                    realloc(resolvedFutureClasses, 
                                      (resolvedFutureClassCount+1) 
                                      * sizeof(Class));
                // 将 newCls 添加到数组的末尾，resolvedFutureClassCount 加 1
                resolvedFutureClasses[resolvedFutureClassCount++] = newCls;
            }
        }
    }

    ts.log("IMAGE TIMES: discover classes");

    // Fix up remapped classes
    // Class list and nonlazy class list remain unremapped.
    // Class refs and super refs are remapped for message dispatching.
    
    // fix up 重映射的类
    // 类列表 和 非惰性的类列表 保持 unremapped (#疑问：什么意思？？？= = )
    // Class ref 和 super refs 被重映射，以用于消息派发
    
    // 如果 remapped_class_map 不是空的
    if (!noClassesRemapped()) {
        for (EACH_HEADER) { // 遍历 hList
            // 取得 header 中所有的类引用
            Class *classrefs = _getObjc2ClassRefs(hi, &count);
            // 遍历这些类引用，fix-up 类引用，从重映射类表中取出新类，如果旧类新类不一致，就将新类赋给这个类引用
            for (i = 0; i < count; i++) {
                remapClassRef(&classrefs[i]);
            }
            // fixme why doesn't test future1 catch the absence of this?
            // 取得镜像中所有类的父类引用
            classrefs = _getObjc2SuperRefs(hi, &count);
            // 遍历父类引用，将其 fix-up 了
            for (i = 0; i < count; i++) {
                remapClassRef(&classrefs[i]);
            }
        }
    }

    ts.log("IMAGE TIMES: remap classes");

    // Fix up @selector references fixup @selector 引用
    static size_t UnfixedSelectors; // 记录 hList 中所有镜像中一共有多少 unfixed 的 selector
    sel_lock(); // selLock 上写锁
    for (EACH_HEADER) { // 遍历 hList
        // 只处理没有预优化的，被预优化过的就跳过
        if (hi->isPreoptimized()) continue;

        bool isBundle = hi->isBundle(); // 是否是 bundle
        // 取得镜像中所有的 selector 引用
        SEL *sels = _getObjc2SelectorRefs(hi, &count);
        UnfixedSelectors += count; // 累加
        for (i = 0; i < count; i++) { // 遍历刚才取出的 selector
            const char *name = sel_cname(sels[i]); // 转为char * 字符串
            sels[i] = sel_registerNameNoLock(name, isBundle); // 注册这个 selector 的名字
        }
    }
    sel_unlock(); // selLock 释放写锁

    ts.log("IMAGE TIMES: fix up selector references");

#if SUPPORT_FIXUP
    // Fix up old objc_msgSend_fixup call sites  fixup 老的 objc_msgSend_fixup
    for (EACH_HEADER) {
        message_ref_t *refs = _getObjc2MessageRefs(hi, &count);
        if (count == 0) continue;

        if (PrintVtables) {
            _objc_inform("VTABLES: repairing %zu unsupported vtable dispatch "
                         "call sites in %s", count, hi->fname);
        }
        for (i = 0; i < count; i++) {
            fixupMessageRef(refs+i);
        }
    }

    ts.log("IMAGE TIMES: fix up objc_msgSend_fixup");
#endif

    // Discover protocols. Fix up protocol refs. 取得镜像中的协议，读出协议
    for (EACH_HEADER) {
        extern objc_class OBJC_CLASS_$_Protocol;
        Class cls = (Class)&OBJC_CLASS_$_Protocol;
        assert(cls);
        NXMapTable *protocol_map = protocols();
        bool isPreoptimized = hi->isPreoptimized();
        bool isBundle = hi->isBundle();

        protocol_t **protolist = _getObjc2ProtocolList(hi, &count);
        for (i = 0; i < count; i++) {
            readProtocol(protolist[i], cls, protocol_map, 
                         isPreoptimized, isBundle);
        }
    }

    ts.log("IMAGE TIMES: discover protocols");

    // Fix up @protocol references
    // Preoptimized images may have the right 
    // answer already but we don't know for sure.
    for (EACH_HEADER) {
        protocol_t **protolist = _getObjc2ProtocolRefs(hi, &count);
        for (i = 0; i < count; i++) {
            remapProtocolRef(&protolist[i]);
        }
    }

    ts.log("IMAGE TIMES: fix up @protocol references");

    // Realize non-lazy classes (for +load methods and static instances)
    for (EACH_HEADER) {
        classref_t *classlist = 
            _getObjc2NonlazyClassList(hi, &count);
        for (i = 0; i < count; i++) {
            Class cls = remapClass(classlist[i]);
            if (!cls) continue;

            // hack for class __ARCLite__, which didn't get this above
#if TARGET_IPHONE_SIMULATOR
            if (cls->cache._buckets == (void*)&_objc_empty_cache  &&  
                (cls->cache._mask  ||  cls->cache._occupied)) 
            {
                cls->cache._mask = 0;
                cls->cache._occupied = 0;
            }
            if (cls->ISA()->cache._buckets == (void*)&_objc_empty_cache  &&  
                (cls->ISA()->cache._mask  ||  cls->ISA()->cache._occupied)) 
            {
                cls->ISA()->cache._mask = 0;
                cls->ISA()->cache._occupied = 0;
            }
#endif

            realizeClass(cls);
        }
    }

    ts.log("IMAGE TIMES: realize non-lazy classes");

    
    // Realize newly-resolved future classes, in case CF manipulates them
    if (resolvedFutureClasses) { // 如果存在被 resolved 的 future 类
        for (i = 0; i < resolvedFutureClassCount; i++) { // 遍历这些被 resolved 的 future 类
            realizeClass(resolvedFutureClasses[i]); // 将类 realize 了
            // 设置这个类和这个类的子类们需要 raw isa
            resolvedFutureClasses[i]->setRequiresRawIsa(false/*inherited*/);
        }
        free(resolvedFutureClasses); // 将 resolvedFutureClasses 释放了
    }    

    ts.log("IMAGE TIMES: realize future classes");

    
    // Discover categories.
    for (EACH_HEADER) { // 遍历 hList
        // 取得 hi 镜像中的所有分类
        category_t **catlist = _getObjc2CategoryList(hi, &count);
        for (i = 0; i < count; i++) { // 遍历所有分类
            category_t *cat = catlist[i];
            Class cls = remapClass(cat->cls); // 得到分类所属的类的 live class

            if (!cls) { // 如果 cls 为空
                // Category's target class is missing (probably weak-linked).
                // Disavow any knowledge of this category.
                
                // 分类所属的类丢了，很多可能是 weak-linked 了
                // 这个分类就是不可信的，完全没有什么鸟用了
                
                catlist[i] = nil; // 将这个分类从列表中删除
                
                if (PrintConnecting) {
                    _objc_inform("CLASS: IGNORING category \?\?\?(%s) %p with "
                                 "missing weak-linked target class", 
                                 cat->name, cat);
                }
                continue;
            }

            // Process this category. 
            // First, register the category with its target class. 
            // Then, rebuild the class's method lists (etc) if 
            // the class is realized.
            
            // 处理这个分类
            // 首先，注册注册这个分类
            // 然后，如果这个类已经是 realized 的话，就重新建立这个类的方法列表（把分类的方法添加进去）
            
            bool classExists = NO;
            
            if (cat->instanceMethods ||  cat->protocols  
                ||  cat->instanceProperties) // 如果分类中存在实例方法 or 协议 or 实例属性
            {
                // 添加分类到所属的 cls 类上，即把这个分类添加到 cls 对应的所有 unattached 的分类的列表中
                addUnattachedCategoryForClass(cat, cls, hi);
                
                // 如果 cls 类已经被 realized
                if (cls->isRealized()) {
                    // 就重新 methodize 一下 cls 类，里面会重新 attachCategories 一下所有未被 attach 的分类
                    // 即把这些分类中的方法、协议、属性添加到 cls 类中
                    remethodizeClass(cls);
                    classExists = YES; // 标记类存在
                }
                if (PrintConnecting) {
                    _objc_inform("CLASS: found category -%s(%s) %s", 
                                 cls->nameForLogging(), cat->name, 
                                 classExists ? "on existing class" : "");
                }
            }

            // 如果分类中存在类方法 or 协议
            if (cat->classMethods  ||  cat->protocols  
                /* ||  cat->classProperties */) 
            {
                // 添加分类到所属类 cls 的元类中
                addUnattachedCategoryForClass(cat, cls->ISA(), hi);
                // 如果 cls 的元类已经 realized 过了
                if (cls->ISA()->isRealized()) {
                    // 就重新 methodize 一下 cls 类的元类
                    remethodizeClass(cls->ISA());
                }
                if (PrintConnecting) {
                    _objc_inform("CLASS: found category +%s(%s)", 
                                 cls->nameForLogging(), cat->name);
                }
            }
        }
    }

    ts.log("IMAGE TIMES: discover categories");

    // Category discovery MUST BE LAST to avoid potential races（潜在的竞争）
    // when other threads call the new category code before 
    // this thread finishes its fixups.

    // 搜索分类必须放在最后，防止其他线程在当前线程完成 fixup 之前就调用分类，导致竞争（即线程不安全）
    // 这步走完了，就会进入 load_images 函数，调用类的 +load 方法
    
    // +load handled by prepare_load_methods() 这行的意思见上面

    // 如果开启了调试 non-fragile 成员变量，就将所有类都 realize 了
    // 但这仅限于 DEBUG，所以事实上的最后一步还是上面的 Category discovery
    if (DebugNonFragileIvars) {
        realizeAllClasses();
    }


    // Print preoptimization statistics  打印预优化的统计信息，不用深究
    if (PrintPreopt) {
        static unsigned int PreoptTotalMethodLists;
        static unsigned int PreoptOptimizedMethodLists;
        static unsigned int PreoptTotalClasses;
        static unsigned int PreoptOptimizedClasses;

        for (EACH_HEADER) {
            if (hi->isPreoptimized()) {
                _objc_inform("PREOPTIMIZATION: honoring preoptimized selectors "
                             "in %s", hi->fname);
            }
            else if (_objcHeaderOptimizedByDyld(hi)) {
                _objc_inform("PREOPTIMIZATION: IGNORING preoptimized selectors "
                             "in %s", hi->fname);
            }

            classref_t *classlist = _getObjc2ClassList(hi, &count);
            for (i = 0; i < count; i++) {
                Class cls = remapClass(classlist[i]);
                if (!cls) continue;

                PreoptTotalClasses++;
                if (hi->isPreoptimized()) {
                    PreoptOptimizedClasses++;
                }
                
                const method_list_t *mlist;
                if ((mlist = ((class_ro_t *)cls->data())->baseMethods())) {
                    PreoptTotalMethodLists++;
                    if (mlist->isFixedUp()) {
                        PreoptOptimizedMethodLists++;
                    }
                }
                if ((mlist=((class_ro_t *)cls->ISA()->data())->baseMethods())) {
                    PreoptTotalMethodLists++;
                    if (mlist->isFixedUp()) {
                        PreoptOptimizedMethodLists++;
                    }
                }
            }
        }

        _objc_inform("PREOPTIMIZATION: %zu selector references not "
                     "pre-optimized", UnfixedSelectors);
        _objc_inform("PREOPTIMIZATION: %u/%u (%.3g%%) method lists pre-sorted",
                     PreoptOptimizedMethodLists, PreoptTotalMethodLists, 
                     PreoptTotalMethodLists
                     ? 100.0*PreoptOptimizedMethodLists/PreoptTotalMethodLists 
                     : 0.0);
        _objc_inform("PREOPTIMIZATION: %u/%u (%.3g%%) classes pre-registered",
                     PreoptOptimizedClasses, PreoptTotalClasses, 
                     PreoptTotalClasses 
                     ? 100.0*PreoptOptimizedClasses/PreoptTotalClasses
                     : 0.0);
        _objc_inform("PREOPTIMIZATION: %zu protocol references not "
                     "pre-optimized", UnfixedProtocolReferences);
    }

#undef EACH_HEADER
}


/***********************************************************************
* prepare_load_methods
* Schedule +load for classes in this image, any un-+load-ed 
* superclasses in other images, and any categories in this image.
**********************************************************************/
// Recursively schedule +load for cls and any un-+load-ed superclasses.
// cls must already be connected.
// 为 cls 安排 +load，就是将类添加到 loadable_classes 列表中，
// 函数中会首先递归向上遍历 cls 的祖宗类，直到某个祖宗类是已经被加载过的，或者直到根类
// 保证 loadable_classes 列表中，父类在前，子类在后，父类的 +load 先被调用
static void schedule_class_load(Class cls)
{
    if (!cls) return; // cls 为 nil，这会出现在根类的时候，结束递归
    
    assert(cls->isRealized());  // cls 必须已经是 realize 的，即 realize 在 load 之前，
                                // realize 是在 _read_images() 中做的

    if (cls->data()->flags & RW_LOADED) return; // 如果该类已经被 load 过了，就直接返回，结束递归

    // Ensure superclass-first ordering
    schedule_class_load(cls->superclass); // 递归，确保在 loadable_classes 列表中父类排在前面

    add_class_to_loadable_list(cls); // 将 cls 类添加到 loadable_classes 列表中
                                     // 其中会检查 cls 类是否确实有 +load 方法，只有拥有 +load 方法，才会将其添加到 loadable_classes 列表
    
    cls->setInfo(RW_LOADED); // 将 cls 类设置为已经 load
}

// Quick scan for +load methods that doesn't take a lock.
// 快速扫描镜像中是否有 +load 方法，整个过程不加锁
// 调用者：load_images() / load_images_nolock()
bool hasLoadMethods(const headerType *mhdr)
{
    size_t count;
    // 扫描类列表
    if (_getObjc2NonlazyClassList(mhdr, &count)  &&  count > 0) return true;
    // 扫描分类列表
    if (_getObjc2NonlazyCategoryList(mhdr, &count)  &&  count > 0) return true;
    
    // #疑问：真是让人费解啊，完全没有地方在检查 +load 方法嘛，难道说只要有类或者分类，就一定有 +load 方法？？
    
    return false;
}

// 为加载方法（调用 +load）做一些准备工作，
// 遍历所有类，按父类在前子类在后的顺序，将所有未 load 的类及其未 load 的祖宗类们添加到 loadable_classes 列表中，
// 遍历所有分类，将分类所属的类 realize 后，把分类添加到 loadable_categories 列表中，
// 调用者：load_images_nolock()
void prepare_load_methods(const headerType *mhdr)
{
    size_t count, i;

    runtimeLock.assertWriting(); // runtimeLock 需要事先加好写锁（是在 load_images() 中加的锁）

    // 获得镜像中所有 objective-2.0 且是非惰性的 类的 列表
    classref_t *classlist = _getObjc2NonlazyClassList(mhdr, &count);
    
    // 遍历类列表，先取得重映射的类，然后调用 schedule_class_load 函数将其添加到 loadable_classes 列表中
    for (i = 0; i < count; i++) {
        schedule_class_load(remapClass(classlist[i]));
    }

    // 取得分类列表
    category_t **categorylist = _getObjc2NonlazyCategoryList(mhdr, &count);
    
    // 遍历分类列表
    for (i = 0; i < count; i++) {
        category_t *cat = categorylist[i];
        Class cls = remapClass(cat->cls); // 取得 分类所属的类 所对应的 重映射类
        if (!cls) continue;  // category for ignored weak-linked class
                             // cls == nil，即 cat->cls 是 ignored weak-linked 类，就跳过
        realizeClass(cls);  // 将 cls 类 realize 了，里面当然也会一并 realize 了 cls 的祖宗类和元类
        assert(cls->ISA()->isRealized()); // 确认 realizeClass 是否已经将 cls 的元类也一并 realize 了，
                                          // 见 realizeClass()
        add_category_to_loadable_list(cat); // 将分类 cat 添加到 loadable_categories 列表中
    }
}


/***********************************************************************
* _unload_image
* Only handles MH_BUNDLE for now.
* Locking: write-lock and loadMethodLock acquired by unmap_image
**********************************************************************/
// 卸载镜像，有两部分
// 一、卸载分类，将分类从所属的类上移除，并从 loadable_categories 列表中移除，
// 二、卸载类，将类从 loadable_classes 中移除，断开类和其他数据结构的关系，并将类销毁，
// 调用者：unmap_image_nolock()
void _unload_image(header_info *hi)
{
    size_t count, i;

    loadMethodLock.assertLocked(); // loadMethodLock 和 runtimeLock 都必须事先上锁
    runtimeLock.assertWriting();

    // Unload unattached categories and categories waiting for +load.

    // 将正在等待执行 +load 的还未 attached 分类 和 已经 attached 的分类都卸载了
    
    category_t **catlist = _getObjc2CategoryList(hi, &count); // 取得镜像中的分类列表
    for (i = 0; i < count; i++) { // 遍历分类列表
        category_t *cat = catlist[i];
        if (!cat) continue;  // category for ignored weak-linked class
                        // 如果分类为 nil，那么它所属的类是 weak-linked 的，
                        // 见 read_images() 中 Discover categories 部分的操作，如果分类所属的类是 weak-linked，就会直接将分类移除
        Class cls = remapClass(cat->cls); // 得到分类所属类的 重映射后的 类
        assert(cls);  // shouldn't have live category for dead class
                      // 断言，因为不存在的类，不应该有分类，而是像上面的 weak-linked 类一样

        // fixme for MH_DYLIB cat's class may have been unloaded already

        // unattached list
        removeUnattachedCategoryForClass(cat, cls); // 将分类 cat 从 cls 类的 unattached 分类列表中移除

        // +load queue
        remove_category_from_loadable_list(cat); // 将分类 cat 从 loadable_categories 列表中删除
    }

    // Unload classes.
    // 卸载类

    // 取得镜像中的类列表
    classref_t *classlist = _getObjc2ClassList(hi, &count);

    // First detach classes from each other. Then free each class.
    // This avoid bugs where this loop unloads a subclass before its superclass

    // 首先断开类之间的关系，然后将它们销毁
    // 这避免了循环中，子类在父类之前被卸载而导致BUG，为什么会导致 BUG 呢？？
    // 因为父类与子类的继承关系是多叉树的结构，见 rw 中的 firstSubclass 和 nextSiblingClass，一个类的子类是以链表串起来的，
    // detach_class 中断开与父类的关系，也是将自己从父类的继承树上摘除，见 removeSubclass()，
    // 但是，如果其中的一个子类比父类先被销毁，那么它的 nextSiblingClass 指针也一并被销毁了，且上一个
    // 子类的 nextSiblingClass 变成了野指针，即子类链表断了，这就没法儿继续玩了是不是
    
    for (i = 0; i < count; i++) { // 遍历类列表，断开类之间的关系
        Class cls = remapClass(classlist[i]); // 取出每个类对应的重映射类 cls
        if (cls) {
            remove_class_from_loadable_list(cls); // 将 cls 类从 loadable_classes 列表中删除
            detach_class(cls->ISA(), YES); // 断开 cls 的元类和其他数据结构的关系，YES 代表是元类
            detach_class(cls, NO); // 断开 cls 和其他数据结构的关系，NO 代表非元类
        }
    }
    
    for (i = 0; i < count; i++) { // 遍历类列表，逐一将类释放
        Class cls = remapClass(classlist[i]); // 取出每个类对应的重映射类 cls
        if (cls) {
            free_class(cls->ISA()); // 释放 cls 类的元类
            free_class(cls); // 释放 cls 类
        }
    }
    
    // XXX FIXME -- Clean up protocols:
    // <rdar://problem/9033191> Support unloading protocols at dylib/image unload time

    // fixme DebugUnload
}


/***********************************************************************
* method_getDescription
* Returns a pointer to this method's objc_method_description.
* Locking: none
**********************************************************************/
// 返回方法的 objc_method_description
struct objc_method_description *
method_getDescription(Method m)
{
    if (!m) return nil;
    return (struct objc_method_description *)m; // 强转为 objc_method_description * 类型，二者的前两个变量是一模一样的
}

// 返回方法的 IMP
IMP 
method_getImplementation(Method m)
{
    return m ? m->imp : nil;
}


/***********************************************************************
* method_getName
* Returns this method's selector.
* The method must not be nil.
* The method must already have been fixed-up.
* Locking: none
**********************************************************************/
// 返回方法的 SEL
SEL 
method_getName(Method m)
{
    if (!m) return nil;

    assert(m->name == sel_registerName(sel_getName(m->name)));
    return m->name;
}


/***********************************************************************
* method_getTypeEncoding
* Returns this method's old-style type encoding string.
* The method must not be nil.
* Locking: none
**********************************************************************/
// 返回方法的 type 字符串
const char *
method_getTypeEncoding(Method m)
{
    if (!m) return nil;
    return m->types;
}


/***********************************************************************
* method_setImplementation
* Sets this method's implementation to imp.
* The previous implementation is returned.
**********************************************************************/
// 设置 cls 类中 m 方法的 IMP，会返回老的 IMP
// 设置新的 IMP 后会清空方法缓存，并检查自定义 RR/AWZ
// 调用者：addMethod() / method_setImplementation()
static IMP 
_method_setImplementation(Class cls, method_t *m, IMP imp)
{
    runtimeLock.assertWriting(); // runtimeLock 必须事先加写锁

    if (!m) return nil;  // 方法和 IMP 都不能为空，否则没法儿玩
    if (!imp) return nil;

    if (ignoreSelector(m->name)) { // 判断方法是否需要被忽略，被忽略的方法永远都是被忽略的
        // Ignored methods stay ignored
        return m->imp;
    }

    IMP old = m->imp; // 保存老的 IMP，留作最后返回
    m->imp = imp; // 设置新的 IMP

    // Cache updates are slow if cls is nil (i.e. unknown)
    // RR/AWZ updates are slow if cls is nil (i.e. unknown)
    // fixme build list of classes whose Methods are known externally?

    flushCaches(cls); // 因为 IMP 变了，所以 cls 类的方法缓存也失效了，需要将方法缓存清空
                      // 注意，如果 cls == nil，flushCaches 会将所有类的方法缓存清空，这会很慢

    updateCustomRR_AWZ(cls, m); // 看 meth 方法是否是自定义 RR or AWZ，如果是的话，会做一些处理
                                // 如果 cls == nil，就会检查所有类，这会很慢

    return old;
}


// 设置 m 方法的 IMP
// 里面也调用了 _method_setImplementation，但与之不同的是加了锁，
// 以及没有 cls 参数，即不指定这个方法是属于哪个类的，
// 那么调用这个方法设置方法的 IMP 后，最后会清空所有类的方法缓存，检查所有类的 RR/AWZ，这个过程会很慢，效率低
IMP 
method_setImplementation(Method m, IMP imp)
{
    // Don't know the class - will be slow if RR/AWZ are affected
    // fixme build list of classes whose Methods are known externally?
    rwlock_writer_t lock(runtimeLock); // runtimeLock 加写锁
    return _method_setImplementation(Nil, m, imp);
}

// 交换方法的 IMP
void method_exchangeImplementations(Method m1, Method m2)
{
    if (!m1  ||  !m2) return; // 两个方法都不能为空

    rwlock_writer_t lock(runtimeLock); // runtimeLock 必须加写锁

    // 如果两个方法中有一个是需要被忽略的，那么很悲剧的是，现在，两个方法都是被忽略的了
    if (ignoreSelector(m1->name)  ||  ignoreSelector(m2->name)) {
        // Ignored methods stay ignored. Now they're both ignored.
        m1->imp = (IMP)&_objc_ignored_method;
        m2->imp = (IMP)&_objc_ignored_method;
        return;
    }

    // 用一个中间变量，实现两个 IMP 的交换
    IMP m1_imp = m1->imp;
    m1->imp = m2->imp;
    m2->imp = m1_imp;


    // RR/AWZ updates are slow because class is unknown
    // Cache updates are slow because class is unknown
    // fixme build list of classes whose Methods are known externally?

    flushCaches(nil); // 因为不知道方法属于哪个类，所以需要清空所有类的方法缓存

    updateCustomRR_AWZ(nil, m1); // 同样因为不知道方法属于哪个类，所以需要检查所有类的自定义 RR/AWZ
    updateCustomRR_AWZ(nil, m2);
}


/***********************************************************************
* ivar_getOffset
* fixme
* Locking: none
**********************************************************************/
// 取得成员变量位于类对应的 IMPL 结构体中的偏移量
ptrdiff_t
ivar_getOffset(Ivar ivar)
{
    if (!ivar) return 0;
    return *ivar->offset;
}


/***********************************************************************
* ivar_getName
* fixme
* Locking: none
**********************************************************************/
// 取得成员遍历的名称
const char *
ivar_getName(Ivar ivar)
{
    if (!ivar) return nil;
    return ivar->name;
}


/***********************************************************************
* ivar_getTypeEncoding
* fixme
* Locking: none
**********************************************************************/
// 取得成员变量的 type 字符串
const char *
ivar_getTypeEncoding(Ivar ivar)
{
    if (!ivar) return nil;
    return ivar->type;
}

// 取得协议的名称
const char *property_getName(objc_property_t prop)
{
    return prop->name;
}

// 取得协议的特性字符串
const char *property_getAttributes(objc_property_t prop)
{
    return prop->attributes;
}

// 取得属性的特性列表，是一个堆中的数组，用 outCount 接收数组中元素的个数
objc_property_attribute_t *property_copyAttributeList(objc_property_t prop, 
                                                      unsigned int *outCount)
{
    if (!prop) {
        if (outCount) *outCount = 0;
        return nil;
    }

    rwlock_reader_t lock(runtimeLock); // runtimeLock 加读锁
    
    // 从 prop->attributes 字符串中取出特性列表，并用 outCount 接收元素个数
    return copyPropertyAttributeList(prop->attributes,outCount);
}

// 拷贝 prop 属性中，指定 name 对应的 Attribute 的值
char * property_copyAttributeValue(objc_property_t prop, const char *name)
{
    if (!prop  ||  !name  ||  *name == '\0') return nil;
    
    rwlock_reader_t lock(runtimeLock); // runtimeLock 加读锁
    
    // 拷贝 prop->attributes 字符串中，指定 name 对应的 attribute 的值，并返回
    return copyPropertyAttributeValue(prop->attributes, name);
}


/***********************************************************************
* getExtendedTypesIndexesForMethod
* Returns:
* a is the count of methods in all method lists before m's method list
* b is the index of m in m's method list
* a+b is the index of m's extended types in the extended types array
**********************************************************************/
// 获得 proto 协议中 m 方法的扩展类型位于 扩展类型 数组(extendedMethodTypes)中的索引
// 这个索引值与 m 方法位于所有方法列表中的索引位置的值是相等的
// 协议中的方法列表有 instanceMethods、classMethods、optionalInstanceMethods、optionalClassMethods
// isRequiredMethod: 是否是 required 的方法(与 optional 相对)
// isInstanceMethod: 是否是实例方法(与类方法相对)
// a 和 b 都是输出参数，
// a 是 m 所在的方法列表之前的所有方法列表中的方法个数
// b 是 m 方法位于 m 所在的方法列表的索引
// a + b 是 m 方法的扩展类型(extended types)位于扩展类型数组(extendedMethodTypes)中的索引
// 调用者：fixupProtocolMethodList() / getExtendedTypesIndexForMethod()
static void getExtendedTypesIndexesForMethod(protocol_t *proto, const method_t *m,
                                             bool isRequiredMethod, bool isInstanceMethod,
                                             uint32_t& a, uint32_t &b)
{
    a = 0; // a 初始化为 0

    if (proto->instanceMethods) { // 如果 proto 中存在实例方法
        if (isRequiredMethod && isInstanceMethod) { // 且 m 方法既是 required 的，也是实例方法，
                                                    // 则 m 方法位于第一个方法列表 instanceMethods 中
            b = proto->instanceMethods->indexOfMethod(m); // 取得 m 方法在 instanceMethods 列表中的索引，赋值给 b
                                                          // 因为 instanceMethods 是第一个列表，所以 a = 0,
                                                          // a 在上面已经初始化为 0 过了
            return; // 直接返回
        }
        
        a += proto->instanceMethods->count; // 如果 m 方法不在 instanceMethods 中
                                            // 则将 instanceMethods 的方法总数累加到 a 中
    }

    if (proto->classMethods) { // 如果 proto 中存在类方法
        if (isRequiredMethod && !isInstanceMethod) { // 且 m 方法是 required 的，且是类方法
                                                     // 则 m 方法位于第二个方法列表 classMethods 中
            b = proto->classMethods->indexOfMethod(m); // 取得 m 方法在 instanceMethods 列表中的索引，赋值给 b
            return;
        }
        a += proto->classMethods->count; // 如果 m 方法不在 classMethods 中
                                         // 则将 classMethods 的方法总数累加到 a 中
    }

    if (proto->optionalInstanceMethods) { // 如果 proto 中存在可选的实例方法
        if (!isRequiredMethod && isInstanceMethod) { // 且 m 方法是 optional 的，且是实例方法
                                                     // 则 m 方法位于第三个方法列表 optionalInstanceMethods 中
            b = proto->optionalInstanceMethods->indexOfMethod(m);
                                                     // 取得 m 方法在 optionalInstanceMethods 列表中的索引，赋值给 b
            return;
        }
        a += proto->optionalInstanceMethods->count; // 如果 m 方法不在 optionalInstanceMethods 中
                                                    // 则将 optionalInstanceMethods 的方法总数累加到 a 中
    }

    if (proto->optionalClassMethods) { // 如果 proto 中存在可选的类方法
        if (!isRequiredMethod && !isInstanceMethod) { // 且 m 方法是 optional 的，且是类方法
                                                      // 则 m 方法位于第四个方法列表 optionalClassMethods 中
            b = proto->optionalClassMethods->indexOfMethod(m);
                                                      // 取得 m 方法在 optionalClassMethods 列表中的索引，赋值给 b
            
            return;
        }
        a += proto->optionalClassMethods->count; // 如果 m 方法不在 optionalClassMethods 中
                                            // 则将 optionalClassMethods 的方法总数累加到 a 中
        
        // 如果走到这里，说明在协议中没有找到 m 方法，这就尴尬了，
        // 为什么这里没有给 b 赋值呢？不过，好像赋什么值都不大合适
        // 也没有返回值标识有没有找到
    }
}


/***********************************************************************
* getExtendedTypesIndexForMethod
* Returns the index of m's extended types in proto's extended types array.
**********************************************************************/
// 获得 proto 协议中 m 方法的扩展类型位于 扩展类型 数组(extendedMethodTypes)中的索引，
// 内部实际调用的是 getExtendedTypesIndexesForMethod()，详情见 getExtendedTypesIndexesForMethod()
// 调用者：protocol_getMethodTypeEncoding_nolock()
static uint32_t getExtendedTypesIndexForMethod(protocol_t *proto, const method_t *m, bool isRequiredMethod, bool isInstanceMethod)
{
    uint32_t a;
    uint32_t b;
    // 调用 getExtendedTypesIndexesForMethod()
    getExtendedTypesIndexesForMethod(proto, m, isRequiredMethod, 
                                     isInstanceMethod, a, b);
    return a + b;
}


/***********************************************************************
* fixupProtocolMethodList
* Fixes up a single method list in a protocol.
**********************************************************************/
// fix-up 协议中的单独的一个方法列表
static void
fixupProtocolMethodList(protocol_t *proto, method_list_t *mlist,  
                        bool required/*是否必选*/, bool instance/*是否是实例方法*/)
{
    runtimeLock.assertWriting(); // runtimeLock 必须事先加写锁

    if (!mlist) return; // 如果方法列表不存在，就直接返回
    
    if (mlist->isFixedUp()) return; // 如果方法列表已经被 fixup 过了，就不用再 fixup 一次，直接返回，

    // 取得 proto 里是否有扩展方法类型
    bool hasExtendedMethodTypes = proto->hasExtendedMethodTypes();
    
    // 将 mlist 方法列表 fixup 了
    // 第二个参数是 true，表示需要从 bundle 中拷贝
    // 第三个参数是 !hasExtendedMethodTypes，表示如果没有扩展方法类型，就需要排序，否则
    //    底下的代码会负责做排序的工作
    fixupMethodList(mlist, true/*always copy for simplicity*/,
                    !hasExtendedMethodTypes/*sort if no ext*/);
    
    if (hasExtendedMethodTypes) { // 存在扩展方法类型，那么就需要在这里进行排序
        // Sort method list and extended method types together.
        // fixupMethodList() can't do this.
        // fixme COW stomp
        
        // 存在扩展方法类型的方法列表，extendedMethodTypes 里的顺序是需要和几个方法列表中方法的顺序是保持一致的，
        // 即 方法 和 它的扩展类型 必须时刻保持一一对应，所以 extendedMethodTypes 也需要一同排序
        // 因为 fixupMethodList() 做不了这个，所以必须在这里做
        
        uint32_t count = mlist->count; // mlist 中的方法数
        uint32_t prefix; // 用来接收 mlist 之前的所有方法列表中的方法总个数
        uint32_t junk;   // 用来接收 &mlist->get(0) 这个方法位于 mlist 中的索引，其实是废话啦
                         // 摆明了是第一个，因为取到了之后也压根儿没用
        
        // 取得 mlist 之前的所有方法列表中方法的总个数 prefix
        getExtendedTypesIndexesForMethod(proto, &mlist->get(0), 
                                         required, instance, prefix, junk);
        
        // 取得扩展方法类型数组
        const char **types = proto->extendedMethodTypes;
        
        // 那么 mlist 中的方法对应的扩展类型就是：types[prefix+0] ~ types[prefix+count-1]
        
        // 遍历 mlist 中的方法，利用冒泡排序，将 name 地址小的方法排前面，顺便调换扩展类型的位置
        for (uint32_t i = 0; i < count; i++) {
            for (uint32_t j = i+1; j < count; j++) {
                method_t& mi = mlist->get(i);
                method_t& mj = mlist->get(j);
                if (mi.name > mj.name) { // mi.name 的地址 小于 mj.name 的地址，就交换，即地址小的排前面
                    std::swap(mi, mj); // 交换 mi 和 mj 的值
                    std::swap(types[prefix+i], types[prefix+j]); // 交换对应位置上的扩展类型的值
                }
            }
        }
    }
}


/***********************************************************************
* fixupProtocol
* Fixes up all of a protocol's method lists.
**********************************************************************/
// fixup 指定的协议，其实是 fixup 协议里的4个方法列表
// 但是不会检查 proto 原来是否已经被 fixedup，检查的步骤会在 fixupProtocolIfNeeded() 中做
// 调用者：fixupProtocolIfNeeded()
static void 
fixupProtocol(protocol_t *proto)
{
    runtimeLock.assertWriting(); // 需要事先加写锁

    // 如果 proto 协议存在子协议
    if (proto->protocols) {
        // 遍历 proto 协议的子协议
        for (uintptr_t i = 0; i < proto->protocols->count; i++) {
            // 取得每个子协议重映射后的协议
            protocol_t *sub = remapProtocol(proto->protocols->list[i]);
            // 如果该子协议还未被 fixed-up，就将它 fix-up 了
            if (!sub->isFixedUp()) fixupProtocol(sub);
        }
    }

    // 以下逐一 fixup 该协议的 4 个方法列表
    fixupProtocolMethodList(proto, proto->instanceMethods, YES, YES);
    fixupProtocolMethodList(proto, proto->classMethods, YES, NO);
    fixupProtocolMethodList(proto, proto->optionalInstanceMethods, NO, YES);
    fixupProtocolMethodList(proto, proto->optionalClassMethods, NO, NO);

    // fixme memory barrier so we can check this with no lock
    proto->setFixedUp(); // 将该协议设置为已经被 fixed-up
}


/***********************************************************************
* fixupProtocolIfNeeded
* Fixes up all of a protocol's method lists if they aren't fixed up already.
* Locking: write-locks runtimeLock.
**********************************************************************/
// 首先会检查 proto 协议是否是 fixed-up 的，如果不是，会调用 fixupProtocol() 将其 fix-up 了
// 调用者：_protocol_getMethodTypeEncoding() / protocol_copyMethodDescriptionList() / protocol_getMethod()
static void 
fixupProtocolIfNeeded(protocol_t *proto)
{
    runtimeLock.assertUnlocked(); // 确定 runtimeLock 没有加锁，因为 runtimeLock 是不可重入的
                                  // 如果原来是加锁了的，后面再加锁一次，就死锁了
    assert(proto);

    if (!proto->isFixedUp()) { // 如果还没有 fix-up
        rwlock_writer_t lock(runtimeLock); // runtimeLock 加写锁
        fixupProtocol(proto); // 调用 fixupProtocol() 将其 fix-up 了
    }
}

// 取得 proto 协议中指定的方法列表，
// required 和 instance 决定了要获取的是哪个列表
// 调用者：protocol_copyMethodDescriptionList() / protocol_getMethod_nolock()
static method_list_t *
getProtocolMethodList(protocol_t *proto,
                      bool required/*是否必选*/,
                      bool instance/*是否是实例方法*/)
{
    method_list_t **mlistp = nil;
    if (required) {
        if (instance) {
            mlistp = &proto->instanceMethods;
        } else {
            mlistp = &proto->classMethods;
        }
    } else {
        if (instance) {
            mlistp = &proto->optionalInstanceMethods;
        } else {
            mlistp = &proto->optionalClassMethods;
        }
    }

    return *mlistp;
}


/***********************************************************************
* protocol_getMethod_nolock
* Locking: runtimeLock must be held by the caller
**********************************************************************/
// 取得 proto 协议中符合指定条件的方法
// sel: 指定的 SEL
// isRequiredMethod: 是否是 required 的方法，如果不是就是 optional 的
// isInstanceMethod: 是否是实例方法，如果不是，就是类方法
// recursive: 是否递归，即是否去 protocols 子协议列表中递归查找
// 调用者：protocol_getMethod() / protocol_getMethodTypeEncoding_nolock()
static method_t *
protocol_getMethod_nolock(protocol_t *proto, SEL sel, 
                          bool isRequiredMethod, bool isInstanceMethod, 
                          bool recursive)
{
    runtimeLock.assertLocked(); // runtimeLock 必须事先加锁

    if (!proto  ||  !sel) return nil; // proto 和 sel 缺一不可

    assert(proto->isFixedUp()); // proto 必须是经过 fixed-up 的

    // 获得协议中符合条件的一个方法列表
    method_list_t *mlist = 
        getProtocolMethodList(proto, isRequiredMethod, isInstanceMethod);
    if (mlist) { // 如果有符合条件的方法列表，就从该方法列表中找到匹配 sel 的方法
        method_t *m = search_method_list(mlist, sel);
        if (m) return m; // 如果找到了，就将方法返回
    }

    if (recursive  &&  proto->protocols) { // 如果指定了需要递归查找，且该协议确实有子协议
        method_t *m;
        // 遍历子协议
        for (uint32_t i = 0; i < proto->protocols->count; i++) {
            // 先取得该子协议对应重映射后的协议 realProto
            protocol_t *realProto = remapProtocol(proto->protocols->list[i]);
            // 递归调用 protocol_getMethod_nolock 从 realProto 中查找符合条件的方法
            m = protocol_getMethod_nolock(realProto, sel, 
                                          isRequiredMethod, isInstanceMethod, 
                                          true);
            if (m) return m; // 如果找到了，就直接将方法返回，不再继续查找
        }
    }

    return nil; // 最后还找到，就返回 nil
}


/***********************************************************************
* protocol_getMethod
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
// 取得 proto 协议中符合指定条件的方法，调用 protocol_getMethod_nolock() 完成查找
// 但多了 fixup 和 加锁 两个步骤
Method 
protocol_getMethod(protocol_t *proto, SEL sel, bool isRequiredMethod, bool isInstanceMethod, bool recursive)
{
    if (!proto) return nil;
    fixupProtocolIfNeeded(proto); // 检查 proto 协议是否是 fixed-up 的，如果不是，会将其 fix-up 了

    rwlock_reader_t lock(runtimeLock); // runtimeLock 加读锁
    
    // 调用 protocol_getMethod_nolock() 完成查找
    return protocol_getMethod_nolock(proto, sel, isRequiredMethod, 
                                     isInstanceMethod, recursive);
}


/***********************************************************************
* protocol_getMethodTypeEncoding_nolock
* Return the @encode string for the requested protocol method.
* Returns nil if the compiler did not emit any extended @encode data.
* Locking: runtimeLock must be held for writing by the caller
**********************************************************************/
// 取得 proto 协议中符合指定条件的方法的类型字符串，这个是不加锁版本，调用方需要加锁
// 调用者：_protocol_getMethodTypeEncoding()
const char * 
protocol_getMethodTypeEncoding_nolock(protocol_t *proto, SEL sel, 
                                      bool isRequiredMethod, 
                                      bool isInstanceMethod)
{
    runtimeLock.assertLocked();

    if (!proto) return nil; // 协议为空，那还找个屁，直接返回 nil
    
    // 如果协议没有扩展方法类型，直接返回 nil
    if (!proto->hasExtendedMethodTypes()) return nil;

    assert(proto->isFixedUp()); // 协议必须是 fixed-up 的

    // 取得符合指定条件的方法
    method_t *m = 
        protocol_getMethod_nolock(proto, sel, 
                                  isRequiredMethod, isInstanceMethod, false);
    
    if (m) { // 如果存在符合条件的 m 方法
        // 获得 m 方法的扩展类型位于 扩展类型数组(extendedMethodTypes) 中的索引 i
        uint32_t i = getExtendedTypesIndexForMethod(proto, m, 
                                                    isRequiredMethod, 
                                                    isInstanceMethod);
        // 返回 i 索引处的扩展类型字符串
        return proto->extendedMethodTypes[i];
    }

    // No method with that name. Search incorporated protocols(合并的协议，即子协议).
    // 在 proto 协议中找不到匹配的方法，就尝试去它的子协议中找
    
    if (proto->protocols) { // 如果存在子协议列表
        // 遍历子协议列表
        for (uintptr_t i = 0; i < proto->protocols->count; i++) {
            // 递归查找每个子协议
            const char *enc = 
                protocol_getMethodTypeEncoding_nolock(remapProtocol(proto->protocols->list[i]), sel, isRequiredMethod, isInstanceMethod);
            if (enc) return enc; // 找到就返回
        }
    }

    return nil; // 如果子协议里也没有，就返回 nil
}

/***********************************************************************
* _protocol_getMethodTypeEncoding
* Return the @encode string for the requested protocol method.
* Returns nil if the compiler did not emit any extended @encode data.
* Locking: acquires runtimeLock
**********************************************************************/
// 取得 proto 协议中符合指定条件的方法的类型字符串，调用 protocol_getMethodTypeEncoding_nolock() 完成查找，
// 比它多的步骤是 fixup 和 加读锁
const char * 
_protocol_getMethodTypeEncoding(Protocol *proto_gen, SEL sel, 
                                BOOL isRequiredMethod, BOOL isInstanceMethod)
{
    protocol_t *proto = newprotocol(proto_gen); // 强转为 protocol_t * 类型

    if (!proto) return nil;
    fixupProtocolIfNeeded(proto); // 检查 proto 是否是已经 fixed-up 的，如果没有，就将其 fix-up 了

    rwlock_reader_t lock(runtimeLock); // runtimeLock 加读锁
    
    // 调用 protocol_getMethodTypeEncoding_nolock() 完成查找
    return protocol_getMethodTypeEncoding_nolock(proto, sel, 
                                                 isRequiredMethod, 
                                                 isInstanceMethod);
}


/***********************************************************************
* protocol_t::demangledName
* Returns the (Swift-demangled) name of the given protocol.
* Locking: none
**********************************************************************/
// 取得取消重整后的协议名称
const char *
protocol_t::demangledName()
{
    // 断言检查 size 是否正确，如果 size 太小，_demangledName 压根就不存在
    assert(size >= offsetof(protocol_t, _demangledName)+sizeof(_demangledName));
    
    if (! _demangledName) { // _demangledName == nil，即还没有 _demangledName
        
        // 取得 mangledName 对应的 _demangledName，如果它不是 swift 协议，就会返回 nil
        char *de = copySwiftV1DemangledName(mangledName, true/*isProtocol*/);
        
        // 如果 de == nil，即不是 swift 协议，就用 mangledName 代替
        // 所以可以得出结论，普通 oc 协议重整前后的名字是一样的，只有 swift 协议是不一样的
        // 可能原来都没重整名字，后来为了兼容 swift，才加了这个
        // 将 de 存入 _demangledName
        if (! OSAtomicCompareAndSwapPtrBarrier(nil, (void*)(de ?: mangledName),
                                               (void**)&_demangledName)) 
        {
            if (de) free(de); // 如果 de 非空，就将其释放，因为它是在堆中分配的，见 copySwiftV1DemangledName()
        }
    }
    return _demangledName; // 将 _demangledName 返回
}

/***********************************************************************
* protocol_getName
* Returns the (Swift-demangled) name of the given protocol.
* Locking: runtimeLock must not be held by the caller
**********************************************************************/
// 取得协议的名字，是 demangledName，即正常的名字
// #疑问：不明白为什么调用者不能对 runtimeLock 加锁，函数体内也没有再加锁过呀，调用者加了锁好像也没问题啊
const char *
protocol_getName(Protocol *proto)
{
    if (!proto) {
        return "nil"; // 如果 proto 是 nil，就返回 nil
    }
    else {
        return newprotocol(proto)->demangledName(); // 否则，返回 proto 取消重整后的名字
    }
}


/***********************************************************************
* protocol_getInstanceMethodDescription
* Returns the description of a named instance method.
* Locking: runtimeLock must not be held by the caller
**********************************************************************/
// 取得协议中符合条件的方法的 objc_method_description
// 调用者不能对 runtimeLock 加锁，因为 protocol_getMethod 方法中对 runtimeLock 加锁了，
// 而 runtimeLock 是不可重入的，一个线程上二次加锁，会造成死锁
struct objc_method_description 
protocol_getMethodDescription(Protocol *p, SEL aSel, 
                              BOOL isRequiredMethod, BOOL isInstanceMethod)
{
    // 用 protocol_getMethod 查找匹配条件的方法
    Method m = 
        protocol_getMethod(newprotocol(p), aSel, 
                           isRequiredMethod, isInstanceMethod, true);
    
    if (m) {
        return *method_getDescription(m); // 找到了匹配的方法，就取得方法的 objc_method_description，并返回
    }
    else {
        return (struct objc_method_description){nil, nil}; // 否则返回一个空的 objc_method_description
    }
}


/***********************************************************************
* protocol_conformsToProtocol_nolock
* Returns YES if self conforms to other.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
// self 协议是否 conforms to(符合，遵从？) other 协议，
// 按下面代码的意思，就是 self 协议本身以及它的子协议中是否有一个协议与 other 协议的 mangledName 相同，
// 即 other 协议是 self 协议的子集，
// 这是一个递归函数，
// 还是个无锁版本
// 调用者：class_conformsToProtocol() / protocol_conformsToProtocol()
static bool 
protocol_conformsToProtocol_nolock(protocol_t *self, protocol_t *other)
{
    runtimeLock.assertLocked(); // runtimeLock 需要被事先加锁

    if (!self  ||  !other) { // self 和 other 有一个为 nil，那都不可能符合，就返回 NO，停止递归
        return NO;
    }

    // protocols need not be fixed up

    // 如果 self 协议本身 和 other 协议的 mangledName 就相同，就直接返回 YES，停止递归
    if (0 == strcmp(self->mangledName, other->mangledName)) {
        return YES;
    }

    // 否则，接着查 self 的子协议
    
    if (self->protocols) { // 如果存在子协议
        uintptr_t i;
        // 遍历子协议
        for (i = 0; i < self->protocols->count; i++) {
            // 取得重映射后的子协议
            protocol_t *proto = remapProtocol(self->protocols->list[i]);
            // 如果有子协议的 mangledName 和 other 协议的 mangledName 相同，就返回 YES，停止递归
            if (0 == strcmp(other->mangledName, proto->mangledName)) {
                return YES;
            }
            // 递归查找子协议的子协议中是否有符合的
            if (protocol_conformsToProtocol_nolock(proto, other)) {
                return YES;
            }
        }
    }

    return NO; // 找不到就返回 NO
}


/***********************************************************************
* protocol_conformsToProtocol
* Returns YES if self conforms to other.
* Locking: acquires runtimeLock
**********************************************************************/
// protocol_conformsToProtocol_nolock() 的有锁版本
// 调用者：-conformsTo: / protocol_isEqual()
BOOL protocol_conformsToProtocol(Protocol *self, Protocol *other)
{
    rwlock_reader_t lock(runtimeLock); // runtimeLock 上了读锁
    
    return protocol_conformsToProtocol_nolock(newprotocol(self), 
                                              newprotocol(other));
}


/***********************************************************************
* protocol_isEqual
* Return YES if two protocols are equal (i.e. conform to each other)
* Locking: acquires runtimeLock
**********************************************************************/
// 两个协议是否相等，即是否等价
BOOL protocol_isEqual(Protocol *self, Protocol *other)
{
    if (self == other) return YES; // 如果二者地址都一样，那还比什么，直接返回 YES
    
    if (!self  ||  !other) return NO; // 如果其中有一个是 nil，也不用比，肯定不相等，返回 NO

    // 先看 self 是否 conforms to other
    // 再看 other 是否 conforms to self
    // 只有互相 conform ，两个协议才是等价的
    if (!protocol_conformsToProtocol(self, other)) return NO;
    if (!protocol_conformsToProtocol(other, self)) return NO;

    return YES;
}


/***********************************************************************
* protocol_copyMethodDescriptionList
* Returns descriptions of a protocol's methods.
* Locking: acquires runtimeLock
**********************************************************************/
// 返回协议中符合条件的方法列表中所有方法的 descriptions，
// 返回值是一个数组，里面每个元素是一个方法的 objc_method_description，
// outCount 是输出参数，记录了数组中的元素个数
struct objc_method_description *
protocol_copyMethodDescriptionList(Protocol *p, 
                                   BOOL isRequiredMethod, // 是否是 required 方法，与 optional 相对
                                   BOOL isInstanceMethod, // 是否是实例方法，与类方法相对
                                   unsigned int *outCount) // 输出参数，记录了数组中的元素个数
{
    protocol_t *proto = newprotocol(p);
    struct objc_method_description *result = nil;
    unsigned int count = 0;

    if (!proto) { // 如果协议本身就是 nil，没法儿玩，将元素个数置为 0 后，直接返回 nil
        if (outCount) *outCount = 0;
        return nil;
    }

    fixupProtocolIfNeeded(proto);

    rwlock_reader_t lock(runtimeLock); // runtimeLock 加读锁

    // 取出符合条件的方法列表
    method_list_t *mlist = 
        getProtocolMethodList(proto, isRequiredMethod, isInstanceMethod);

    if (mlist) { // 方法列表不为空，即里面有方法
        
        // 在堆中为数组开辟足够的空间，mlist->count + 1 个单位，每个单位 sizeof(struct objc_method_description) 的大小
        // calloc 会将这片内存初始化为 0
        // 疑问：为什么是 mlist->count + 1 个单位呢，多出来的那 1 个单位是干嘛用的
        result = (struct objc_method_description *)
            calloc(mlist->count + 1, sizeof(struct objc_method_description));
        
        // 遍历方法列表，填充 descriptions 数组
        for (const auto& meth : *mlist) {
            result[count].name = meth.name;
            result[count].types = (char *)meth.types;
            count++; // 元素总数加 1
        }
    }

    if (outCount) *outCount = count; // 不等于 0，就将 count 赋值给输出参数 outCount
    
    return result;
}


/***********************************************************************
* protocol_getProperty
* fixme
* Locking: runtimeLock must be held by the caller
**********************************************************************/
// 从 proto 协议中取得指定名称的属性
// 调用者：protocol_getProperty()
static property_t * 
protocol_getProperty_nolock(protocol_t *proto,
                            const char *name, // 属性名
                            bool isRequiredProperty, // 是否是 required 的属性，当前只支持 required 的
                            bool isInstanceProperty) // 是否是实例，当前也只支持实例属性
{
    runtimeLock.assertLocked(); // runtimeLock 需要实现上锁

    // 当前只支持 required 的实例属性，所以，optional 的 或者 非实例属性，都直接返回 nil
    if (!isRequiredProperty  ||  !isInstanceProperty) {
        // Only required instance properties are currently supported
        return nil;
    }

    // 遍历实例属性列表，如果找到属性名为 name 的属性，就将其返回
    property_list_t *plist;
    if ((plist = proto->instanceProperties)) {
        for (auto& prop : *plist) {
            if (0 == strcmp(name, prop.name)) {
                return &prop;
            }
        }
    }

    // proto 协议中没有找到，就去它的子协议中找
    if (proto->protocols) {
        uintptr_t i;
        // 遍历子协议列表，
        for (i = 0; i < proto->protocols->count; i++) {
            // 取得重映射后的子协议
            protocol_t *p = remapProtocol(proto->protocols->list[i]);
            // 递归调用本函数，寻找匹配的属性
            property_t *prop = 
                protocol_getProperty_nolock(p, name, 
                                            isRequiredProperty, 
                                            isInstanceProperty);
            if (prop) return prop;
        }
    }

    return nil;
}

// protocol_getProperty_nolock() 的有锁版本
objc_property_t protocol_getProperty(Protocol *p, const char *name, 
                              BOOL isRequiredProperty, BOOL isInstanceProperty)
{
    if (!p  ||  !name) return nil; // 协议和名字缺一不可

    rwlock_reader_t lock(runtimeLock); // runtimeLock 加读锁
    
    // 调用 protocol_getProperty_nolock() 进行查找的工作
    return (objc_property_t)
        protocol_getProperty_nolock(newprotocol(p), name, 
                                    isRequiredProperty, isInstanceProperty);
}


/***********************************************************************
* protocol_copyPropertyList
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
// 拷贝出协议的 plist 实例属性列表，
// 返回值是数组，元素是属性的地址，outCount 是输出参数，记录属性的个数
// 并不是深拷贝，数组确实是在堆上分配的，但是每个元素指向的属性还是那些属性，
// 调用者：protocol_copyPropertyList()
static property_t **
copyPropertyList(property_list_t *plist, unsigned int *outCount)
{
    property_t **result = nil;
    unsigned int count = 0; // 记录属性的个数

    if (plist) {
        count = plist->count;
    }

    if (count > 0) {
        // 为数组在堆中分配足够大的内存，分配 count+1 个单位，是为了在最后一个单位上存 nil
        // 该数组是以 nil 结尾的
        result = (property_t **)malloc((count+1) * sizeof(property_t *));

        // 遍历属性列表
        count = 0;
        for (auto& prop : *plist) {
            result[count++] = &prop; // 将每个属性的地址存入数组中
        }
        result[count] = nil; // 最后一个元素存 nil
    }

    if (outCount) *outCount = count; // 总数赋值给 outCount
    
    return result;
}

// 拷贝出 proto 协议的实例属性列表，
// 返回值是新的列表，内存不一样，但是列表里记录的属性地址是一模一样的
// outCount 是输出参数，记录了属性的个数
objc_property_t *protocol_copyPropertyList(Protocol *proto, unsigned int *outCount)
{
    if (!proto) { // 如果协议为空，没法儿玩，直接返回 nil
        if (outCount) *outCount = 0;
        return nil;
    }

    rwlock_reader_t lock(runtimeLock); // runtimeLock 加读锁

    // 取得原来的属性列表
    property_list_t *plist = newprotocol(proto)->instanceProperties;
    
    // 调用 copyPropertyList 拷贝出属性列表，并将其返回
    return (objc_property_t *)copyPropertyList(plist, outCount);
}


/***********************************************************************
* protocol_copyProtocolList
* Copies this protocol's incorporated protocols. 
* Does not copy those protocol's incorporated protocols in turn.
* Locking: acquires runtimeLock
**********************************************************************/
// 拷贝出协议中的 incorporated protocols (子协议，也可以称为被合并的协议)
// 并不按顺序拷贝，#疑问：不明白这是什么意思，子协议之间还有顺序？？
// 返回值是一个数组，每个元素是协议的地址
Protocol * __unsafe_unretained * 
protocol_copyProtocolList(Protocol *p,
                          unsigned int *outCount/*输出参数，记录子协议的数量*/)
{
    unsigned int count = 0;
    Protocol **result = nil;
    protocol_t *proto = newprotocol(p); // 强转为 protocol_t 类型
    
    if (!proto) { //如果协议为空，没法儿玩，直接返回 nil
        if (outCount) *outCount = 0;
        return nil;
    }

    rwlock_reader_t lock(runtimeLock); // runtimeLock 加读锁

    if (proto->protocols) {
        count = (unsigned int)proto->protocols->count; // 记录子协议的数量
    }
    if (count > 0) {
        // 为结果数组在堆中分配足够大的内存空间
        result = (Protocol **)malloc((count+1) * sizeof(Protocol *));

        // 遍历 proto->protocols，将子协议一一插入结果数组中
        unsigned int i;
        for (i = 0; i < count; i++) {
            result[i] = (Protocol *)remapProtocol(proto->protocols->list[i]);
        }
        result[i] = nil; // 数组的最后一个元素是 nil
    }

    if (outCount) *outCount = count;
    
    return result;
}


/***********************************************************************
* objc_allocateProtocol
* Creates a new protocol. The protocol may not be used until 
* objc_registerProtocol() is called.
* Returns nil if a protocol with the same name already exists.
* Locking: acquires runtimeLock
**********************************************************************/
// 创建一个新协议，这个协议在 objc_registerProtocol() 调用前是不会被使用的
// 协议不能重名，如果给定的协议名称已经存在了，就返回 nil
// 名字是重整后的名字
Protocol *
objc_allocateProtocol(const char *name)
{
    rwlock_writer_t lock(runtimeLock); // runtimeLock 加写锁

    if (getProtocol(name)) { // 协议不能重名，如果给定的协议名称已经存在了，就返回 nil
        return nil;
    }

    // 为新协议在堆中分配内存，并清零
    protocol_t *result = (protocol_t *)calloc(sizeof(protocol_t), 1);

    // 取得别处定义的一个 objc_class 结构体对象，它被用作未注册的协议的 cls
    extern objc_class OBJC_CLASS_$___IncompleteProtocol;
    Class cls = (Class)&OBJC_CLASS_$___IncompleteProtocol;
    
    // 从 objc_registerProtocol() 函数中可以看到
    // 注册前的协议，它的 cls 是 OBJC_CLASS_$___IncompleteProtocol
    // 注册后的协议，它的 cls 会变成 OBJC_CLASS_$_Protocol
    
    result->initProtocolIsa(cls); // 设置新协议的 isa
    result->size = sizeof(protocol_t); // 新协议的大小
    // fixme mangle the name if it looks swift-y?
    result->mangledName = strdup(name); // 新协议的名字

    // fixme reserve name without installing

    return (Protocol *)result; // 返回新协议
}


/***********************************************************************
* objc_registerProtocol
* Registers a newly-constructed protocol. The protocol is now 
* ready for use and immutable.
* Locking: acquires runtimeLock
**********************************************************************/
// 注册一个新创建的协议
void objc_registerProtocol(Protocol *proto_gen) 
{
    protocol_t *proto = newprotocol(proto_gen); // 强转为 protocol_t *

    rwlock_writer_t lock(runtimeLock); // runtimeLock 加写锁

    // 注册前的 cls，代表不完整的协议
    extern objc_class OBJC_CLASS_$___IncompleteProtocol;
    Class oldcls = (Class)&OBJC_CLASS_$___IncompleteProtocol;
    
    // 注册后的 cls
    extern objc_class OBJC_CLASS_$_Protocol;
    Class cls = (Class)&OBJC_CLASS_$_Protocol;

    if (proto->ISA() == cls) { // 如果协议已经被注册过了，就报警告
        _objc_inform("objc_registerProtocol: protocol '%s' was already "
                     "registered!", proto->nameForLogging());
        return;
    }
    if (proto->ISA() != oldcls) { // 如果协议的 cls 不等于 oldcls，则在 objc_allocateProtocol() 中有错误
        _objc_inform("objc_registerProtocol: protocol '%s' was not allocated "
                     "with objc_allocateProtocol!", proto->nameForLogging());
        return;
    }

    // NOT initProtocolIsa(). The protocol object may already 
    // have been retained and we must preserve that count.
    proto->changeIsa(cls); // 改变协议的 cls，不用 initProtocolIsa() 是为了不改变除 cls 外的其他信息

    // 将协议插入 protocol_map 映射表中
    NXMapKeyCopyingInsert(protocols(), proto->mangledName, proto);
}


/***********************************************************************
* protocol_addProtocol
* Adds an incorporated protocol to another protocol.
* No method enforcement is performed.
* `proto` must be under construction. `addition` must not.
* Locking: acquires runtimeLock
**********************************************************************/
// 添加一个已经注册了的协议到另一个正在构造中的协议里
// 目的协议 proto_gen 必须是正在被构造中(under construction—allocated)，且还未在 runtime 中注册，
// 而被添加的协议 addition_gen 必须是已经注册了的
void 
protocol_addProtocol(Protocol *proto_gen, Protocol *addition_gen) 
{
    protocol_t *proto = newprotocol(proto_gen);
    protocol_t *addition = newprotocol(addition_gen);

    // 未完成的协议的 cls
    extern objc_class OBJC_CLASS_$___IncompleteProtocol;
    Class cls = (Class)&OBJC_CLASS_$___IncompleteProtocol;

    if (!proto_gen) return;
    if (!addition_gen) return;

    rwlock_writer_t lock(runtimeLock); // runtimeLock 加写锁

    // 如果 proto_gen 并不是未完成的协议
    if (proto->ISA() != cls) {
        _objc_inform("protocol_addProtocol: modified protocol '%s' is not "
                     "under construction!", proto->nameForLogging());
        return;
    }
    
    // 如果 addition_gen 并不是已注册的协议
    if (addition->ISA() == cls) {
        _objc_inform("protocol_addProtocol: added protocol '%s' is still "
                     "under construction!", addition->nameForLogging());
        return;        
    }
    
    // 取得 proto_gen 的子协议列表
    protocol_list_t *protolist = proto->protocols;
    
    if (!protolist) { // 如果 proto_gen 还没有子协议列表，就创建一个，大小只够一个元素
        protolist = (protocol_list_t *)
            calloc(1, sizeof(protocol_list_t) 
                             + sizeof(protolist->list[0]));
    }
    else { // 如果 proto_gen 已经存在子协议列表，就重新开辟一块内存，大小比原来能多放一个元素，并将原来列表中的数据拷贝过去
        protolist = (protocol_list_t *)
            realloc(protolist, protocol_list_size(protolist) 
                              + sizeof(protolist->list[0]));
    }

    // 将 addition_gen 协议放在列表末尾
    protolist->list[protolist->count++] = (protocol_ref_t)addition;
    
    // proto_gen 的 protocols 指向新的子协议列表
    proto->protocols = protolist;
}


/***********************************************************************
* protocol_addMethodDescription
* Adds a method to a protocol. The protocol must be under construction.
* Locking: acquires runtimeLock
**********************************************************************/
// 向协议中添加方法，该协议必须是正在构造中(under construction)，未注册的
// 需要指定是哪个方法列表
// 这个是无锁版本
// 调用者：protocol_addMethodDescription()
static void
protocol_addMethod_nolock(method_list_t*& list, // 方法列表的引用，因为是引用，所以下面可以直接赋值，免去了二级指针的麻烦
                          SEL name,
                          const char *types) // 方法类型字符串，又称方法签名
{
    if (!list) { // 如果方法列表为 nil
        // 为其在堆中分配一块内存
        list = (method_list_t *)calloc(sizeof(method_list_t), 1);
        list->entsizeAndFlags = sizeof(list->first); // 列表中元素的大小是第一个元素的大小
        list->setFixedUp(); // 设置该方法列表是已经 fixed-up 的
    }
    else { // 否则为 list 重新分配一块更大的内存，以存放新来的方法
        // 新的 size 比原来多 list->entsize()，即多一个元素的大小
        size_t size = list->byteSize() + list->entsize();
        // 用 realloc 重新分配内存，并将原来的数据拷贝过去
        list = (method_list_t *)realloc(list, size);
    }

    // 取得新的方法列表中，最后一个位置的方法
    method_t& meth = list->get(list->count++);
    meth.name = name; // 名字，即 selector
    meth.types = strdup(types ? types : ""); // 方法类型字符串，需要在堆中深拷贝
    meth.imp = nil; // 因为是协议，所以 imp 为 nil
}


// 向 proto_gen 协议中添加方法，该协议必须是正在构造中(under construction)，未注册的
// 这是有锁的版本
void 
protocol_addMethodDescription(Protocol *proto_gen,
                              SEL name,
                              const char *types, // 方法类型字符串，又称方法签名
                              BOOL isRequiredMethod, // 是否是 required 方法，与 optional 相对
                              BOOL isInstanceMethod) // 是否是实例方法，与类方法相对
{
    protocol_t *proto = newprotocol(proto_gen);

    // proto_gen 必须是正在构造中(under construction)，未注册的协议
    
    // 未完成的协议的 cls 是 OBJC_CLASS_$___IncompleteProtocol
    extern objc_class OBJC_CLASS_$___IncompleteProtocol;
    Class cls = (Class)&OBJC_CLASS_$___IncompleteProtocol;

    if (!proto_gen) return; // proto_gen 为 nil，没得玩，直接返回

    rwlock_writer_t lock(runtimeLock); // runtimeLock 加写锁

    if (proto->ISA() != cls) { // proto_gen 的 cls 不是 OBJC_CLASS_$___IncompleteProtocol
                               // 即它不是未完成的协议，警告，并直接返回
        _objc_inform("protocol_addMethodDescription: protocol '%s' is not "
                     "under construction!", proto->nameForLogging());
        return;
    }

    // 根据 isRequiredMethod 和 isInstanceMethod 确定需要将方法插入到哪个方法列表中
    // 然后调用 protocol_addMethod_nolock() 插入新方法
    if (isRequiredMethod  &&  isInstanceMethod) {
        protocol_addMethod_nolock(proto->instanceMethods, name, types);
    } else if (isRequiredMethod  &&  !isInstanceMethod) {
        protocol_addMethod_nolock(proto->classMethods, name, types);
    } else if (!isRequiredMethod  &&  isInstanceMethod) {
        protocol_addMethod_nolock(proto->optionalInstanceMethods, name,types);
    } else /*  !isRequiredMethod  &&  !isInstanceMethod) */ {
        protocol_addMethod_nolock(proto->optionalClassMethods, name, types);
    }
}


/***********************************************************************
* protocol_addProperty
* Adds a property to a protocol. The protocol must be under construction.
* Locking: acquires runtimeLock
**********************************************************************/
// 向协议中添加一个属性，该协议必须是 under construction 未完成状态
// 这是无锁版本
// 调用者：protocol_addProperty()
static void 
protocol_addProperty_nolock(property_list_t *&plist, // 协议中的属性列表，注意是引用
                            const char *name, // 新属性的名字
                            const objc_property_attribute_t *attrs, // 新属性的特性列表
                            unsigned int count) // 特性列表中元素的数量
{
    if (!plist) { // 如果属性列表为 nil
        // 就在堆中新开辟一个，并清零
        plist = (property_list_t *)calloc(sizeof(property_list_t), 1);
        plist->entsizeAndFlags = sizeof(property_t); // 设置元素的大小
    } else {
        plist = (property_list_t *)
            realloc(plist, sizeof(property_list_t) 
                    + plist->count * plist->entsize());
    }

    property_t& prop = plist->get(plist->count++); // property_list_t 是值类型的，所以直接可以取得最后一个元素
    prop.name = strdup(name); // 深拷贝 name
    // 取得 attrs 对应的特性字符串，并赋给 prop.attributes，该字符串是在堆中分配的
    prop.attributes = copyPropertyAttributeString(attrs, count);
}


// 向协议中添加一个属性，该协议必须是 under construction 未完成状态
// 这是有锁版本
void 
protocol_addProperty(Protocol *proto_gen,
                     const char *name, // 新属性的名字
                     const objc_property_attribute_t *attrs, // 新属性的特性列表
                     unsigned int count, // 特性列表中元素的数量
                     BOOL isRequiredProperty, // 是否是 required 属性，但现在不支持 optional 属性，所以一定是 YES
                     BOOL isInstanceProperty) // 是否是 实例属性，但现在不支持 类属性，所以一定是 YES
{
    protocol_t *proto = newprotocol(proto_gen);

    // 未完成的协议的 cls 是 OBJC_CLASS_$___IncompleteProtocol
    extern objc_class OBJC_CLASS_$___IncompleteProtocol;
    Class cls = (Class)&OBJC_CLASS_$___IncompleteProtocol;

    // 协议和属性名都不能为 nil
    if (!proto) return;
    if (!name) return;

    rwlock_writer_t lock(runtimeLock); // runtimeLock 加写锁

    // 如果 proto 的 cls 不是 OBJC_CLASS_$___IncompleteProtocol，
    // 即它不是 under construction 未完成的协议，就警告，并返回
    if (proto->ISA() != cls) {
        _objc_inform("protocol_addProperty: protocol '%s' is not "
                     "under construction!", proto->nameForLogging());
        return;
    }

    // 当前只支持 required 的实例属性
    if (isRequiredProperty  &&  isInstanceProperty) {
        // 调用 protocol_addProperty_nolock() 函数将新属性添加到 协议的 实例属性列表中
        protocol_addProperty_nolock(proto->instanceProperties, name, attrs, count);
    }
    //else if (isRequiredProperty  &&  !isInstanceProperty) {
    //    protocol_addProperty_nolock(proto->classProperties, name, attrs, count);
    //} else if (!isRequiredProperty  &&  isInstanceProperty) {
    //    protocol_addProperty_nolock(proto->optionalInstanceProperties, name, attrs, count);
    //} else /*  !isRequiredProperty  &&  !isInstanceProperty) */ {
    //    protocol_addProperty_nolock(proto->optionalClassProperties, name, attrs, count);
    //}
}


/***********************************************************************
* objc_getClassList
* Returns pointers to all classes.
* This requires all classes be realized, which is regretfully non-lazy. 很抱歉是非惰性的
* Locking: acquires runtimeLock
**********************************************************************/
// 取得 runtime 中所有已注册的类，但是限制了数量，
// 这个函数会将 runtime 中所有类都 realize 了，因为这是非惰性的，所以会比较慢，
// buffer: 是一个已经分配好内存的数组，用来存储所有已注册的类的指针，
// bufferLen: 分配给 buffer 的内存长度，即 buffer 中最多可以存多少个类的指针，这限制了类的数量，
// 返回值是 runtime 中所有已注册的类的总数，
// 如果 bufferLen 小于总数，则得到的是一个子集
int 
objc_getClassList(Class *buffer, int bufferLen) 
{
    rwlock_writer_t lock(runtimeLock); // runtimeLock 加写锁，因为需要 realize 所有类

    realizeAllClasses(); // 将 runtime 中所有类都 realize 了，因为这是非惰性的，所以会比较慢

    int count;
    Class cls;
    NXHashState state;
    
    NXHashTable *classes = realizedClasses(); // 获得 realized_class_hash 哈希表，里面存了所有已被 realized 的类
    
    int allCount = NXCountHashTable(classes); // realized_class_hash 哈希表中类的总数

    if (!buffer) { // 如果 buffer 压根没分配空间，没地方存结果，就直接返回总数
        return allCount;
    }

    count = 0;
    state = NXInitHashState(classes);
    
    // 遍历 realized_class_hash 哈希表中的所有类，将类的地址逐一放入 buffer 中
    // 插入的数量必须小于分配给 buffer 的空间长度
    while (count < bufferLen  &&  
           NXNextHashState(classes, &state, (void **)&cls))
    {
        buffer[count++] = cls;
    }

    return allCount;
}


/***********************************************************************
* objc_copyClassList
* Returns pointers to all classes.
* This requires all classes be realized, which is regretfully non-lazy.
* 
* outCount may be nil. *outCount is the number of classes returned. 
* If the returned array is not nil, it is nil-terminated and must be 
* freed with free().
* Locking: write-locks runtimeLock
**********************************************************************/
// 拷贝出 runtime 中的所有已注册的类，与 objc_getClassList() 不同的是，没有限制数量，有多少取多少
// 这个函数会将 runtime 中所有类都 realize 了，因为这是非惰性的，所以会比较慢，
// 返回值是一个数组，数组在堆中分配，调用者需要负责释放它，里面的元素是所有类的地址，数组最后一个元素是 nil，
// outCount 是输出参数，记录了数组中类的个数，不包括最后的 nil，
Class *
objc_copyClassList(unsigned int *outCount)
{
    rwlock_writer_t lock(runtimeLock); // runtimeLock 加写锁，因为需要 realize 所有类

    realizeAllClasses(); // 将 runtime 中所有类都 realize 了，因为这是非惰性的，所以会比较慢

    Class *result = nil;
    NXHashTable *classes = realizedClasses(); // 获得 realized_class_hash 哈希表，里面存了所有已被 realized 的类
    unsigned int count = NXCountHashTable(classes);

    if (count > 0) { // realized_class_hash 哈希表里有东西，才从中取
        Class cls;
        NXHashState state = NXInitHashState(classes);
        // 在堆中为 result 开辟足够大的空间，1+count 是为了在末尾放 nil
        result = (Class *)malloc((1+count) * sizeof(Class));
        count = 0;
        // 遍历哈希表，逐个将类放入 result 数组中
        while (NXNextHashState(classes, &state, (void **)&cls)) {
            result[count++] = cls;
        }
        // 数组最后一个元素放 nil
        result[count] = nil;
    }
    
    if (outCount) *outCount = count; // 记录下数组中有多少类
    
    return result;
}


/***********************************************************************
* objc_copyProtocolList
* Returns pointers to all protocols.
* Locking: read-locks runtimeLock
**********************************************************************/
// 拷贝出 runtime 中所有的协议，
// 返回值是一个数组，数组在堆中分配，调用者需要负责释放它，里面的元素是所有协议的地址，数组最后一个元素是 nil，
// outCount 是输出参数，记录了数组中协议的个数，不包括最后的 nil，
Protocol * __unsafe_unretained *
objc_copyProtocolList(unsigned int *outCount) 
{
    rwlock_reader_t lock(runtimeLock); // runtimeLock 加读锁，没有对协议们再做其他的操作，所以只加读锁

    NXMapTable *protocol_map = protocols(); // 取得存储所有协议的映射表

    unsigned int count = NXCountMapTable(protocol_map); // 映射表中的元素数目
    if (count == 0) { // 如果映射表里压根没东西，就直接返回
        if (outCount) *outCount = 0;
        return nil;
    }

    // 给 result 数组在堆中分配足够大的空间，count+1 是为了在末尾放 nil
    Protocol **result = (Protocol **)malloc((count+1) * sizeof(Protocol*));

    unsigned int i = 0;
    Protocol *proto;
    const char *name;
    NXMapState state = NXInitMapState(protocol_map);
    
    // 遍历映射表，逐一将协议放入 result 数组中
    while (NXNextMapState(protocol_map, &state, 
                          (const void **)&name, (const void **)&proto))
    {
        result[i++] = proto;
    }
    
    result[i++] = nil; // 最后一个位置放 nil
    assert(i == count+1);

    if (outCount) *outCount = count; // 记录协议的个数
    
    return result;
}


/***********************************************************************
* objc_getProtocol
* Get a protocol by name, or return nil
* Locking: read-locks runtimeLock
**********************************************************************/
// 根据协议名 name 查找对应的协议，调用 getProtocol() 完成查找，
// 与之不同的是，加了读锁
Protocol *objc_getProtocol(const char *name)
{
    rwlock_reader_t lock(runtimeLock); 
    return getProtocol(name);
}


/***********************************************************************
* class_copyMethodList
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
// 拷贝出 cls 类中的所有方法，
// 返回值是个数组，在堆中分配，里面存了 cls 类中的所有方法的地址，
// outCount 是输出参数，记录了数组中方法的数目
Method *
class_copyMethodList(Class cls, unsigned int *outCount)
{
    unsigned int count = 0;
    Method *result = nil;

    if (!cls) { // cls 为 nil，没法儿玩，直接返回 nil
        if (outCount) *outCount = 0;
        return nil;
    }

    rwlock_reader_t lock(runtimeLock); // runtimeLock 加读锁
    
    assert(cls->isRealized()); // cls 必须是已经被 realized 的

    count = cls->data()->methods.count(); // 取得 cls 类中方法的数目

    if (count > 0) { // cls 中有方法，才进行拷贝
        
        // 为 result 数组在堆中开辟足够大的空间，count+1 是为了在末尾放 nil
        result = (Method *)malloc((count + 1) * sizeof(Method));
        
        // 遍历 cls 类的方法列表数组，将方法逐一插入到 result 数组中
        count = 0;
        for (auto& meth : cls->data()->methods) {
            if (! ignoreSelector(meth.name)) { // 忽略需要被 ingore 的方法
                result[count++] = &meth;
            }
        }
        result[count] = nil; // 最后一个位置放 nil
    }

    if (outCount) *outCount = count; // 记录数组中方法的数目
    
    return result;
}


/***********************************************************************
* class_copyIvarList
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
// 拷贝出 cls 类的所有成员变量，
// 返回值是数组，在堆中分配，里面存了所有成员变量的地址，
// outCount 是输出参数，记录了数组中成员变量的数目
Ivar *
class_copyIvarList(Class cls, unsigned int *outCount)
{
    const ivar_list_t *ivars;
    Ivar *result = nil;
    unsigned int count = 0;

    if (!cls) { // cls 为 nil，没法儿玩，直接返回 nil
        if (outCount) *outCount = 0;
        return nil;
    }

    rwlock_reader_t lock(runtimeLock); // runtimeLock 加读锁

    assert(cls->isRealized()); // cls 必须是已经被 realized 的
    
    // 如果 ro 中有成员变量列表，且列表中有成员变量
    if ((ivars = cls->data()->ro->ivars)  &&  ivars->count) {
        
        // 为 result 数组在堆中开辟足够大的空间，count+1 是为了在末尾放 nil
        result = (Ivar *)malloc((ivars->count+1) * sizeof(Ivar));
        
        // 遍历成员变量列表，将成员变量逐一放入 result 数组中
        for (auto& ivar : *ivars) {
            if (!ivar.offset) continue; // 偏移量为 0，说明是 anonymous bitfield(匿名的位)，
                                        // 不是正常的成员变量，直接忽略
            result[count++] = &ivar;
        }
        
        result[count] = nil; // 最后一个位置放 nil
    }
    
    if (outCount) *outCount = count; // 记录数组中元素的个数
    return result;
}


/***********************************************************************
* class_copyPropertyList. Returns a heap block containing the 
* properties declared in the class, or nil if the class 
* declares no properties. Caller must free the block.
* Does not copy any superclass's properties.
* Locking: read-locks runtimeLock
**********************************************************************/
// 返回 cls 类的所有属性
// 返回值是数组，在堆中分配，里面存了所有属性的地址，因为是堆中分配的，所以调用者需要负责释放，
// outCount 是输出参数，记录了数组中属性的数目
objc_property_t *
class_copyPropertyList(Class cls, unsigned int *outCount)
{
    if (!cls) { // cls 为 nil，没法儿玩，直接返回 nil
        if (outCount) *outCount = 0;
        return nil;
    }

    rwlock_reader_t lock(runtimeLock); // runtimeLock 加读锁

    assert(cls->isRealized()); // cls 必须是已经被 realized 的
    auto rw = cls->data(); // 取得 rw

    property_t **result = nil;
    unsigned int count = rw->properties.count(); // 取得 cls 的属性列表中的属性数目
    
    if (count > 0) { // 列表中确定有属性，才进行拷贝
        
        // 为 result 数组在堆中开辟足够大的空间，count+1 是为了在末尾放 nil
        result = (property_t **)malloc((count + 1) * sizeof(property_t *));

        count = 0;
        
        // 遍历属性列表，将成员变量逐一放入 result 数组中
        for (auto& prop : rw->properties) {
            result[count++] = &prop;
        }
        
        result[count] = nil; // 最后一个位置放 nil
    }

    if (outCount) *outCount = count; // 记录数组中元素的个数
    
    return (objc_property_t *)result;
}


/***********************************************************************
* objc_class::getLoadMethod
* fixme
* Called only from add_class_to_loadable_list.
* Locking: runtimeLock must be read- or write-locked by the caller.
**********************************************************************/
// 取得类的 +load 方法的 imp 
// 调用者：add_class_to_loadable_list()
IMP 
objc_class::getLoadMethod()
{
    runtimeLock.assertLocked(); // runtimeLock 需要事先加锁

    const method_list_t *mlist;

    assert(isRealized()); // 该类必须是 realized 过的
    assert(ISA()->isRealized()); // 元类也必须是 realized 过的
    assert(!isMetaClass()); // 该类不能是元类
    assert(ISA()->isMetaClass()); // 该类的 isa 必须是元类

    mlist = ISA()->data()->ro->baseMethods(); // +load 是类方法，所以存在了元类中，取出元类的 ro 中的方法列表
    if (mlist) {
        for (const auto& meth : *mlist) { // 遍历元类的方法列表，
            const char *name = sel_cname(meth.name);
            if (0 == strcmp(name, "load")) { // 寻找名字叫 "load" 的方法
                return meth.imp; // 如果找到了，就返回该方法的 imp
            }
        }
    }

    return nil; // 找不到就返回 nil
}


/***********************************************************************
* _category_getName
* Returns a category's name.
* Locking: none
**********************************************************************/
// 取得分类的名字，完全理解不了这种函数存在的意义啊....
// 调用者：add_category_to_loadable_list() / call_category_loads() /
//            remove_category_from_loadable_list()
const char *
_category_getName(Category cat)
{
    return cat->name;
}


/***********************************************************************
* _category_getClassName
* Returns a category's class's name
* Called only from add_category_to_loadable_list and 
* remove_category_from_loadable_list for logging purposes.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
// 取得分类所属类的类名
// 调用者：add_category_to_loadable_list() / remove_category_from_loadable_list()
const char *
_category_getClassName(Category cat)
{
    runtimeLock.assertLocked(); // runtimeLock 需要事先加锁
    return remapClass(cat->cls)->nameForLogging(); // 取得 cat->cls 对应的重映射后的类，并取得类名
}


/***********************************************************************
* _category_getClass
* Returns a category's class
* Called only by call_category_loads.
* Locking: read-locks runtimeLock
**********************************************************************/
// 取得分类所属的类
// 调用者：call_category_loads()
Class 
_category_getClass(Category cat)
{
    rwlock_reader_t lock(runtimeLock); // runtimeLock 加读锁
    
    Class result = remapClass(cat->cls); // 取得 cat->cls 对应的重映射后的类
    
    assert(result->isRealized());  // ok for call_category_loads' usage
    return result;
}


/***********************************************************************
* _category_getLoadMethod
* fixme
* Called only from add_category_to_loadable_list
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
// 取得分类的 +load 方法对应的 imp，如果没有 +load 方法，就返回 nil
IMP 
_category_getLoadMethod(Category cat)
{
    runtimeLock.assertLocked(); // runtimeLock 需要事先加锁

    const method_list_t *mlist;

    mlist = cat->classMethods; // 取得分类的类方法列表，因为 +load 也是类方法，位于类方法列表中
    if (mlist) {
        for (const auto& meth : *mlist) { // 遍历类方法列表，查找名为 "load" 的方法
            const char *name = sel_cname(meth.name);
            if (0 == strcmp(name, "load")) {
                return meth.imp; // 如果找到了，就将方法的 imp 返回
            }
        }
    }

    return nil; // 没有 +load 方法，就返回 nil
}


/***********************************************************************
* class_copyProtocolList
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
// 拷贝出 cls 类的协议列表
// 返回值是一个数组，在堆中分配，调用者需要负责释放它，
// 数组中存了 cls 类的所有协议的地址
// outCount 是输出参数，记录了数组中协议的数目，不包括末尾的 nil
Protocol * __unsafe_unretained * 
class_copyProtocolList(Class cls, unsigned int *outCount)
{
    unsigned int count = 0;
    Protocol **result = nil;
    
    if (!cls) { // cls 为 nil，没法儿玩，直接返回 nil
        if (outCount) *outCount = 0;
        return nil;
    }

    rwlock_reader_t lock(runtimeLock); // runtimeLock 加读锁

    assert(cls->isRealized()); // cls 必须是已经 realized 的
    
    count = cls->data()->protocols.count(); // cls 中协议的个数

    if (count > 0) { // 有协议才进行拷贝
        
        // 为 result 数组开辟一块足够大的内存，count+1 是为了在末尾加 nil
        result = (Protocol **)malloc((count+1) * sizeof(Protocol *));

        // 遍历协议列表数组，将协议一一插入到 result 数组中
        count = 0;
        for (const auto& proto : cls->data()->protocols) {
            result[count++] = (Protocol *)remapProtocol(proto); // 插入的是重映射后的协议
        }
        
        result[count] = nil; // 数组最后一个位置放 nil
    }

    if (outCount) *outCount = count; // 记录了数组中协议的数目，不包括末尾的 nil
    
    return result;
}


/***********************************************************************
* _objc_copyClassNamesForImage
* fixme
* Locking: write-locks runtimeLock
**********************************************************************/
// 拷贝出镜像中所有类的名字
// 返回值是一个数组，数组在堆中分配，所以调用者需要负责释放它，
// 数组中存了镜像中所有类的名字字符串的地址，名字是 demangledName，即取消重整的正常点的名字，
// 会忽略 weak-linked 的类，
// outCount 是输出参数，记录了数组中字符串地址的个数
const char **
_objc_copyClassNamesForImage(header_info *hi, unsigned int *outCount)
{
    size_t count, i, shift;
    classref_t *classlist;
    const char **names; // 返回值，是一个数组
    
    // Need to write-lock in case demangledName() needs to realize a class.
    rwlock_writer_t lock(runtimeLock); // runtimeLock 加写锁，因为后面 cls->demangledName(true);
                                       // 指定了 cls 如果没有 realized 的话，就将其 realize 了
    
    // 获得镜像中所有 objective-2.0 类的列表
    classlist = _getObjc2ClassList(hi, &count);
    
    // 为 names 在堆中开辟一块足够大的内存空间，count+1 是为了在末尾放 nil
    names = (const char **)malloc((count+1) * sizeof(const char *));
    
    shift = 0; // 需要移动的格数
    
    // 遍历镜像中的类列表
    for (i = 0; i < count; i++) {
        Class cls = remapClass(classlist[i]); // 取得重映射后的类
        if (cls) {
            // 如果 cls 存在，即它是 live class，就取得它取消重整后的名字
            // 并指定 demangledName() 函数，若该类未被 realized 的话，就将其 realize 了
            // i-shift 是因为，有一些类可能是 weak-linked 的，会被跳过
            names[i-shift] = cls->demangledName(true/*realize*/);
        }
        else { // 忽略 weak-linked 的类
            shift++;  // ignored weak-linked class
        }
    }
    count -= shift; // 总数需要减去被忽略的那些类
    names[count] = nil; // 数组的最后一个位置放 nil

    if (outCount) *outCount = (unsigned int)count; // 记录数组中类的总数
    
    return names;
}


/***********************************************************************
 * _class_getInstanceStart
 * Uses alignedInstanceStart() to ensure that ARR layout strings are
 * interpreted relative to the first word aligned ivar of an object.
 
 #疑问：不明白这是什么意思
 
 * Locking: none
 **********************************************************************/
// 获取类中的实例变量的起始地址
// 调用者：_class_getInstanceStart()
static uint32_t
alignedInstanceStart(Class cls)
{
    assert(cls);
    assert(cls->isRealized()); // cls 类必须是 realized 过的
    
    // 返回 ro->instanceStart，并进行字节对齐
    return (uint32_t)word_align(cls->data()->ro->instanceStart);
}

// 获取类中的实例变量的起始地址，
// 类的实例变量是存在一个结构体里的，见 TestNSObject 里的 struct AXPerson_IMPL
// 结构体中第一个变量是父类对应的结构体，里面存了父类的成员变量，
// 从第二个变量开始才是本类的实例变量，这个函数就是获得这个实例变量的地址
// 调用者：arr_fixup_copied_references() / object_getIvar() / object_setIvar()
uint32_t _class_getInstanceStart(Class cls) {
    return alignedInstanceStart(cls);
}


/***********************************************************************
* saveTemporaryString
* Save a string in a thread-local FIFO buffer. 
* This is suitable for temporary strings generated for logging purposes.
**********************************************************************/
// 存储一个字符串到 TLS 中的队列缓冲区（first in first out）
// 因为是队列的长度是固定的，所以队列中的元素不会存活太长时间，存入的字符串必须尽快使用，不然就被释放了
static void
saveTemporaryString(char *str)
{
    // Fixed-size FIFO. We free the first string, shift 
    // the rest, and add the new string to the end.
    // 用 _objc_fetch_pthread_data() 取得这个线程的 线程数据. 如果 data 不存在，就为 data 开辟一块内存，
    // 用 TLS 存起来， 然后将它返回
    _objc_pthread_data *data = _objc_fetch_pthread_data(true);
    if (data->printableNames[0]) { // 如果 printableNames 数组第一个元素有值
        free(data->printableNames[0]); // 就将其释放
    }
    int last = countof(data->printableNames) - 1; // 取得 printableNames 数组的最后一个索引
    for (int i = 0; i < last; i++) { // 遍历数组，将后面的元素(index>=1)向前挪一个单位
        data->printableNames[i] = data->printableNames[i+1];
    }
    data->printableNames[last] = str; // 将新的 str 放在末尾
}


/***********************************************************************
* objc_class::nameForLogging
* Returns the class's name, suitable for display.
* The returned memory is TEMPORARY. Print it or copy it immediately.
* Locking: none
**********************************************************************/
// 返回类的名字，做了一些处理更适合显示，其实就是类取消重整后的名字，
// 主要针对 swift 类，oc 类重整前后名字是一样的，而 swift 类重整后的名字加了乱七八糟的字符，不好看，
// 取消重整后的名字没有了这些乱七八糟的字符，看上去正常一点
// 返回的 char * 字符串存在临时的队列里，见 saveTemporaryString()，应立即使用或拷贝，否则很快就被释放了
const char *
objc_class::nameForLogging()
{
    // Handle the easy case directly.
    if (isRealized()  ||  isFuture()) { // 如果该类已经被 realized 的 或 是 future 的
        // 则查看类是否已经存了取消重整的名字，如果有，就将取消重整的名字返回
        if (data()->demangledName) return data()->demangledName;
    }

    // 否则只能将 mangledName，重整后的名字处理一下，取得取消重整的名字
    // 其实普通 OC 类，重整前后的名字是一样的，而 swift 类重整前后的名字不一样
    
    char *result;
    
    const char *name = mangledName();
    char *de = copySwiftV1DemangledName(name); // 如果是 swift 类，得到的是取消重整的字符串，如果是 oc 类，得到的 nil
    if (de) {
        result = de;
    }
    else {
        result = strdup(name); // 如果是 oc 类，得到的是 nil，则直接用重整后的名字，所以 oc 类，重整前后的名字是一样的
    }

    saveTemporaryString(result); // 保存 result 字符串到临时的队列里
    
    return result;
}


/***********************************************************************
* objc_class::demangledName
* If realize=false, the class must already be realized or future.
* Locking: If realize=true, runtimeLock must be held for writing by the caller.
**********************************************************************/
// 取得 demangledName 取消重整后的名字
// 如果传入的参数 realize 是 false，那么类必须已经被 realized 或者 future
// 否则就会对类做 realize 操作
// 调用者：_objc_copyClassNamesForImage() / class_getName()
const char *
objc_class::demangledName(bool realize)
{
    // Return previously demangled name if available.
    if (isRealized()  ||  isFuture()) {
        // 如果已经存在，就直接返回它
        if (data()->demangledName) {
            return data()->demangledName;
        }
    }

    // Try demangling the mangled name.
    // 先拿到 mangled 的名字，即重整后的名字
    const char *mangled = mangledName();
    
    // 然后进行 demangled，那么如果它是 swift 类，就会取得取消重整后的名字，否则得到的是 nil
    char *de = copySwiftV1DemangledName(mangled);
    
    // 如果类已经 Realized 或者 future
    if (isRealized()  ||  isFuture()) {
        // Class is already realized or future. 
        // Save demangling result in rw data.
        // We may not own rwlock for writing so use an atomic operation instead.
        
        // 就将 de 拷贝到 class_rw_t 中的 demangledName 所处的内存处
        // 如果 de 是 nil，即本类不是 swift 类，就用 mangled name 代替，
        // 所以普通 oc 类的 mangledName 和 demangledName 是相同的
        if (! OSAtomicCompareAndSwapPtrBarrier(nil, (void*)(de ?: mangled), 
                                               (void**)&data()->demangledName)) 
        {
            // 如果 de 不是空，就将其释放
            if (de) {
                free(de);
            }
        }
        return data()->demangledName; // 返回重整后的名字
    }

    // Class is not yet realized.
    // 类既没有 realized ,也没有 future，才会走到这里
    // 如果 de 是空的，即本类不是 swift 类，因为普通 oc 类的 mangledName 和 demangledName 是相同的
    // 所以直接返回 mangledName 就好了
    if (!de) {
        // Name is not mangled. Return it without caching.
        return mangled;
    }

    // Class is not yet realized and name is mangled. Realize the class.
    // Only objc_copyClassNamesForImage() should get here.
    // 类既没有 realized ,也没有 future，
    // 但是上面拿到的 de 不是空的，说明本类是 swift 类，但是还未 realized or future
    // 只有 _objc_copyClassNamesForImage() 调用本函数，才会走到这里
    
    runtimeLock.assertWriting(); // runtimeLock 需要事先加上写锁
    
    assert(realize); // 确保到这里的时候，传入的 realize 是 true
    
    if (realize) {
        realizeClass((Class)this);  // 对类做 realize 操作
        data()->demangledName = de; // 将 de 赋值给 demangledName
        return de;  // 这里 demangledName 指向了 de，de 会在 class 销毁时一并被释放，所以没有内存泄漏
    } else {
        return de;  // bug - just leak
                    // 见 copySwiftV1DemangledName() 因为 de 在堆中，没有被 free，所以会有内存泄漏
    }
}


/***********************************************************************
* class_getName
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
// 取得类的名字，如果传入的是 nil，返回的是 "nil"
const char *class_getName(Class cls)
{
    // 如果传入的是 nil，则返回 "nil"
    if (!cls) return "nil";
    
    // 如果类既没有 realized 也没有 future，就报错
    assert(cls->isRealized()  ||  cls->isFuture());
    
    // 返回类对象的 demangledName
    return cls->demangledName();
}


/***********************************************************************
* class_getVersion
* fixme
* Locking: none
**********************************************************************/
// 获取类的版本
int 
class_getVersion(Class cls)
{
    if (!cls) return 0;
    
    assert(cls->isRealized());
    
    return cls->data()->version;
}


/***********************************************************************
* class_setVersion
* fixme
* Locking: none
**********************************************************************/
// 设置类的版本
void 
class_setVersion(Class cls, int version)
{
    if (!cls) return;
    assert(cls->isRealized());
    cls->data()->version = version;
}

// 在一个有序的方法列表 list 中，查找 key 对应的方法，用的是二分查找，所以必须保证 list 是有序数组
// 调用者：search_method_list()
static method_t *findMethodInSortedMethodList(SEL key, const method_list_t *list)
{
    assert(list);

    const method_t * const first = &list->first; // 方法列表的第一个元素
    const method_t *base = first; // 基准，会变化
    const method_t *probe; // 探针
    uintptr_t keyValue = (uintptr_t)key;
    uint32_t count;
    
    // 遍历 list，不是逐个遍历的，而是用了二分查找，正是因为列表是有序的，所以才能用二分查找
    // 先看中间的那个元素，中间的元素不匹配，就找右边部分，依次二分下去，直到找到匹配的元素（默认右边是正方向）
    // 找到匹配的元素后，从右往左，找到第一个满足条件的元素
    // count >>= 1 中的 >>= 意思是先将变量 count 的各个二进制位顺序右移1位，最高位补二进制0，然后将这个结果再复制给 count
    //       也就是表示需要寻找的 count 少了一半
    for (count = list->count; count != 0; count >>= 1) {
        probe = base + (count >> 1); // 探针移到 base + (count >> 1) 位置，也就是中间
        uintptr_t probeValue = (uintptr_t)probe->name;// 探针位置的方法的名字，就是方法的 SEL
        if (keyValue == probeValue) { // 如果这个 SEL 与传入的参数 key 一致，就表示匹配上了
            // `probe` is a match.
            // Rewind looking for the *first* occurrence of this value.
            // This is required for correct category overrides.
            // 从 probe 开始往前找，找到第一个方法，这个方法的前一个方法的名字不是 keyValue
            // 也就是找到与 keyValue 同名的第一个方法
            while (probe > first && keyValue == (uintptr_t)probe[-1].name) {
                probe--;
            }
            return (method_t *)probe; // 将方法返回
        }
        if (keyValue > probeValue) {// 因为 SEL 本质上就是 char * 字符串，所以是可以比较地址的
            base = probe + 1; // 基准指向 probe 的下一个单位，找右半边
            count--; // 数量减一
        }
    }
    
    return nil; // 完全没找到，就返回 nil
}

/***********************************************************************
* getMethodNoSuper_nolock
* fixme
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
// 搜索 mlist 列表中名字是 sel 的方法
// 调用者：getMethodNoSuper_nolock() / methodListImplementsAWZ() /
//          methodListImplementsRR() / protocol_getMethod_nolock()
static method_t *search_method_list(const method_list_t *mlist, SEL sel)
{
    // 方法列表是否被 fixedup，因为 fixupMethodList 里做了排序
    int methodListIsFixedUp = mlist->isFixedUp();
    // 方法列表中每个元素的大小是否是期望的大小，就是和 method_t 一样，没有变化。因为后面的指针操作是以 sizeof(method_t) 为单位做的
    // 即每个元素等宽，如果元素大小不相等的话，一定会出问题
    int methodListHasExpectedSize = mlist->entsize() == sizeof(method_t);
    
    // 如果 methodListIsFixedUp 和 methodListHasExpectedSize 都是 1，则列表 mlist 是有序的
    
    // __builtin_expect() 是 GCC (version >= 2.96）提供给程序员使用的，目的是将“分支转移”的信息提供给编译器，这样编译器可以对代码进行优化，以减少指令跳转带来的性能下降
    // methodListIsFixedUp && methodListHasExpectedSize 的结果是否等于 1 ，满足的话，走这个分支
    // 因为绝大多数情况下，都是走这个分支，所以用 __builtin_expect() 来判断可以优化
    if (__builtin_expect(methodListIsFixedUp && methodListHasExpectedSize, 1)) {
        // 查找列表中是否有 sel 对应的方法
        return findMethodInSortedMethodList(sel, mlist);
    } else {
        // Linear search of unsorted method list
        // 如果是未排序的方法列表的话，就只能线性查找了，也就是一个一个按顺序遍历
        for (auto& meth : *mlist) {
            // 如果找到，就返回
            if (meth.name == sel) return &meth;
        }
    }

#if DEBUG
    // sanity-check negative results
    // 如果在 DEBUG 模式下，如果还没找到，并且列表是排好序的，就按顺序遍历列表，如果不幸找到了，那就说明二分查找有错
    if (mlist->isFixedUp()) {
        for (auto& meth : *mlist) {
            if (meth.name == sel) {
                _objc_fatal("linear search worked when binary search did not");
            }
        }
    }
#endif

    return nil;
}

// 在 cls 类中查找 sel 对应的方法，注意不找父类 NoSuper
// 并且返回的是方法 method_t，而不是 IMP
// 因为调用方已经加了锁，所以这里不用加锁
// 调用本函数的函数有：
//  addMethod()
//  getMethod_nolock()
//  lookUpImpOrForward()
//  lookupMethodInClassAndLoadCache()
static method_t *
getMethodNoSuper_nolock(Class cls, SEL sel)
{
    runtimeLock.assertLocked(); // 确定调用方已经正确加锁

    assert(cls->isRealized()); // 确定父类已经是 realized 的
    // fixme nil cls? 
    // fixme nil sel?

    for (auto mlists = cls->data()->methods.beginLists(), // 遍历方法列表数组，
              end = cls->data()->methods.endLists(); // 最后一个列表的末尾
         mlists != end;
         ++mlists)
    {
        // 在当前方法列表中查找是否有对应的方法
        method_t *m = search_method_list(*mlists, sel);
        if (m) {
            return m; // 如果找到了，就将其返回
        }
    }

    return nil; // 找不到就返回 nil
}


/***********************************************************************
* getMethod_nolock
* fixme
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
// 无锁版本的查找 cls 类中 sel 对应方法的函数，里面调用的还是 getMethodNoSuper_nolock() 函数
// 调用者：_class_getMethod()
static method_t *
getMethod_nolock(Class cls, SEL sel)
{
    method_t *m = nil;

    runtimeLock.assertLocked(); // 看 runtimeLock 是否已经被正确得加锁(读锁 or 写锁)

    // fixme nil cls?
    // fixme nil sel?

    assert(cls->isRealized()); // 必须已经被 realize 过

    // 先在 cls 类中找，找不到再在父类中找，一直到根类
    while (cls  &&  ((m = getMethodNoSuper_nolock(cls, sel))) == nil) {
        cls = cls->superclass;
    }

    return m;
}


/***********************************************************************
* _class_getMethod
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
// 静态的内部方法，查找 cls 类中 sel 对应的方法
// 调用者：class_getInstanceMethod()
static Method _class_getMethod(Class cls, SEL sel)
{
    // 加读锁
    rwlock_reader_t lock(runtimeLock);
    // 调用无锁版本查找
    return getMethod_nolock(cls, sel);
}


/***********************************************************************
* class_getInstanceMethod.  Return the instance method for the
* specified class and selector.
**********************************************************************/
// 取得 cls 类的中 sel 对应的方法，注意是 Method(method_t) 类型，并不只是 IMP
// 会先用 lookUpImpOrNil 查找 selector，如果找不到会尝试 resolver，让开发者有机会动态插入 IMP
// 然后调用 _class_getMethod 进行查找
// 调用者：class_getClassMethod()
Method class_getInstanceMethod(Class cls, SEL sel)
{
    //
    if (!cls  ||  !sel) return nil;

    // This deliberately avoids +initialize because it historically did so.

    // This implementation is a bit weird(有点怪) because it's the only place that
    // wants a Method instead of an IMP.

    // 这个实现有点怪，因为它是要 Method(method_t)，而不是 IMP
    
#warning fixme build and search caches
    
    // Search method lists, try method resolver, etc.
    
    // 调用 lookUpImpOrNil，是为了如果找不到的话，就尝试一下 resolver，让开发者有机会动态插入 IMP
    lookUpImpOrNil(cls, sel, nil, 
                   NO/*initialize*/, NO/*cache*/, YES/*resolver*/);

#warning fixme build and search caches

    // 调用 _class_getMethod() 查找，
    // 有意思的是，_class_getMethod() 里面一层层调用最后使用的还是 getMethodNoSuper_nolock() 函数，这和 lookUpImpOrNil 中是一样的
    return _class_getMethod(cls, sel);
}


/***********************************************************************
* log_and_fill_cache
* Log this method call. If the logger permits it, fill the method cache.
* cls is the method whose cache should be filled. 
* implementer is the class that owns the implementation in question.
**********************************************************************/
// 记录缓存日志，并将 sel->imp 对插入 cls 的方法缓存中
// 调用者：lookUpImpOrForward()
static void
log_and_fill_cache(Class cls, IMP imp, SEL sel, id receiver,
                   Class implementer) // implementer 和 cls 现在是一致，不知道以后会怎么样，理解不了
{
#if SUPPORT_MESSAGE_LOGGING
    if (objcMsgLogEnabled) {
        // 记录日志文件，如果失败了，就直接返回
        bool cacheIt = logMessageSend(implementer->isMetaClass(), 
                                      cls->nameForLogging(),
                                      implementer->nameForLogging(), 
                                      sel);
        if (!cacheIt) return;
    }
#endif
    // 将 sel->imp 对插入 cls 的方法缓存中
    cache_fill (cls, sel, imp, receiver);
}


/***********************************************************************
* _class_lookupMethodAndLoadCache.
* Method lookup for dispatchers ONLY. OTHER CODE SHOULD USE lookUpImp().
* This lookup avoids optimistic（开放式） cache scan because the dispatcher 
* already tried that.
 
 这个查找方法的函数只能被 dispatchers （也就是 objc_msgSend、objc_msgSend_stret 等函数）使用
 其他的代码应该使用 lookUpImp() 函数
 这个函数避免了扫描缓存，因为 dispatchers 已经尝试过扫描缓存了，正是因为缓存中没有找到，才调用这个方法找的
**********************************************************************/
// 该方法会在 objc_msgSend 中，当在缓存中没有找到 sel 对应的 IMP 时被调用
// objc-msg-arm.s 文件中 STATIC_ENTRY _objc_msgSend_uncached 里可以找到
// 因为在调用这个方法之前，我们已经是从缓存无法找到这个方法了，所以这个方法避免了再去扫描缓存查找方法的过程，而是直接从方法列表找起。
IMP _class_lookupMethodAndLoadCache3(id obj, SEL sel, Class cls)
{
    return lookUpImpOrForward(cls, sel, obj, 
                              YES/*initialize*/, NO/*cache 不找缓存了*/, YES/*resolver*/);
}


/***********************************************************************
* lookUpImpOrForward.
* The standard IMP lookup. 
* initialize==NO tries to avoid +initialize (but sometimes fails)
* cache==NO skips optimistic unlocked lookup (but uses cache elsewhere)
* Most callers should use initialize==YES and cache==YES.
* inst is an instance of cls or a subclass thereof, or nil if none is known. 
*   If cls is an un-initialized metaclass then a non-nil inst is faster.
* May return _objc_msgForward_impcache. IMPs destined for external use 
*   must be converted to _objc_msgForward or _objc_msgForward_stret.
*   If you don't want forwarding at all, use lookUpImpOrNil() instead.
**********************************************************************/
// 标准的查找 IMP 的函数
// 在 cls 类以及父类中寻找 sel 对应的 IMP，
// initialize == NO 表示尝试避免触发 +initialize (但有时失败)，
// cache == NO 表示跳过 optimistic unlocked lookup，即跳过前面不加锁的部分对缓存的查找，但是在 retry 里加锁的部分还是会优先查找缓存
// 大多数调用者应该用 initialize==YES and cache==YES.
// inst 是这个类的实例，或者它的子类的实例，也可能是 nil，
// 如果这个类是一个不是 initialized 状态的元类，那么 obj 非空的话，会快一点，
// resolver == YES 的话，如果在缓存和方法列表中都没有找到 IMP，就会进行 resolve，尝试动态添加方法
// 有可能返回 _objc_msgForward_impcache。IMPs 被用作外部的使用时（转发？？），一定要转为 _objc_msgForward 或者 _objc_msgForward_stret
// 如果确实不想转发，就用 lookUpImpOrNil() 代替
IMP lookUpImpOrForward(Class cls, SEL sel, id inst, 
                       bool initialize, bool cache, bool resolver)
{
    Class curClass;
    IMP imp = nil;
    Method meth;
    bool triedResolver = NO; // 用来标记是否尝试过 resolver，调用 _class_resolveMethod 后就置为 YES，
                             // 即使再 retry 也不会再 resolver，详情自己在下面找

    runtimeLock.assertUnlocked(); // 确定 runtimeLock 已经解锁

    // Optimistic cache lookup
    if (cache) { // 如果指定了需要在缓存中查找，这时是不加锁的，这是与 retry 部分的缓存查找最大的不同
        imp = cache_getImp(cls, sel); // 就在缓存中找
        if (imp) {
            return imp; // 如果很幸运得在缓存中找到了，就将找到的 IMP 返回，注意哦，有可能找到的是 _objc_msgForward_impcache 函数
                        // 这个函数会进行消息转发
        }
    }

    // 如果 cls 还没被 realized，就将 cls 类 realize 了
    if (!cls->isRealized()) {
        rwlock_writer_t lock(runtimeLock); // runtimeLock 加写锁
        realizeClass(cls); // 将 cls 类 realize 了，realizeClass() 函数里还会顺便把 cls 类的父类和元类也一并 realize 了
                           // 当然这会造成递归，会把 cls 往上的所有没 realize 的祖宗类和 cls类的元类往上所有没有被 realize 的元类都 realize 了
    }

    // 如果 cls 类还不是 initialized 状态，并且指定了需要 initialize 的话，就将它 initialize 了
    if (initialize  &&  !cls->isInitialized()) {
        // 1. 先调用 _class_getNonMetaClass() 取得 cls 的实例类
        //       如果 cls 不是元类的话，_class_getNonMetaClass 返回的就是 cls 本身
        //       如果 cls 是元类，就找到它对应的实例类
        // 2. 对 _class_getNonMetaClass 返回的类进行 initialize，
        //      其中如果父类没有初始化，会将父类也初始化了；其中会有递归，在完成 cls 的初始化工作之前，会将所有祖宗类都完成初始化，
        //      如果有 cls 类或者其中有个祖宗类正在其他线程上被初始化，本线程还会挂起等待，所以这都是串行并且线程安全的，
        //      类的状态会从 未初始化 -> initializing -> initialized
        _class_initialize (_class_getNonMetaClass(cls, inst));
        
        // If sel == initialize, _class_initialize will send +initialize and 
        // then the messenger will send +initialize again after this 
        // procedure finishes. Of course, if this is not being called 
        // from the messenger then it won't happen. 2778172
        
        /*
        这段话是说，如果 sel 本身就是 initialize 方法的话，因为 _class_initialize 中会调用 +initialize 方法，
        所以本函数结束以后，会再一次调用 +initialize 方法，也就是 +initialize 会悲催地走两次。
        
        +initialize 方法的调用与普通方法的调用是一样的，走的都是发送消息的流程。换言之，如果子类没有实现 +initialize 方法，那么继承自父类的实现会被调用；如果一个类的分类实现了 +initialize 方法，那么就会对这个类中的实现造成覆盖。
        
        因此，如果一个子类没有实现 +initialize 方法，那么父类的实现是会被执行多次的。有时候，这可能是你想要的；但如果我们想确保自己的 +initialize 方法只执行一次，避免多次执行可能带来的副作用时，我们可以使用下面的代码来实现：
        
        + (void)initialize {
            if (self == [ClassName self]) {
                // ... do the initialization ...
            }
        }
         
        或者使用：
        
        + (void)initialize {
            static BOOL b = false;
            if (!b) {
                NSLog(@"Person initialize");
                b = true;
            }
        }
        */
    }

    // The lock is held to make method-lookup + cache-fill atomic 
    // with respect to method addition. Otherwise, a category could 
    // be added but ignored indefinitely because the cache was re-filled 
    // with the old value after the cache flush on behalf of the category.
    
    // 这个锁是用来实现 方法查找 + 填充缓存 两个步骤的原子性的,
    // 否则，一个分类被添加进来后有可能被无限期地忽略，
    // 添加分类的时候会清空缓存，见 attachCategories() 函数，而调用 attachCategories() 函数之前都对 runtimeLock 加写锁，
    // 设想下，如果没有 runtimeLock 读写锁的存在，那么就可能会出现下面的情况：
    // 1. 线程 1 method-lookup 方法查找 找到了老的 IMP，
    // 2. 线程 2 attachCategories() 函数中添加完分类并清空方法缓存，
    // 3. 线程 1 cache-fill 将老的 IMP 插进了缓存中
    // 这时，缓存中存的还是老的 IMP，之后 objc_msgSend 函数在缓存中找到的也都是老的 IMP，通过分类添加的新的方法就被忽略了
    
 retry: // 进行 resolve 后，会进行一次 retry，即重新查一次 IMP，如果这回再找不到，就会进行消息转发
    runtimeLock.read(); // runtimeLock 加读锁，原因见上面

    // Ignore GC selectors
    if (ignoreSelector(sel)) { // 查看 sel 是否需要被忽略
        imp = _objc_ignored_method; // 被忽略的 sel，会被分配 _objc_ignored_method 为 IMP，
                                    // 这与 _objc_ignored_method() 的做法是一致的
                                    // _objc_ignored_method 的实现源码也在 objc_msg_arm.s 文件中
        cache_fill(cls, sel, imp, inst); // 将 sel 和 imp(_objc_ignored_method) 插入到缓存中
        goto done; // 就算是已经确定 IMP 了，完成，跳到 done
    }

    // Try this class's cache.

    imp = cache_getImp(cls, sel); // 再在缓存中查找一次，与函数开头的缓存查找不同的是，现在是加了读锁的
    if (imp) {                    // 还有个不同是，这时可能是 retry，即命中的这个 IMP 可能是 resolve 成功时插入到缓存中的
        goto done; // 找到就跳到 done
    }

    // Try this class's method lists.

    meth = getMethodNoSuper_nolock(cls, sel); // 在 cls 类中搜索 sel 对应的方法，NoSuper 即不在 cls 的父类中查找
    if (meth) {
        log_and_fill_cache(cls, meth->imp, sel, inst, cls); // 如果找到了，就将 meth 中的 IMP 和 sel 一并存入缓存
        imp = meth->imp; // 存起来，后面需要返回 imp
        goto done;
    }

    // Try superclass caches and method lists.
    
    // 缓存中没有、cls 类中也没有，只能沿着 cls 类的祖宗类一路向上寻找了

    curClass = cls;
    while ((curClass = curClass->superclass)) { // 先从父类开始找，直到找到 NSObject 类，NSObject 类没有父类，就停止循环了
        // Superclass cache.
        imp = cache_getImp(curClass, sel); // 在 curClass 类的缓存中寻找
        if (imp) {
            if (imp != (IMP)_objc_msgForward_impcache) { // 如果找到了，并且 IMP 不是 _objc_msgForward_impcache
                                                         // 即不是消息转发，就将 IMP 放入 cls 类的方法缓存中
                                                         // 一定要注意哦，是 cls 类的方法缓存，不是 curClass 类的方法缓存
                                                         // 因为我们在为 cls 类寻找 IMP，最后存在 cls 类的方法缓存中，也有利于以后对 cls 类的方法调用，即各自类缓存各自的 IMP，互不干扰，查起来即简单又快
                // Found the method in a superclass. Cache it in this class.
                log_and_fill_cache(cls, imp, sel, inst, curClass);
                goto done;
            }
            else {
                // Found a forward:: entry in a superclass.
                // Stop searching, but don't cache yet; call method 
                // resolver for this class first.
                
                // 找到一个消息转发，就停止寻找，但是不缓存，
                // 先对这个 curClass 类调用 resolver 方法，即 +resolveInstanceMethod 和 +resolveClassMethod
                // 这两个方法可以给程序员动态添加 实例方法 和 类方法 的机会
                break;
            }
        }

        // Superclass method list.
        // 缓存中没找到，就只能在 curClass 类的方法列表中查找
        meth = getMethodNoSuper_nolock(curClass, sel);
        if (meth) { // 如果找到了，就将方法的 IMP 插入 cls 类的方法缓存中，注意，是 cls 类的方法缓存
            log_and_fill_cache(cls, meth->imp, sel, inst, curClass);
            imp = meth->imp; // 保存一下 imp，后面返回用
            goto done;
        }
    }

    // No implementation found. Try method resolver once.

    // 找不到 IMP，尝试一次 resolver，即调用 +resolveInstanceMethod 和 +resolveClassMethod
    // 但是必须指定需要 resolver，并且没有尝试过 resolver，才能进行 resolver
    // retry 最多只会进行一次，即 resolve 只有一次机会，如果还不成功，就进行完整的消息转发
    if (resolver  &&  !triedResolver/*没有尝试过resolver*/) {
        runtimeLock.unlockRead(); // 释放 runtimeLock 的读锁，retry 的时候会再加上读锁
        _class_resolveMethod(cls, sel, inst); // 调用 _class_resolveMethod() 尝试 resolve
        // Don't cache the result; we don't hold the lock so it may have 
        // changed already. Re-do the search from scratch instead.
        // 不缓存结果，我们释放了读锁，所以结果是不可信的，中间过程中很有可能已经有其他的线程修改了它
        // 进行 retry 时，会重新获得读锁，并重新进行搜索
        triedResolver = YES;
        goto retry;
    }

    // No implementation found, and method resolver didn't help. 
    // Use forwarding.

    imp = (IMP)_objc_msgForward_impcache; // 任何方法都失败了，resolve 也失败了，就进行完整的消息转发，返回这个消息转发函数
    cache_fill(cls, sel, imp, inst); // 将 _objc_msgForward_impcache 作为 sel 对应的 IMP 插入到缓存中

 done:
    runtimeLock.unlockRead(); // 释放读锁

    // paranoia: look for ignored selectors with non-ignored implementations
    // sel 必须不能是需要忽略的 SEL，且 imp 必须不是 _objc_ignored_method
    // 因为如果是这种情况，在上面就应该已经返回了，绝不应该走到这里
    assert(!(ignoreSelector(sel)  &&  imp != (IMP)&_objc_ignored_method));

    // paranoia: never let uncached leak out
    // imp 必须不能是 _objc_msgSend_uncached_impcache 函数，绝不能泄漏未命中的缓存
    // 我猜，如果返回 _objc_msgSend_uncached_impcache 的话，因为 _objc_msgSend_uncached_impcache 中会调用 _class_lookupMethodAndLoadCache3() 函数，而 _class_lookupMethodAndLoadCache3() 又会调用 lookUpImpOrForward，即本函数，那么就反反复复死循环了
    // 理解 _objc_msgSend_uncached_impcache 函数需要看 objc_msg_arm.s 中的 STATIC_ENTRY _objc_msgSend_uncached_impcache
    // 它也只在汇编中用到，其他地方并没有用到这个函数
    assert(imp != _objc_msgSend_uncached_impcache);

    return imp;
}


/***********************************************************************
* lookUpImpOrNil.
* Like lookUpImpOrForward, but returns nil instead of _objc_msgForward_impcache
**********************************************************************/
// 查找 IMP，与 lookUpImpOrForward() 类似，
// 但是如果没有找到的话，返回nil，而不是 _objc_msgForward_impcache
// 即不会进行消息转发
IMP lookUpImpOrNil(Class cls, SEL sel, id inst, 
                   bool initialize, bool cache, bool resolver)
{
    // 用的还是 lookUpImpOrForward ，
    IMP imp = lookUpImpOrForward(cls, sel, inst, initialize, cache, resolver);
    // 但是过滤了 _objc_msgForward_impcache 的情况，如果是 _objc_msgForward_impcache，就直接返回 nil
    if (imp == _objc_msgForward_impcache) {
        return nil;
    } else {
        return imp;
    }
}


/***********************************************************************
* lookupMethodInClassAndLoadCache.
* Like _class_lookupMethodAndLoadCache, but does not search superclasses.
* Caches and returns objc_msgForward if the method is not found in the class.
**********************************************************************/
// 在指定 Class 中搜索 sel 对应的 IMP，先在缓存中找，
// 如果没有找到，再在 method list 里找，如果找到，就将 sel-IMP 对放入缓存中，并返回 IMP
// 如果没有找到，就将 sel-_objc_msgForward_impcache 放入缓存中，
// 并返回_objc_msgForward_impcache
// 但是这个函数只用于 object_cxxConstructFromClass() 和 object_cxxDestructFromClass() 两个函数
IMP lookupMethodInClassAndLoadCache(Class cls, SEL sel)
{
    Method meth;
    IMP imp;

    // fixme this is incomplete - no resolver, +initialize, GC - 
    // but it's only used for .cxx_construct/destruct so we don't care
    
    // 这个函数只用于 object_cxxConstructFromClass() 和 object_cxxDestructFromClass() 两个函数
    assert(sel == SEL_cxx_construct  ||  sel == SEL_cxx_destruct);

    // Search cache first.
    // 先搜索 cls 类的缓存中是否有 sel 对应的 imp
    imp = cache_getImp(cls, sel);
    // 如果命中缓存，就直接返回找到的 imp
    if (imp) {
        return imp;
    }

    // Cache miss. Search method list.
    // 加锁
    rwlock_reader_t lock(runtimeLock);

    // 没有命中，就从类的 method list 里找，但不找父类的
    meth = getMethodNoSuper_nolock(cls, sel);

    if (meth) {
        // Hit in method list. Cache it.
        // 找到了，将 sel-imp 对放入 cls 类的 cache 缓存中
        cache_fill(cls, sel, meth->imp, nil);
        return meth->imp;
    } else {
        // Miss in method list. Cache objc_msgForward.
        // 没有找到，就将 sel - _objc_msgForward_impcache 放入 cls 类的 cache 缓存中
        // 可能后面要用到 _objc_msgForward_impcache 进行消息转发
        cache_fill(cls, sel, _objc_msgForward_impcache, nil);
        return _objc_msgForward_impcache;
    }
}


/***********************************************************************
* class_getProperty
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
// 从 cls 类或其祖宗类中寻找指定名字的属性
objc_property_t class_getProperty(Class cls, const char *name)
{
    if (!cls  ||  !name) return nil;

    rwlock_reader_t lock(runtimeLock); // 加读锁，rwlock_reader_t 的 构造函数中会调用 read() 加读锁，
                                       // 在析构函数中会调用 调用 unlockRead() 释放读锁

    assert(cls->isRealized()); // cls 类必须是已经被 realize 过的

    for ( ; cls; cls = cls->superclass) { // 从 cls 类开始一路向上寻找，直到根类（因为根类没有父类）
        for (auto& prop : cls->data()->properties) { // 遍历当前类的 rw 中的属性列表数组，可能因为 for(auto :) 会自动
                                                     // 调用迭代器，所以得到的 prop 的是 objc_property_t 类型，而不是
                                                     // property_list_t
                                                     // #疑问：但是为什么 getMethodNoSuper_nolock 不是这样的呢，存疑，properties 里存的究竟是一个个列表，还是只是一个个属性
                                                     // 在 methodizeClass() 中添加方法、属性和协议都是一样用 attachLists() 呀，让人费解啊，标记一下
            if (0 == strcmp(name, prop.name)) { // 比较属性的名字是否与 name 一样，如果一样，就是找到了
                                                // 因为二者都是 C 字符串，所以用 strcmp 比较
                return (objc_property_t)&prop; // 将找到的属性返回
            }
        }
    }
    
    return nil; // 如果一直到根类还没有找到，就返回 nil
}


/***********************************************************************
* Locking: fixme
**********************************************************************/
// 用于 gdb 调试，
// 根据 cls 的重整后的名称，查找类，
// 在 look_up_class() 中，如果该类没有 realized 就将其 realize 了，
// 调用者：gdb_object_getClass()
Class gdb_class_getClass(Class cls)
{
    const char *className = cls->mangledName();
    if(!className || !strlen(className)) return Nil;
    Class rCls = look_up_class(className, NO, NO);
    return rCls;
}

// 用于 gdb 调试，
// 取得 obj 对象的类
Class gdb_object_getClass(id obj)
{
    if (!obj) return nil;
    return gdb_class_getClass(obj->getIsa());
}


/***********************************************************************
* Locking: write-locks runtimeLock
**********************************************************************/
// 将 cls 设置为已经被 Initialized，
// 里面会做设置是否有自定义 AWZ/RR 的工作，
// 并将 cls 的状态由 Initializing 变为 Initialized
// 调用者：_finishInitializing()
void 
objc_class::setInitialized()
{
    Class metacls;
    Class cls;

    assert(!isMetaClass()); // 本类必须不是元类

    cls = (Class)this;  // 本类本身
    metacls = cls->ISA(); // 本类的元类

    rwlock_reader_t lock(runtimeLock); // 读锁，构造函数中会将 runtimeLock 自动加锁

    // Scan metaclass for custom AWZ.
    // Scan metaclass for custom RR.
    // Scan class for custom RR.
    // Also print custom RR/AWZ because we probably haven't done it yet.

    // Special cases:
    // GC's RR and AWZ are never default.
    // NSObject AWZ class methods are default.
    // NSObject RR instance methods are default.
    // updateCustomRR_AWZ() also knows these special cases.
    // attachMethodLists() also knows these special cases.

    // 扫描元类，查找自定义的 AWZ (allocWithZone)
    // 扫描元类，查找自定义的 RR (Retain/Release)
    // 扫描类，查找自定义 RR
    // 打印自定义 RR/AWZ，因为我们大概没有完成
    
    // 特殊的例子：
    //    GC 的 RR 和 AWZ 从来都不是默认的（不用管，我们也不会用 GC）
    //    NSObject 的 RR 实例方法是默认的
    //    updateCustomRR_AWZ() 和 attachMethodLists() 也知道这些特殊的例子
    
    
    bool inherited; // 自定义的 AWZ 是否是继承来的
    bool metaCustomAWZ = NO; // 记录元类是否有自定的 AWZ
    if (UseGC) {
        // GC is always custom AWZ
        metaCustomAWZ = YES; // GC 一直有自定义的 AWZ
        inherited = NO;
    }
    else if (MetaclassNSObjectAWZSwizzled) { // NSObject 元类中的 AWZ 方法被 swizzle 了
        // Somebody already swizzled NSObject's methods
        // 其他地方已经 swizzle 了 NSObject 的 AWZ 方法，见 objc_class::setHasCustomAWZ()
        metaCustomAWZ = YES; // 记录有自定义 AWZ
        inherited = NO;
    }
    // 如果 metacls 是 NSObject 类的元类
    else if (metacls == classNSObject()->ISA()) {
        // NSObject's metaclass AWZ is default, but we still need to check categories
        // NSObject 的元类中的 AWZ 是默认的，因为 NSObject 元类类是根类，默认的 AWZ 指的就是 NSObject 元类中的 AWZ
        // 但是我们还需要检查分类，万一分类重写了 AWZ
        // 取得元类中存的分类方法列表
        auto& methods = metacls->data()->methods;
        // 遍历每个分类方法数组
        for (auto mlists = methods.beginCategoryMethodLists(), 
                  end = methods.endCategoryMethodLists(metacls); 
             mlists != end;
             ++mlists)
        {
            // 查看这个列表中是否有方法的名字是 allocWithZone/alloc，也就是分类重写了 allocWithZone/alloc
            if (methodListImplementsAWZ(*mlists)) {
                metaCustomAWZ = YES;
                inherited = NO;
                break;
            }
        }
    }
    else if (metacls->superclass->hasCustomAWZ()) {
        // Superclass is custom AWZ, therefore we are too.
        // 父类是自定义的 AWZ，那么本类当然也是
        metaCustomAWZ = YES;
        inherited = YES; // 继承来的
    } 
    else {
        // Not metaclass NSObject.   能进入 else 分支，就说明肯定不是 NSObject 了
        // 遍历方法列表，看是否有方法的名字是 allocWithZone/alloc，因为除了 NSObject 类只能在分类中重写 AWZ 方法外，其他类都可以直接在类中重写 AWZ 方法，
        auto& methods = metacls->data()->methods;
        for (auto mlists = methods.beginLists(),
                  end = methods.endLists(); 
             mlists != end;
             ++mlists)
        {
            if (methodListImplementsAWZ(*mlists)) {
                metaCustomAWZ = YES;
                inherited = NO;
                break;
            }
        }
    }
    
    // 一路查找过来，如果确实没有自定义的 AWZ ，就在元类中记录用的是默认的 AWZ
    if (!metaCustomAWZ) metacls->setHasDefaultAWZ();

    if (PrintCustomAWZ  &&  metaCustomAWZ) metacls->printCustomAWZ(inherited);
    // metacls->printCustomRR();


    // ------- 查找是否有自定的 RR  retain/release
    
    bool clsCustomRR = NO; // 标记是否是自定义 RR
    if (UseGC) { // GC 一直有自定义的 RR
        // GC is always custom RR
        clsCustomRR = YES;
        inherited = NO;
    }
    else if (ClassNSObjectRRSwizzled) { // NSObject 的 RR 被 swizzle 了
        // Somebody already swizzled NSObject's methods
        // 一些地方已经 swizzle 了 NSObject 的 RR 方法，见 objc_class::setHasCustomRR()
        clsCustomRR = YES; // 标记 cls 类用自定义 RR
        inherited = NO;
    }
    if (cls == classNSObject()) { // 如果 cls 是 NSObject 类
        // NSObject's RR is default, but we still need to check categories
        // NSObject 类的 RR 是默认的，但是还需要检查它的分类，因为分类中有可能重写 RR
        auto& methods = cls->data()->methods;
        for (auto mlists = methods.beginCategoryMethodLists(), // 分类方法列表起点
                  end = methods.endCategoryMethodLists(cls);   // 分类方法列表终点
             mlists != end;
             ++mlists)
        {
            // 查找 mlist 中是否有方法重写了 RR
            if (methodListImplementsRR(*mlists)) {
                clsCustomRR = YES;
                inherited = NO;
                break;
            }
        }
    }
    else if (!cls->superclass) { // 如果没有父类，那么就一定有自定义 RR，（自定义 RR 是从 NSObject 继承来的）
        // Custom root class
        clsCustomRR = YES;
        inherited = NO;
    } 
    else if (cls->superclass->hasCustomRR()) { // 如果父类有自定义 RR，那么子类也一定用的是从父类那儿继承来的自定义 RR
        // Superclass is custom RR, therefore we are too.
        clsCustomRR = YES;
        inherited = YES; // 继承来的
    } 
    else {
        // Not class NSObject. 能走到这里，就一定不是 NSObject
        // 遍历所有方法，看是否有方法重写了 RR
        auto& methods = cls->data()->methods;
        for (auto mlists = methods.beginLists(), 
                  end = methods.endLists(); 
             mlists != end;
             ++mlists)
        {
            if (methodListImplementsRR(*mlists)) {
                clsCustomRR = YES;
                inherited = NO;
                break;
            }
        }
    }
    if (!clsCustomRR) cls->setHasDefaultRR(); // 如果确实没有自定义 RR，就在类中记录用的是默认的 RR

    // cls->printCustomAWZ();
    if (PrintCustomRR  &&  clsCustomRR) cls->printCustomRR(inherited);

    // Update the +initialize flags.
    // Do this last. 最后干这事儿 
    
    // 更改元类中的信息，将 RW_INITIALIZING 位置清0，即取消了 initializing 状态，然后将 RW_INITIALIZED 置为 1，即设置当前为 initialized 状态
    metacls->changeInfo(RW_INITIALIZED, RW_INITIALIZING);
}


/***********************************************************************
 * _class_usesAutomaticRetainRelease
 * Returns YES if class was compiled with -fobjc-arc
 **********************************************************************/
// 判断 cls 类是否用了自动引用计数 ARC，
// ARC - Automatic Reference Counting 和 ARR - Automatic Retain Release 应该是一回事儿
// 调用者：arr_fixup_copied_references() / classOrSuperClassesUseARR() /
//           object_getIvar() / object_setIvar()
BOOL _class_usesAutomaticRetainRelease(Class cls)
{
    // 是否使用了 ARC 被记录在 ro 的 flags 中
    return bool(cls->data()->ro->flags & RO_IS_ARR);
}


/***********************************************************************
* Return YES if sel is used by retain/release implementors
**********************************************************************/
// 判断 sel 是否 RR 的 selector
// 调用者：updateCustomRR_AWZ()
static bool 
isRRSelector(SEL sel)
{
    return (sel == SEL_retain          ||  sel == SEL_release              ||  
            sel == SEL_autorelease     ||  sel == SEL_retainCount          ||  
            sel == SEL_tryRetain       ||  sel == SEL_retainWeakReference  ||  
            sel == SEL_isDeallocating  ||  sel == SEL_allowsWeakReference);
}


/***********************************************************************
* Return YES if mlist implements one of the isRRSelector() methods
**********************************************************************/
// 查找 mlist 中是否有方法重写了 RR, 即是否有方法的名字是 RR
// 调用者：objc_class::setInitialized() / prepareMethodLists()
static bool 
methodListImplementsRR(const method_list_t *mlist)
{
    return (search_method_list(mlist, SEL_retain)               ||  
            search_method_list(mlist, SEL_release)              ||  
            search_method_list(mlist, SEL_autorelease)          ||  
            search_method_list(mlist, SEL_retainCount)          ||  
            search_method_list(mlist, SEL_tryRetain)            ||  
            search_method_list(mlist, SEL_isDeallocating)       ||  
            search_method_list(mlist, SEL_retainWeakReference)  ||  
            search_method_list(mlist, SEL_allowsWeakReference));
}


/***********************************************************************
* Return YES if sel is used by alloc or allocWithZone implementors
**********************************************************************/
// 判断 sel 是否是 AWZ 的 selector
// 调用者：updateCustomRR_AWZ()
static bool 
isAWZSelector(SEL sel)
{
    return (sel == SEL_allocWithZone  ||  sel == SEL_alloc);
}


/***********************************************************************
* Return YES if mlist implements one of the isAWZSelector() methods
**********************************************************************/
// 查看 mlist 中，是否有方法实现了 AWZ（allocWithZone/alloc），即是否有方法的名字是 allocWithZone/alloc
static bool 
methodListImplementsAWZ(const method_list_t *mlist)
{
    // 查找 mlist 列表中是否有名字是 SEL_allocWithZone 或 SEL_alloc 的方法
    return (search_method_list(mlist, SEL_allocWithZone)  ||
            search_method_list(mlist, SEL_alloc));
}

// 打印自定义 RR
void 
objc_class::printCustomRR(bool inherited)
{
    assert(PrintCustomRR);
    assert(hasCustomRR());
    _objc_inform("CUSTOM RR:  %s%s%s", nameForLogging(), 
                 isMetaClass() ? " (meta)" : "", 
                 inherited ? " (inherited)" : "");
}

// 打印自定义 AWZ
void 
objc_class::printCustomAWZ(bool inherited)
{
    assert(PrintCustomAWZ);
    assert(hasCustomAWZ());
    _objc_inform("CUSTOM AWZ:  %s%s%s", nameForLogging(), 
                 isMetaClass() ? " (meta)" : "", 
                 inherited ? " (inherited)" : "");
}

// 打印需要 raw isa
void 
objc_class::printRequiresRawIsa(bool inherited)
{
    assert(PrintRawIsa);
    assert(requiresRawIsa());
    _objc_inform("RAW ISA:  %s%s%s", nameForLogging(), 
                 isMetaClass() ? " (meta)" : "", 
                 inherited ? " (inherited)" : "");
}


/***********************************************************************
* Mark this class and all of its subclasses as implementors or 
* inheritors of custom RR (retain/release/autorelease/retainCount)
**********************************************************************/
// 设置本类以及其所有的子类有自定义的 RR，参数 inherited 好像没啥用
// 这是一个递归函数
// 调用者：addSubclass() / prepareMethodLists() / updateCustomRR_AWZ()
void objc_class::setHasCustomRR(bool inherited) 
{
    Class cls = (Class)this;
    
    runtimeLock.assertWriting(); // runtimeLock 需要事先加写锁

    if (hasCustomRR()) return; // 如果已经设置过了，就直接返回
    
    // 遍历它和它的子类
    foreach_realized_class_and_subclass(cls, ^(Class c){
        
        if (c != cls  &&  !c->isInitialized()) { // 如果 c 类还没有被 Initialized
            // Subclass not yet initialized. Wait for setInitialized() to do it
            // fixme short circuit recursion?
            return;
        }
        if (c->hasCustomRR()) { // 如果已经有自定义的 RR
            // fixme short circuit recursion?
            return;
        }

        c->bits.setHasCustomRR(); // 设置 c 类有自定义的 RR

        if (PrintCustomRR) {
            // inherited 好像只在这里用了，感觉。。。。没啥用啊
            c->printCustomRR(inherited  ||  c != cls);
        }
    });
}

/***********************************************************************
* Mark this class and all of its subclasses as implementors or 
* inheritors of custom alloc/allocWithZone:
**********************************************************************/
// 设置本类和其所有的子类有自定义的 AWZ
// 这是一个递归函数
// 调用者：addSubclass() / prepareMethodLists() / updateCustomRR_AWZ()
void objc_class::setHasCustomAWZ(bool inherited) 
{
    Class cls = (Class)this;
    
    runtimeLock.assertWriting(); // runtimeLock 需要事先加写锁

    if (hasCustomAWZ()) return; // 如果已经设置了，就直接返回
    
    // 遍历本类，及其所有子孙类
    foreach_realized_class_and_subclass(cls, ^(Class c){
        if (c != cls  &&  !c->isInitialized()) {
            // Subclass not yet initialized. Wait for setInitialized() to do it
            // fixme short circuit recursion?
            return;
        }
        if (c->hasCustomAWZ()) {
            // fixme short circuit recursion?
            return;
        }

        c->bits.setHasCustomAWZ(); // 设置为有自定义 AWZ

        if (PrintCustomAWZ) c->printCustomAWZ(inherited  ||  c != cls);
    });
}


/***********************************************************************
* Mark this class and all of its subclasses as requiring raw isa pointers
**********************************************************************/
// 设置本类，以及本类的所有子类都必须使用 raw isa pointers
// 参数 inherited 没啥用，只是打印信息的时候用了下，不要深究
// 调用者：_read_images() / addSubclass() / realizeClass()
void objc_class::setRequiresRawIsa(bool inherited) 
{
    Class cls = (Class)this;
    runtimeLock.assertWriting();

    if (requiresRawIsa()) return; // 再确认一下，是否真的需要 raw isa，如果不需要，就不往下干了，直接返回
    
    // 遍历自己和自己的所有子类
    foreach_realized_class_and_subclass(cls, ^(Class c){
        if (c->isInitialized()) {
            _objc_fatal("too late to require raw isa");
            return;
        }
        if (c->requiresRawIsa()) {
            // fixme short circuit recursion?
            return;
        }

        c->bits.setRequiresRawIsa(); // 将每一个类都设为需要 raw isa

        if (PrintRawIsa) c->printRequiresRawIsa(inherited  ||  c != cls);
    });
}


/***********************************************************************
* Update custom RR and AWZ when a method changes its IMP
**********************************************************************/
// 看 cls 中的 meth 方法是否是自定义 RR or AWZ，如果是的话，会做一些处理
// 调用者：_method_setImplementation() / method_exchangeImplementations()
static void
updateCustomRR_AWZ(Class cls, method_t *meth)
{
    // In almost all cases, IMP swizzling does not affect custom RR/AWZ bits. 
    // Custom RR/AWZ search will already find the method whether or not 
    // it is swizzled, so it does not transition from non-custom to custom.
    // 
    // The only cases where IMP swizzling can affect the RR/AWZ bits is 
    // if the swizzled method is one of the methods that is assumed to be 
    // non-custom. These special cases are listed in setInitialized().
    // We look for such cases here.
    
    if (isRRSelector(meth->name)) { // 如果 meth 属于 RR 方法
        
        if ((classNSObject()->isInitialized() // NSObject 类已经被 Initialized
             && classNSObject()->hasCustomRR()) // 且 NSObject 类有自定义 RR
            || ClassNSObjectRRSwizzled) // 或者 NSObject 类的 RR 方法已经被 swizzled 了
        {
            // already custom, nothing would change
            // 则已经是自定义的，不需要做什么修改
            return;
        }

        bool swizzlingNSObject = NO; // 标记是否 swizzle NSObject 类
        
        if (cls == classNSObject()) { // 如果 cls 类是 NSObject 类
            swizzlingNSObject = YES; // 就标记为需要 swizzle NSObject 类
        } else {
            // Don't know the class. 
            // The only special case is class NSObject.
            // 不清楚 cls 类，唯一的特例就是 NSObject 类
            // 遍历 NSObject 类的方法列表
            for (const auto& meth2 : classNSObject()->data()->methods) {
                if (meth == &meth2) { // 当有方法与 meth 地址相同
                    swizzlingNSObject = YES; // 就标记为需要 swizzle NSObject 类
                    break;
                }
            }
        }
        if (swizzlingNSObject) { // 如果需要 swizzle NSObject 类
            if (classNSObject()->isInitialized()) { // 如果 NSObject 类已经被 Initialized 了
                classNSObject()->setHasCustomRR(); // 就设置为有自定义 RR
            } else {
                // NSObject not yet +initialized, so custom RR has not yet 
                // been checked, and setInitialized() will not notice the 
                // swizzle.
                // NSObject 还没有被 Initialized，就先标记一下，
                // 当 NSObject 被 initialize 以后，走到 setInitialized() 函数，里面会接着做处理
                ClassNSObjectRRSwizzled = YES;
            }
        }
    }
    
    else if (isAWZSelector(meth->name)) { // 如果 meth 属于 AWZ 方法
        
        Class metaclassNSObject = classNSObject()->ISA(); // 取得 NSObject 的元类
        
        if ((metaclassNSObject->isInitialized()  // NSObject 类已经被 Initialized（该信息存在元类中）
            && metaclassNSObject->hasCustomAWZ()) // 且 NSObject 元类中有自定义 AWZ 方法
            || MetaclassNSObjectAWZSwizzled) // 或者 NSObject 元类的 AWZ 方法已经被标记需要 swizzled 了
        {
            // already custom, nothing would change
            // 已经是自定义的 AWZ，就什么都不做
            return;
        }

        bool swizzlingNSObject = NO; // 标记是否 swizzle NSObject 元类中的 AWZ 方法
        if (cls == metaclassNSObject) { // 如果 cls 类就是 NSObject 元类，
            swizzlingNSObject = YES; // 就标记需要 swizzle NSObject元类中的 AWZ 方法
        }
        else {
            // Don't know the class. 
            // The only special case is metaclass NSObject.
            // 不清楚 cls 类，唯一的特例就是 NSObject 元类
            // 遍历 NSObject 元类的方法列表
            for (const auto& meth2 : metaclassNSObject->data()->methods) {
                if (meth == &meth2) { // 当有方法与 meth 地址相同
                    swizzlingNSObject = YES; // 就标记为需要 swizzle NSObject 元类中的 AWZ 方法
                    break;
                }
            }
        }
        if (swizzlingNSObject) { // 如果需要 swizzle NSObject 元类中的 AWZ 方法
            if (metaclassNSObject->isInitialized()) { // 如果 NSObject 类已经被 Initialized 了
                                                      // （元类不需要 initialize）
                metaclassNSObject->setHasCustomAWZ(); // 就设置为有自定义 AWZ
            } else {
                // NSObject not yet +initialized, so custom RR has not yet 
                // been checked, and setInitialized() will not notice the 
                // swizzle.
                // NSObject 类还没有被 Initialized，就先标记一下需要 swizzle AWZ 方法，
                // 当 NSObject 类被 initialize 以后，走到 setInitialized() 函数，里面会接着做处理
                MetaclassNSObjectAWZSwizzled = YES;
            }
        }
    }
}


/***********************************************************************
* class_getIvarLayout
* Called by the garbage collector. 
* The class must be nil or already realized. 
* Locking: none
**********************************************************************/
// 取得 cls 类中成员变量的 ivarlayout，
// layout 中记录了哪些是 strong 的 ivar
// 调用者：_objc_dumpHeap() / arr_fixup_copied_references() / object_setIvar()
const uint8_t *
class_getIvarLayout(Class cls)
{
    if (cls) return cls->data()->ro->ivarLayout;
    else return nil;
}


/***********************************************************************
* class_getWeakIvarLayout
* Called by the garbage collector. 
* The class must be nil or already realized. 
* Locking: none
**********************************************************************/
// 取得 cls 类中的成员变量的 weakIvarLayout
// weakIvarLayout 中记录了哪些是 weak 的 ivar
// 调用者：_objc_dumpHeap()
//        arr_fixup_copied_references()
//        gc_fixup_weakreferences
//        objc_weak_layout_for_address()
//        object_getIvar()
//        object_setIvar()
const uint8_t *
class_getWeakIvarLayout(Class cls)
{
    if (cls) return cls->data()->ro->weakIvarLayout;
    else return nil;
}


/***********************************************************************
* class_setIvarLayout
* Changes the class's GC scan layout.
* nil layout means no unscanned ivars
* The class must be under construction.
* fixme: sanity-check layout vs instance size?
* fixme: sanity-check layout vs superclass?
* Locking: acquires runtimeLock
**********************************************************************/
// 设置 cls 类成员变量的 layout
// cls 类必须是 under construction 正在构造中，未完成的类
void
class_setIvarLayout(Class cls, const uint8_t *layout)
{
    if (!cls) return;

    rwlock_writer_t lock(runtimeLock); // runtimeLock 加写锁
    
    // Can only change layout of in-construction classes.
    // note: if modifications to post-construction classes were 
    //   allowed, there would be a race below (us vs. concurrent GC scan)
    
    // cls 类必须是 under construction 正在构造中，未完成的类
    // 如果 cls 类不是 under construction，就警告，并立即返回
    if (!(cls->data()->flags & RW_CONSTRUCTING)) {
        _objc_inform("*** Can't set ivar layout for already-registered "
                     "class '%s'", cls->nameForLogging());
        return;
    }

    // 重新为 rw->ro 在堆中分配空间，使其可写
    class_ro_t *ro_w = make_ro_writeable(cls->data());

    // 尝试释放老的 ivarLayout
    try_free(ro_w->ivarLayout);
    
    // 在堆中深拷贝一份新的 layout，赋值给 ivarLayout
    ro_w->ivarLayout = ustrdupMaybeNil(layout);
}

// SPI:  Instance-specific object layout.
// 指定 cls 类的 ivarLayout 的存取器，存取器是一个函数指针，
// 则取 cls 类的实例对象的 layout 时，就将对象作为参数传入函数，返回值就是 layout，见 _object_getIvarLayout()
void
_class_setIvarLayoutAccessor(Class cls, const uint8_t* (*accessor) (id object) /*函数指针*/) {
    
    if (!cls) return;

    rwlock_writer_t lock(runtimeLock); // runtimeLock 加写锁

    // 重新为 rw->ro 在堆中分配空间，使其可写
    class_ro_t *ro_w = make_ro_writeable(cls->data());

    // FIXME:  this really isn't safe to free if there are instances of this class already.
    // 如果 cls 类已经有实例的话，这非常不安全
    // 如果没有指定有 instance-specific object layout
    if (!(cls->data()->flags
          & RW_HAS_INSTANCE_SPECIFIC_LAYOUT)) {
        try_free(ro_w->ivarLayout); // 就尝试将原来的 ivarLayout 释放
    }
    
    ro_w->ivarLayout = (uint8_t *)accessor; // 将新的 ivarLayout 设为 accessor 存取器函数指针
    
    cls->setInfo(RW_HAS_INSTANCE_SPECIFIC_LAYOUT); // 将 cls 标记为有 instance-specific object layout
}

// 取得 cls 的实例 object 的 layout
const uint8_t *
_object_getIvarLayout(Class cls, id object) 
{
    if (cls) {
        // 取出 layout，里面可能是真的 layout，也可能是存取器的函数指针
        const uint8_t* layout = cls->data()->ro->ivarLayout;
        
        // 如果 cls 标记了有  instance-specific object layout
        // 则 layout 里是存取器的函数指针
        if (cls->data()->flags & RW_HAS_INSTANCE_SPECIFIC_LAYOUT) {
            // 强转为函数指针
            const uint8_t* (*accessor) (id object) = (const uint8_t* (*)(id))layout;
            // 调用存取器函数，得到真的 layout
            layout = accessor(object);
        }
        return layout; // 返回 layout
    }
    return nil;
}

/***********************************************************************
* class_setWeakIvarLayout
* Changes the class's GC weak layout.
* nil layout means no weak ivars
* The class must be under construction.
* fixme: sanity-check layout vs instance size?
* fixme: sanity-check layout vs superclass?
* Locking: acquires runtimeLock
**********************************************************************/
// 设置 cls 类的 weakIvarLayout
// 如果 layout 是 nil，则表示没有 weak 的成员变量
// cls 类必须是 under construction 正在构造中，未完成的（既没有注册）
void
class_setWeakIvarLayout(Class cls, const uint8_t *layout)
{
    if (!cls) return;

    rwlock_writer_t lock(runtimeLock); // runtimeLock 加写锁
    
    // Can only change layout of in-construction classes.
    // note: if modifications to post-construction classes were 
    //   allowed, there would be a race below (us vs. concurrent GC scan)
    
    // cls 类必须是 under construction 正在构造中，未完成的
    // 如果 cls 类不是 under construction 的，就报警告，并直接返回
    if (!(cls->data()->flags & RW_CONSTRUCTING)) {
        _objc_inform("*** Can't set weak ivar layout for already-registered "
                     "class '%s'", cls->nameForLogging());
        return;
    }

    // 重新为 rw->ro 在堆中分配空间，使其可写
    class_ro_t *ro_w = make_ro_writeable(cls->data());

    // 尝试释放原来的 weakIvarLayout
    try_free(ro_w->weakIvarLayout);
    
    // 在堆中深拷贝一份新的 layout，赋值给 weakIvarLayout
    ro_w->weakIvarLayout = ustrdupMaybeNil(layout);
}


/***********************************************************************
* _class_getVariable
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
// 从 cls 及其祖宗类里寻找，名为 name 的成员变量，
// 返回值是成员变量的地址，
// memberOf 是输出参数，代表该成员变量实际是属于哪个类的
Ivar
_class_getVariable(Class cls, const char *name, Class *memberOf)
{
    rwlock_reader_t lock(runtimeLock); // runtimeLock 加读锁

    for ( ; cls; cls = cls->superclass) { // 遍历 cls 类及其祖宗类
        ivar_t *ivar = getIvar(cls, name); // 查找名为 name 的成员变量
        if (ivar) { // 如果找到了
            if (memberOf) *memberOf = cls; // 就记录下该成员变量是属于哪个类的
            return ivar; // 将成员变量返回
        }
    }

    return nil; // 找不到，就返回 nil
}


/***********************************************************************
* class_conformsToProtocol
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
// 判断 cls 类是否遵守 proto_gen 协议
// 调用者：+[NSObject conformsToProtocol:] / -[NSObject conformsToProtocol:] / class_addProtocol()
BOOL class_conformsToProtocol(Class cls, Protocol *proto_gen)
{
    protocol_t *proto = newprotocol(proto_gen);
    
    // 类和协议都不能为 nil，否则默认为不遵守
    if (!cls) return NO;
    if (!proto_gen) return NO;

    rwlock_reader_t lock(runtimeLock); // runtimeLock 加读锁

    assert(cls->isRealized()); // cls 必须是 realized 的

    // 遍历 cls 类遵守的 协议列表数组
    for (const auto& proto_ref : cls->data()->protocols) {
        protocol_t *p = remapProtocol(proto_ref); // 取得重映射后的 p 协议
        // 如果 p 协议 与 proto_gen 协议是同一个，那么 cls 遵守 p 协议就等于遵守 proto_gen 协议
        // 或者 p 协议 遵守 proto_gen 协议，即 p 协议中的一个子协议与 proto_gen 协议相同，也即 proto_gen 协议是 p 协议的子集，那么 cls 遵守 p 协议，就一定遵守 proto_gen 协议
        if (p == proto || protocol_conformsToProtocol_nolock(p, proto)) {
            return YES;
        }
    }

    return NO;
}


/**********************************************************************
* addMethod
* fixme
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static IMP 
addMethod(Class cls, SEL name, IMP imp, const char *types, bool replace)
{
    IMP result = nil;

    runtimeLock.assertWriting();

    assert(types);
    assert(cls->isRealized());

    method_t *m;
    if ((m = getMethodNoSuper_nolock(cls, name))) {
        // already exists
        if (!replace) {
            result = m->imp;
        } else {
            result = _method_setImplementation(cls, m, imp);
        }
    } else {
        // fixme optimize
        method_list_t *newlist;
        newlist = (method_list_t *)calloc(sizeof(*newlist), 1);
        newlist->entsizeAndFlags = 
            (uint32_t)sizeof(method_t) | fixed_up_method_list;
        newlist->count = 1;
        newlist->first.name = name;
        newlist->first.types = strdup(types);
        if (!ignoreSelector(name)) {
            newlist->first.imp = imp;
        } else {
            newlist->first.imp = (IMP)&_objc_ignored_method;
        }

        prepareMethodLists(cls, &newlist, 1, NO, NO);
        cls->data()->methods.attachLists(&newlist, 1);
        flushCaches(cls);

        result = nil;
    }

    return result;
}


BOOL 
class_addMethod(Class cls, SEL name, IMP imp, const char *types)
{
    if (!cls) return NO;

    rwlock_writer_t lock(runtimeLock);
    return ! addMethod(cls, name, imp, types ?: "", NO);
}


IMP 
class_replaceMethod(Class cls, SEL name, IMP imp, const char *types)
{
    if (!cls) return nil;

    rwlock_writer_t lock(runtimeLock);
    return addMethod(cls, name, imp, types ?: "", YES);
}


/***********************************************************************
* class_addIvar
* Adds an ivar to a class.
* Locking: acquires runtimeLock
**********************************************************************/
BOOL 
class_addIvar(Class cls, const char *name, size_t size, 
              uint8_t alignment, const char *type)
{
    if (!cls) return NO;

    if (!type) type = "";
    if (name  &&  0 == strcmp(name, "")) name = nil;

    rwlock_writer_t lock(runtimeLock);

    assert(cls->isRealized());

    // No class variables
    if (cls->isMetaClass()) {
        return NO;
    }

    // Can only add ivars to in-construction classes.
    if (!(cls->data()->flags & RW_CONSTRUCTING)) {
        return NO;
    }

    // Check for existing ivar with this name, unless it's anonymous.
    // Check for too-big ivar.
    // fixme check for superclass ivar too?
    if ((name  &&  getIvar(cls, name))  ||  size > UINT32_MAX) {
        return NO;
    }

    class_ro_t *ro_w = make_ro_writeable(cls->data());

    // fixme allocate less memory here
    
    ivar_list_t *oldlist, *newlist;
    if ((oldlist = (ivar_list_t *)cls->data()->ro->ivars)) {
        size_t oldsize = oldlist->byteSize();
        newlist = (ivar_list_t *)calloc(oldsize + oldlist->entsize(), 1);
        memcpy(newlist, oldlist, oldsize);
        free(oldlist);
    } else {
        newlist = (ivar_list_t *)calloc(sizeof(ivar_list_t), 1);
        newlist->entsizeAndFlags = (uint32_t)sizeof(ivar_t);
    }

    uint32_t offset = cls->unalignedInstanceSize();
    uint32_t alignMask = (1<<alignment)-1;
    offset = (offset + alignMask) & ~alignMask;

    ivar_t& ivar = newlist->get(newlist->count++);
#if __x86_64__
    // Deliberately over-allocate the ivar offset variable. 
    // Use calloc() to clear all 64 bits. See the note in struct ivar_t.
    ivar.offset = (int32_t *)(int64_t *)calloc(sizeof(int64_t), 1);
#else
    ivar.offset = (int32_t *)malloc(sizeof(int32_t));
#endif
    *ivar.offset = offset;
    ivar.name = name ? strdup(name) : nil;
    ivar.type = strdup(type);
    ivar.alignment_raw = alignment;
    ivar.size = (uint32_t)size;

    ro_w->ivars = newlist;
    cls->setInstanceSize((uint32_t)(offset + size));

    // Ivar layout updated in registerClass.

    return YES;
}


/***********************************************************************
* class_addProtocol
* Adds a protocol to a class.
* Locking: acquires runtimeLock
**********************************************************************/
BOOL class_addProtocol(Class cls, Protocol *protocol_gen)
{
    protocol_t *protocol = newprotocol(protocol_gen);

    if (!cls) return NO;
    if (class_conformsToProtocol(cls, protocol_gen)) return NO;

    rwlock_writer_t lock(runtimeLock);

    assert(cls->isRealized());
    
    // fixme optimize
    protocol_list_t *protolist = (protocol_list_t *)
        malloc(sizeof(protocol_list_t) + sizeof(protocol_t *));
    protolist->count = 1;
    protolist->list[0] = (protocol_ref_t)protocol;

    cls->data()->protocols.attachLists(&protolist, 1);

    // fixme metaclass?

    return YES;
}


/***********************************************************************
* class_addProperty
* Adds a property to a class.
* Locking: acquires runtimeLock
**********************************************************************/
static bool 
_class_addProperty(Class cls, const char *name, 
                   const objc_property_attribute_t *attrs, unsigned int count, 
                   bool replace)
{
    if (!cls) return NO;
    if (!name) return NO;

    property_t *prop = class_getProperty(cls, name);
    if (prop  &&  !replace) {
        // already exists, refuse to replace
        return NO;
    } 
    else if (prop) {
        // replace existing
        rwlock_writer_t lock(runtimeLock);
        try_free(prop->attributes);
        prop->attributes = copyPropertyAttributeString(attrs, count);
        return YES;
    }
    else {
        rwlock_writer_t lock(runtimeLock);
        
        assert(cls->isRealized());
        
        property_list_t *proplist = (property_list_t *)
            malloc(sizeof(*proplist));
        proplist->count = 1;
        proplist->entsizeAndFlags = sizeof(proplist->first);
        proplist->first.name = strdup(name);
        proplist->first.attributes = copyPropertyAttributeString(attrs, count);
        
        cls->data()->properties.attachLists(&proplist, 1);
        
        return YES;
    }
}

BOOL 
class_addProperty(Class cls, const char *name, 
                  const objc_property_attribute_t *attrs, unsigned int n)
{
    return _class_addProperty(cls, name, attrs, n, NO);
}

void 
class_replaceProperty(Class cls, const char *name, 
                      const objc_property_attribute_t *attrs, unsigned int n)
{
    _class_addProperty(cls, name, attrs, n, YES);
}


/***********************************************************************
* look_up_class
* Look up a class by name, and realize it.
* Locking: acquires runtimeLock
**********************************************************************/
// 根据 name 查找类，并且如果该类没有 realize 就将其 realize 了
// 调用者 ：gdb_class_getClass() / objc_getClass() / objc_getFutureClass() / objc_lookUpClass()
Class 
look_up_class(const char *name, 
              bool includeUnconnected __attribute__((unused)), 
              bool includeClassHandler __attribute__((unused)))
{
    if (!name) return nil;

    Class result;
    bool unrealized;
    {
        rwlock_reader_t lock(runtimeLock); // 加读锁
        result = getClass(name); // 利用 getClass 函数查找类
        unrealized = result  &&  !result->isRealized(); // 如果找到了类，且类没有被 realize，就标记为 unrealized
    }
    if (unrealized) { // 类存在，且没有被 realize
        rwlock_writer_t lock(runtimeLock); // 加写锁
        realizeClass(result); // 将类 realize 了
    }
    return result;
}


/***********************************************************************
* objc_duplicateClass
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
Class 
objc_duplicateClass(Class original, const char *name, 
                    size_t extraBytes)
{
    Class duplicate;

    rwlock_writer_t lock(runtimeLock);

    assert(original->isRealized());
    assert(!original->isMetaClass());

    duplicate = alloc_class_for_subclass(original, extraBytes);

    duplicate->initClassIsa(original->ISA());
    duplicate->superclass = original->superclass;

    duplicate->cache.initializeToEmpty();

    class_rw_t *rw = (class_rw_t *)calloc(sizeof(*original->data()), 1);
    rw->flags = (original->data()->flags | RW_COPIED_RO | RW_REALIZING);
    rw->version = original->data()->version;
    rw->firstSubclass = nil;
    rw->nextSiblingClass = nil;

    duplicate->bits = original->bits;
    duplicate->setData(rw);

    rw->ro = (class_ro_t *)
        memdup(original->data()->ro, sizeof(*original->data()->ro));
    *(char **)&rw->ro->name = strdup(name);

    rw->methods = original->data()->methods.duplicate();

    // fixme dies when categories are added to the base
    rw->properties = original->data()->properties;
    rw->protocols = original->data()->protocols;

    if (duplicate->superclass) {
        addSubclass(duplicate->superclass, duplicate);
    }

    // Don't methodize class - construction above is correct

    addNamedClass(duplicate, duplicate->data()->ro->name);
    addRealizedClass(duplicate);
    // no: duplicate->ISA == original->ISA
    // addRealizedMetaclass(duplicate->ISA);

    if (PrintConnecting) {
        _objc_inform("CLASS: realizing class '%s' (duplicate of %s) %p %p", 
                     name, original->nameForLogging(), 
                     (void*)duplicate, duplicate->data()->ro);
    }

    duplicate->clearInfo(RW_REALIZING);

    return duplicate;
}

/***********************************************************************
* objc_initializeClassPair
* Locking: runtimeLock must be write-locked by the caller
**********************************************************************/

// &UnsetLayout is the default ivar layout during class construction
static const uint8_t UnsetLayout = 0;

static void objc_initializeClassPair_internal(Class superclass, const char *name, Class cls, Class meta)
{
    runtimeLock.assertWriting();

    class_ro_t *cls_ro_w, *meta_ro_w;

    cls->cache.initializeToEmpty();
    meta->cache.initializeToEmpty();
    
    cls->setData((class_rw_t *)calloc(sizeof(class_rw_t), 1));
    meta->setData((class_rw_t *)calloc(sizeof(class_rw_t), 1));
    cls_ro_w   = (class_ro_t *)calloc(sizeof(class_ro_t), 1);
    meta_ro_w  = (class_ro_t *)calloc(sizeof(class_ro_t), 1);
    cls->data()->ro = cls_ro_w;
    meta->data()->ro = meta_ro_w;

    // Set basic info

    cls->data()->flags = RW_CONSTRUCTING | RW_COPIED_RO | RW_REALIZED | RW_REALIZING;
    meta->data()->flags = RW_CONSTRUCTING | RW_COPIED_RO | RW_REALIZED | RW_REALIZING;
    cls->data()->version = 0;
    meta->data()->version = 7;

    cls_ro_w->flags = 0;
    meta_ro_w->flags = RO_META;
    if (!superclass) {
        cls_ro_w->flags |= RO_ROOT;
        meta_ro_w->flags |= RO_ROOT;
    }
    if (superclass) {
        cls_ro_w->instanceStart = superclass->unalignedInstanceSize();
        meta_ro_w->instanceStart = superclass->ISA()->unalignedInstanceSize();
        cls->setInstanceSize(cls_ro_w->instanceStart);
        meta->setInstanceSize(meta_ro_w->instanceStart);
    } else {
        cls_ro_w->instanceStart = 0;
        meta_ro_w->instanceStart = (uint32_t)sizeof(objc_class);
        cls->setInstanceSize((uint32_t)sizeof(id));  // just an isa
        meta->setInstanceSize(meta_ro_w->instanceStart);
    }

    cls_ro_w->name = strdup(name);
    meta_ro_w->name = strdup(name);

    cls_ro_w->ivarLayout = &UnsetLayout;
    cls_ro_w->weakIvarLayout = &UnsetLayout;

    // Connect to superclasses and metaclasses
    cls->initClassIsa(meta);
    if (superclass) {
        meta->initClassIsa(superclass->ISA()->ISA());
        cls->superclass = superclass;
        meta->superclass = superclass->ISA();
        addSubclass(superclass, cls);
        addSubclass(superclass->ISA(), meta);
    } else {
        meta->initClassIsa(meta);
        cls->superclass = Nil;
        meta->superclass = cls;
        addSubclass(cls, meta);
    }
}


/***********************************************************************
* verifySuperclass
* Sanity-check the superclass provided to 
* objc_allocateClassPair, objc_initializeClassPair, or objc_readClassPair.
**********************************************************************/
bool
verifySuperclass(Class superclass, bool rootOK)
{
    if (!superclass) {
        // Superclass does not exist.
        // If subclass may be a root class, this is OK.
        // If subclass must not be a root class, this is bad.
        return rootOK;
    }

    // Superclass must be realized.
    if (! superclass->isRealized()) return false;

    // Superclass must not be under construction.
    if (superclass->data()->flags & RW_CONSTRUCTING) return false;

    return true;
}


/***********************************************************************
* objc_initializeClassPair
**********************************************************************/
Class objc_initializeClassPair(Class superclass, const char *name, Class cls, Class meta)
{
    rwlock_writer_t lock(runtimeLock);

    // Fail if the class name is in use.
    // Fail if the superclass isn't kosher.
    if (getClass(name)  ||  !verifySuperclass(superclass, true/*rootOK*/)) {
        return nil;
    }

    objc_initializeClassPair_internal(superclass, name, cls, meta);

    return cls;
}


/***********************************************************************
* objc_allocateClassPair
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
Class objc_allocateClassPair(Class superclass, const char *name, 
                             size_t extraBytes)
{
    Class cls, meta;

    rwlock_writer_t lock(runtimeLock);

    // Fail if the class name is in use.
    // Fail if the superclass isn't kosher.
    if (getClass(name)  ||  !verifySuperclass(superclass, true/*rootOK*/)) {
        return nil;
    }

    // Allocate new classes.
    cls  = alloc_class_for_subclass(superclass, extraBytes);
    meta = alloc_class_for_subclass(superclass, extraBytes);

    // fixme mangle the name if it looks swift-y?
    objc_initializeClassPair_internal(superclass, name, cls, meta);

    return cls;
}


/***********************************************************************
* objc_registerClassPair
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
void objc_registerClassPair(Class cls)
{
    rwlock_writer_t lock(runtimeLock);

    if ((cls->data()->flags & RW_CONSTRUCTED)  ||  
        (cls->ISA()->data()->flags & RW_CONSTRUCTED)) 
    {
        _objc_inform("objc_registerClassPair: class '%s' was already "
                     "registered!", cls->data()->ro->name);
        return;
    }

    if (!(cls->data()->flags & RW_CONSTRUCTING)  ||  
        !(cls->ISA()->data()->flags & RW_CONSTRUCTING))
    {
        _objc_inform("objc_registerClassPair: class '%s' was not "
                     "allocated with objc_allocateClassPair!", 
                     cls->data()->ro->name);
        return;
    }

    // Build ivar layouts
    if (UseGC) {
        Class supercls = cls->superclass;
        class_ro_t *ro_w = (class_ro_t *)cls->data()->ro;

        if (ro_w->ivarLayout != &UnsetLayout) {
            // Class builder already called class_setIvarLayout.
        }
        else if (!supercls) {
            // Root class. Scan conservatively (should be isa ivar only).
            ro_w->ivarLayout = nil;
        }
        else if (ro_w->ivars == nil) {
            // No local ivars. Use superclass's layouts.
            ro_w->ivarLayout = 
                ustrdupMaybeNil(supercls->data()->ro->ivarLayout);
        }
        else {
            // Has local ivars. Build layouts based on superclass.
            layout_bitmap bitmap = 
                layout_bitmap_create(supercls->data()->ro->ivarLayout, 
                                     supercls->unalignedInstanceSize(), 
                                     cls->unalignedInstanceSize(), NO);
            for (const auto& ivar : *ro_w->ivars) {
                if (!ivar.offset) continue;  // anonymous bitfield

                layout_bitmap_set_ivar(bitmap, ivar.type, *ivar.offset);
            }
            ro_w->ivarLayout = layout_string_create(bitmap);
            layout_bitmap_free(bitmap);
        }

        if (ro_w->weakIvarLayout != &UnsetLayout) {
            // Class builder already called class_setWeakIvarLayout.
        }
        else if (!supercls) {
            // Root class. No weak ivars (should be isa ivar only).
            ro_w->weakIvarLayout = nil;
        }
        else if (ro_w->ivars == nil) {
            // No local ivars. Use superclass's layout.
            ro_w->weakIvarLayout = 
                ustrdupMaybeNil(supercls->data()->ro->weakIvarLayout);
        }
        else {
            // Has local ivars. Build layout based on superclass.
            // No way to add weak ivars yet.
            ro_w->weakIvarLayout = 
                ustrdupMaybeNil(supercls->data()->ro->weakIvarLayout);
        }
    }

    // Clear "under construction" bit, set "done constructing" bit
    cls->ISA()->changeInfo(RW_CONSTRUCTED, RW_CONSTRUCTING | RW_REALIZING);
    cls->changeInfo(RW_CONSTRUCTED, RW_CONSTRUCTING | RW_REALIZING);

    // Add to named and realized classes
    addNamedClass(cls, cls->data()->ro->name);
    addRealizedClass(cls);
    addRealizedMetaclass(cls->ISA());
}


/***********************************************************************
* objc_readClassPair()
* Read a class and metaclass as written by a compiler.
* Assumes the class and metaclass are not referenced by other things 
* that might need to be fixed up (such as categories and subclasses).
* Does not call +load.
* Returns the class pointer, or nil.
*
* Locking: runtimeLock acquired by map_images
**********************************************************************/
Class objc_readClassPair(Class bits, const struct objc_image_info *info)
{
    rwlock_writer_t lock(runtimeLock);

    // No info bits are significant yet.
    (void)info;

    // Fail if the class name is in use.
    // Fail if the superclass isn't kosher.
    const char *name = bits->mangledName();
    bool rootOK = bits->data()->flags & RO_ROOT;
    if (getClass(name) || !verifySuperclass(bits->superclass, rootOK)){
        return nil;
    }

    Class cls = readClass(bits, false/*bundle*/, false/*shared cache*/);
    if (cls != bits) {
        // This function isn't allowed to remap anything.
        _objc_fatal("objc_readClassPair for class %s changed %p to %p", 
                    cls->nameForLogging(), bits, cls);
    }
    realizeClass(cls);

    return cls;
}


/***********************************************************************
* detach_class
* Disconnect a class from other data structures.
* Exception: does not remove the class from the +load list
* Call this before free_class.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
// 断开一个类和其他数据结构的连接
// 异常：不要将这个类从 +load 列表中移除（#疑问：什么意思？？）
// 必须在 free_class 前被调用，见 _unload_image()
// 调用者：_unload_image() / objc_disposeClassPair()
static void detach_class(Class cls, bool isMeta)
{
    runtimeLock.assertWriting(); // runtimeLock 需要事先加上写锁

    // categories not yet attached to this class
    removeAllUnattachedCategoriesForClass(cls); // 移除 cls 的所有未 attach 的分类（无论是否 load）

    // superclass's subclass list
    if (cls->isRealized()) { // 如果类已经 realize，那么类中就存了父类的信息，需要将这些有关父类的信息移除
        Class supercls = cls->superclass; // 取得父类
        if (supercls) { // 如果有父类，就将 cls 类从父类中移除
            removeSubclass(supercls, cls);
        }
    }

    // class tables and +load queue
    if (!isMeta) { // 如果不是元类，
        removeNamedClass(cls, cls->mangledName()); // 则将 cls 类从 gdb_objc_realized_classes 列表中移除
        removeRealizedClass(cls); // 将 cls 类从 realized_class_hash 哈希表中移除
    } else {
        removeRealizedMetaclass(cls); // 如果是元类，则将 cls 从 realized_metaclass_hash 哈希表中移除
    }
}


/***********************************************************************
* free_class
* Frees a class's data structures.
* Call this after detach_class.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
// 释放一个类
// 必须在 detach_class() 之后被调用，比如 _unload_image() 中就是这么做的
// 调用者：_unload_image() / objc_disposeClassPair()
static void free_class(Class cls)
{
    runtimeLock.assertWriting();

    if (! cls->isRealized()) return; // 如果 cls 还未 realize，就不必销毁，因为类里啥都没有

    auto rw = cls->data(); // 取得 rw
    auto ro = rw->ro; // 取得 ro

    cache_delete(cls); // 删除 cls 类的方法缓存
    
    for (auto& meth : rw->methods) { // 遍历 rw 中的方法
        try_free(meth.types); // 将方法中的 types 变量释放，因为那是在堆中分配的
    }
    rw->methods.tryFree(); // 将方法列表数组整个释放了，那么其中的所有方法也一同被释放了
    
    const ivar_list_t *ivars = ro->ivars; // 取得 ro 中的成员变量列表
    if (ivars) { // 如果成员变量列表存在
        for (auto& ivar : *ivars) { // 遍历成员变量列表，释放每个成员变量的 offset、name、type 字段
            try_free(ivar.offset);
            try_free(ivar.name);
            try_free(ivar.type);
        }
        try_free(ivars); // 将整个成员列表释放
    }

    for (auto& prop : rw->properties) { // 遍历 rw 中的属性，释放每个属性的 name、attributes 字段
        try_free(prop.name);
        try_free(prop.attributes);
    }
    rw->properties.tryFree(); // 将整个属性列表数组释放

    rw->protocols.tryFree(); // 将协议列表数组释放
    
    try_free(ro->ivarLayout);  // 下面释放 ro 中的 ivarLayout、weakIvarLayout、name 字段
    try_free(ro->weakIvarLayout);
    try_free(ro->name);
    
    try_free(ro);  // 释放 ro
    try_free(rw);  // 释放 rw
    try_free(cls); // 最后将 cls 类本身也释放了
}


void objc_disposeClassPair(Class cls)
{
    rwlock_writer_t lock(runtimeLock);

    if (!(cls->data()->flags & (RW_CONSTRUCTED|RW_CONSTRUCTING))  ||  
        !(cls->ISA()->data()->flags & (RW_CONSTRUCTED|RW_CONSTRUCTING))) 
    {
        // class not allocated with objc_allocateClassPair
        // disposing still-unregistered class is OK!
        _objc_inform("objc_disposeClassPair: class '%s' was not "
                     "allocated with objc_allocateClassPair!", 
                     cls->data()->ro->name);
        return;
    }

    if (cls->isMetaClass()) {
        _objc_inform("objc_disposeClassPair: class '%s' is a metaclass, "
                     "not a class!", cls->data()->ro->name);
        return;
    }

    // Shouldn't have any live subclasses.
    if (cls->data()->firstSubclass) {
        _objc_inform("objc_disposeClassPair: class '%s' still has subclasses, "
                     "including '%s'!", cls->data()->ro->name, 
                     cls->data()->firstSubclass->nameForLogging());
    }
    if (cls->ISA()->data()->firstSubclass) {
        _objc_inform("objc_disposeClassPair: class '%s' still has subclasses, "
                     "including '%s'!", cls->data()->ro->name, 
                     cls->ISA()->data()->firstSubclass->nameForLogging());
    }

    // don't remove_class_from_loadable_list() 
    // - it's not there and we don't have the lock
    detach_class(cls->ISA(), YES);
    detach_class(cls, NO);
    free_class(cls->ISA());
    free_class(cls);
}


/***********************************************************************
* objc_constructInstance
* Creates an instance of `cls` at the location pointed to by `bytes`. 
* `bytes` must point to at least class_getInstanceSize(cls) bytes of 
*   well-aligned zero-filled memory.
* The new object's isa is set. Any C++ constructors are called.
* Returns `bytes` if successful. Returns nil if `cls` or `bytes` is 
*   nil, or if C++ constructors fail.
* Note: class_createInstance() and class_createInstances() preflight this.
**********************************************************************/
id 
objc_constructInstance(Class cls, void *bytes) 
{
    if (!cls  ||  !bytes) return nil;

    id obj = (id)bytes;

    // Read class's info bits all at once for performance
    bool hasCxxCtor = cls->hasCxxCtor();
    bool hasCxxDtor = cls->hasCxxDtor();
    bool fast = cls->canAllocIndexed();
    
    if (!UseGC  &&  fast) {
        obj->initInstanceIsa(cls, hasCxxDtor);
    } else {
        obj->initIsa(cls);
    }

    if (hasCxxCtor) {
        return object_cxxConstructFromClass(obj, cls);
    } else {
        return obj;
    }
}


/***********************************************************************
* class_createInstance
* fixme
* Locking: none
**********************************************************************/

static __attribute__((always_inline)) 
id
_class_createInstanceFromZone(Class cls, size_t extraBytes, void *zone, 
                              bool cxxConstruct = true, 
                              size_t *outAllocatedSize = nil)
{
    if (!cls) return nil;

    assert(cls->isRealized());

    // Read class's info bits all at once for performance
    bool hasCxxCtor = cls->hasCxxCtor();
    bool hasCxxDtor = cls->hasCxxDtor();
    bool fast = cls->canAllocIndexed();

    size_t size = cls->instanceSize(extraBytes);
    if (outAllocatedSize) *outAllocatedSize = size;

    id obj;
    if (!UseGC  &&  !zone  &&  fast) {
        obj = (id)calloc(1, size);
        if (!obj) return nil;
        obj->initInstanceIsa(cls, hasCxxDtor);
    } 
    else {
#if SUPPORT_GC
        if (UseGC) {
            obj = (id)auto_zone_allocate_object(gc_zone, size,
                                                AUTO_OBJECT_SCANNED, 0, 1);
        } else 
#endif
        if (zone) {
            obj = (id)malloc_zone_calloc ((malloc_zone_t *)zone, 1, size);
        } else {
            obj = (id)calloc(1, size);
        }
        if (!obj) return nil;

        // Use non-indexed isa on the assumption that they might be 
        // doing something weird with the zone or RR.
        obj->initIsa(cls);
    }

    if (cxxConstruct && hasCxxCtor) {
        obj = _objc_constructOrFree(obj, cls);
    }

    return obj;
}


id 
class_createInstance(Class cls, size_t extraBytes)
{
    return _class_createInstanceFromZone(cls, extraBytes, nil);
}


/***********************************************************************
* class_createInstances
* fixme
* Locking: none
**********************************************************************/
#if SUPPORT_NONPOINTER_ISA
#warning fixme optimize class_createInstances
#endif
unsigned 
class_createInstances(Class cls, size_t extraBytes, 
                      id *results, unsigned num_requested)
{
    return _class_createInstancesFromZone(cls, extraBytes, nil, 
                                          results, num_requested);
}

static bool classOrSuperClassesUseARR(Class cls) {
    while (cls) {
        if (_class_usesAutomaticRetainRelease(cls)) return true;
        cls = cls->superclass;
    }
    return false;
}

static void arr_fixup_copied_references(id newObject, id oldObject)
{
    // use ARR layouts to correctly copy the references from old object to new, both strong and weak.
    Class cls = oldObject->ISA();
    for ( ; cls; cls = cls->superclass) {
        if (_class_usesAutomaticRetainRelease(cls)) {
            // FIXME:  align the instance start to nearest id boundary. This currently handles the case where
            // the the compiler folds a leading BOOL (char, short, etc.) into the alignment slop of a superclass.
            size_t instanceStart = _class_getInstanceStart(cls);
            const uint8_t *strongLayout = class_getIvarLayout(cls);
            if (strongLayout) {
                id *newPtr = (id *)((char*)newObject + instanceStart);
                unsigned char byte;
                while ((byte = *strongLayout++)) {
                    unsigned skips = (byte >> 4);
                    unsigned scans = (byte & 0x0F);
                    newPtr += skips;
                    while (scans--) {
                        // ensure strong references are properly retained.
                        id value = *newPtr++;
                        if (value) objc_retain(value);
                    }
                }
            }
            const uint8_t *weakLayout = class_getWeakIvarLayout(cls);
            // fix up weak references if any.
            if (weakLayout) {
                id *newPtr = (id *)((char*)newObject + instanceStart), *oldPtr = (id *)((char*)oldObject + instanceStart);
                unsigned char byte;
                while ((byte = *weakLayout++)) {
                    unsigned skips = (byte >> 4);
                    unsigned weaks = (byte & 0x0F);
                    newPtr += skips, oldPtr += skips;
                    while (weaks--) {
                        *newPtr = nil;
                        objc_storeWeak(newPtr, objc_loadWeak(oldPtr));
                        ++newPtr, ++oldPtr;
                    }
                }
            }
        }
    }
}

/***********************************************************************
* object_copyFromZone
* fixme
* Locking: none
**********************************************************************/
static id 
_object_copyFromZone(id oldObj, size_t extraBytes, void *zone)
{
    if (!oldObj) return nil;
    if (oldObj->isTaggedPointer()) return oldObj;

    // fixme this doesn't handle C++ ivars correctly (#4619414)

    Class cls = oldObj->ISA();
    size_t size;
    id obj = _class_createInstanceFromZone(cls, extraBytes, zone, false, &size);
    if (!obj) return nil;

    // Copy everything except the isa, which was already set above.
    uint8_t *copyDst = (uint8_t *)obj + sizeof(Class);
    uint8_t *copySrc = (uint8_t *)oldObj + sizeof(Class);
    size_t copySize = size - sizeof(Class);
#if SUPPORT_GC
    objc_memmove_collectable(copyDst, copySrc, copySize);
#else
    memmove(copyDst, copySrc, copySize);
#endif

#if SUPPORT_GC
    if (UseGC)
        gc_fixup_weakreferences(obj, oldObj);
    else
#endif
    if (classOrSuperClassesUseARR(cls))
        arr_fixup_copied_references(obj, oldObj);

    return obj;
}


/***********************************************************************
* object_copy
* fixme
* Locking: none
**********************************************************************/
id 
object_copy(id oldObj, size_t extraBytes)
{
    return _object_copyFromZone(oldObj, extraBytes, malloc_default_zone());
}


#if !(TARGET_OS_EMBEDDED  ||  TARGET_OS_IPHONE)

/***********************************************************************
* class_createInstanceFromZone
* fixme
* Locking: none
**********************************************************************/
id
class_createInstanceFromZone(Class cls, size_t extraBytes, void *zone)
{
    return _class_createInstanceFromZone(cls, extraBytes, zone);
}

/***********************************************************************
* object_copyFromZone
* fixme
* Locking: none
**********************************************************************/
id 
object_copyFromZone(id oldObj, size_t extraBytes, void *zone)
{
    return _object_copyFromZone(oldObj, extraBytes, zone);
}

#endif


/***********************************************************************
* objc_destructInstance
* Destroys an instance without freeing memory. 
* Calls C++ destructors.
* Calls ARR ivar cleanup.
* Removes associative references.
* Returns `obj`. Does nothing if `obj` is nil.
* Be warned that GC DOES NOT CALL THIS. If you edit this, also edit finalize.
* CoreFoundation and other clients do call this under GC.
**********************************************************************/
// 销毁对象，但不释放内存，因为使用 GC 的情况下需要做一些其他的工作
// 调用者：object_dispose()
void *objc_destructInstance(id obj) 
{
    if (obj) {
        // Read all of the flags at once for performance.
        bool cxx = obj->hasCxxDtor();
        bool assoc = !UseGC && obj->hasAssociatedObjects();
        bool dealloc = !UseGC;

        // This order is important.
        // 顺序非常重要，千万不能乱
        
        // 如果有c++的析构器，就调用c++的析构器进行析构
        if (cxx) object_cxxDestruct(obj);
        
        // 如果有关联的对象，就移除关联的对象
        if (assoc) _object_remove_assocations(obj);
        
        // clearDeallocating 中清空引用计数表并清除弱引用表，将所有weak引用指 nil
        if (dealloc) {
            obj->clearDeallocating();
        }
    }

    return obj;
}


/***********************************************************************
* object_dispose
* fixme
* Locking: none
**********************************************************************/
// 这个方法为什么不写成 objc_object 的成员方法呢，难道是因为这里需要 free objc_object 对象的内存，在成员方法里释放自己的内存，可能是不大合适的吧
// 调用者：objc_object::rootDealloc()
id 
object_dispose(id obj)
{
    if (!obj) return nil;

    // 析构实例，里面会调用c++析构器、清除关联对象、清除弱引用
    objc_destructInstance(obj);
    
    // 如果有 Garbage Collection 的话
    // 需要做一些其他的工作
#if SUPPORT_GC
    if (UseGC) {
        auto_zone_retain(gc_zone, obj); // gc free expects rc==1
    }
#endif

    // 释放内存
    free(obj);

    return nil;
}

/***********************************************************************
* _objc_getFreedObjectClass
* fixme
* Locking: none
**********************************************************************/
Class _objc_getFreedObjectClass (void)
{
    return nil;
}



/***********************************************************************
* Tagged pointer objects.
*
* Tagged pointer objects store the class and the object value in the 
* object pointer; the "pointer" does not actually point to anything.
* 
* Tagged pointer objects currently use this representation:
* (LSB)
*  1 bit   set if tagged, clear if ordinary object pointer
*  3 bits  tag index
* 60 bits  payload
* (MSB)
* The tag index defines the object's class. 
* The payload format is defined by the object's class.
*
* This representation is subject to change. Representation-agnostic SPI is:
* objc-internal.h for class implementers.
* objc-gdb.h for debuggers.
**********************************************************************/
#if !SUPPORT_TAGGED_POINTERS

// These variables are always provided for debuggers.
uintptr_t objc_debug_taggedpointer_mask = 0;
unsigned  objc_debug_taggedpointer_slot_shift = 0;
uintptr_t objc_debug_taggedpointer_slot_mask = 0;
unsigned  objc_debug_taggedpointer_payload_lshift = 0;
unsigned  objc_debug_taggedpointer_payload_rshift = 0;
Class objc_debug_taggedpointer_classes[1] = { nil };

static void
disableTaggedPointers() { }

#else

// The "slot" used in the class table and given to the debugger 
// includes the is-tagged bit. This makes objc_msgSend faster.

uintptr_t objc_debug_taggedpointer_mask = TAG_MASK;
unsigned  objc_debug_taggedpointer_slot_shift = TAG_SLOT_SHIFT;
uintptr_t objc_debug_taggedpointer_slot_mask = TAG_SLOT_MASK;
unsigned  objc_debug_taggedpointer_payload_lshift = TAG_PAYLOAD_LSHIFT;
unsigned  objc_debug_taggedpointer_payload_rshift = TAG_PAYLOAD_RSHIFT;
// objc_debug_taggedpointer_classes is defined in objc-msg-*.s

// 禁止 tagged pointer
static void
disableTaggedPointers()
{
    objc_debug_taggedpointer_mask = 0;
    objc_debug_taggedpointer_slot_shift = 0;
    objc_debug_taggedpointer_slot_mask = 0;
    objc_debug_taggedpointer_payload_lshift = 0;
    objc_debug_taggedpointer_payload_rshift = 0;
}

static int 
tagSlotForTagIndex(objc_tag_index_t tag)
{
#if SUPPORT_MSB_TAGGED_POINTERS
    return 0x8 | tag;
#else
    return (tag << 1) | 1;
#endif
}


/***********************************************************************
* _objc_registerTaggedPointerClass
* Set the class to use for the given tagged pointer index.
* Aborts if the tag is out of range, or if the tag is already 
* used by some other class.
**********************************************************************/
void
_objc_registerTaggedPointerClass(objc_tag_index_t tag, Class cls)
{    
    if (objc_debug_taggedpointer_mask == 0) {
        _objc_fatal("tagged pointers are disabled");
    }

    if ((unsigned int)tag >= TAG_COUNT) {
        _objc_fatal("tag index %u is too large.", tag);
    }

    int slot = tagSlotForTagIndex(tag);
    Class oldCls = objc_tag_classes[slot];
    
    if (cls  &&  oldCls  &&  cls != oldCls) {
        _objc_fatal("tag index %u used for two different classes "
                    "(was %p %s, now %p %s)", tag, 
                    oldCls, oldCls->nameForLogging(), 
                    cls, cls->nameForLogging());
    }

    objc_tag_classes[slot] = cls;
}


// Deprecated name.
void _objc_insert_tagged_isa(unsigned char slotNumber, Class isa) 
{
    return _objc_registerTaggedPointerClass((objc_tag_index_t)slotNumber, isa);
}


/***********************************************************************
* _objc_getClassForTag
* Returns the class that is using the given tagged pointer tag.
* Returns nil if no class is using that tag or the tag is out of range.
**********************************************************************/
Class
_objc_getClassForTag(objc_tag_index_t tag)
{
    if ((unsigned int)tag >= TAG_COUNT) return nil;
    return objc_tag_classes[tagSlotForTagIndex(tag)];
}

#endif


#if SUPPORT_FIXUP

OBJC_EXTERN void objc_msgSend_fixup(void);
OBJC_EXTERN void objc_msgSendSuper2_fixup(void);
OBJC_EXTERN void objc_msgSend_stret_fixup(void);
OBJC_EXTERN void objc_msgSendSuper2_stret_fixup(void);
#if defined(__i386__)  ||  defined(__x86_64__)
OBJC_EXTERN void objc_msgSend_fpret_fixup(void);
#endif
#if defined(__x86_64__)
OBJC_EXTERN void objc_msgSend_fp2ret_fixup(void);
#endif

OBJC_EXTERN void objc_msgSend_fixedup(void);
OBJC_EXTERN void objc_msgSendSuper2_fixedup(void);
OBJC_EXTERN void objc_msgSend_stret_fixedup(void);
OBJC_EXTERN void objc_msgSendSuper2_stret_fixedup(void);
#if defined(__i386__)  ||  defined(__x86_64__)
OBJC_EXTERN void objc_msgSend_fpret_fixedup(void);
#endif
#if defined(__x86_64__)
OBJC_EXTERN void objc_msgSend_fp2ret_fixedup(void);
#endif

/***********************************************************************
* fixupMessageRef
* Repairs an old vtable dispatch call site. 
* vtable dispatch itself is not supported.
**********************************************************************/
// 修复一个老的 vtable 调度
// 调用者：_read_images()
static void 
fixupMessageRef(message_ref_t *msg)
{
    // 注册消息的 sel
    msg->sel = sel_registerName((const char *)msg->sel);

    if (ignoreSelector(msg->sel)) { // 如果 sel 是需要被忽略的，就将其 imp 设为 _objc_ignored_method
        // ignored selector - bypass dispatcher
        msg->imp = (IMP)&_objc_ignored_method;
    }
    else if (msg->imp == &objc_msgSend_fixup) { // 如果消息的 imp 是 objc_msgSend_fixup，即指定了需要将 imp fixup
        if (msg->sel == SEL_alloc) {
            msg->imp = (IMP)&objc_alloc;
        } else if (msg->sel == SEL_allocWithZone) {
            msg->imp = (IMP)&objc_allocWithZone;
        } else if (msg->sel == SEL_retain) {
            msg->imp = (IMP)&objc_retain;
        } else if (msg->sel == SEL_release) {
            msg->imp = (IMP)&objc_release;
        } else if (msg->sel == SEL_autorelease) {
            msg->imp = (IMP)&objc_autorelease;
        } else {
            msg->imp = &objc_msgSend_fixedup; // 如果上面都不符合，就将它设置为已经 fixed-up 了
        }
    } 
    else if (msg->imp == &objc_msgSendSuper2_fixup) { 
        msg->imp = &objc_msgSendSuper2_fixedup;
    } 
    else if (msg->imp == &objc_msgSend_stret_fixup) { 
        msg->imp = &objc_msgSend_stret_fixedup;
    } 
    else if (msg->imp == &objc_msgSendSuper2_stret_fixup) { 
        msg->imp = &objc_msgSendSuper2_stret_fixedup;
    } 
#if defined(__i386__)  ||  defined(__x86_64__)
    else if (msg->imp == &objc_msgSend_fpret_fixup) { 
        msg->imp = &objc_msgSend_fpret_fixedup;
    } 
#endif
#if defined(__x86_64__)
    else if (msg->imp == &objc_msgSend_fp2ret_fixup) { 
        msg->imp = &objc_msgSend_fp2ret_fixedup;
    } 
#endif
}

// SUPPORT_FIXUP
#endif


// ProKit SPI
static Class setSuperclass(Class cls, Class newSuper)
{
    Class oldSuper;

    runtimeLock.assertWriting();

    assert(cls->isRealized());
    assert(newSuper->isRealized());

    oldSuper = cls->superclass;
    removeSubclass(oldSuper, cls);
    removeSubclass(oldSuper->ISA(), cls->ISA());

    cls->superclass = newSuper;
    cls->ISA()->superclass = newSuper->ISA();
    addSubclass(newSuper, cls);
    addSubclass(newSuper->ISA(), cls->ISA());

    // Flush subclass's method caches.
    flushCaches(cls);
    
    return oldSuper;
}


Class class_setSuperclass(Class cls, Class newSuper)
{
    rwlock_writer_t lock(runtimeLock);
    return setSuperclass(cls, newSuper);
}


// __OBJC2__
#endif
