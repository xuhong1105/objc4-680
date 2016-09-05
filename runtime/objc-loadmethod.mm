/*
 * Copyright (c) 2004-2006 Apple Inc.  All Rights Reserved.
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
* objc-loadmethod.m
* Support for +load methods.
**********************************************************************/

#include "objc-loadmethod.h"
#include "objc-private.h"

typedef void(*load_method_t)(id, SEL); // 用于 +load 方法的 imp 类型

struct loadable_class { // 需要被调用 +load 方法的类
    Class cls;  // may be nil
    IMP method; // +load 方法对应的 imp
};

struct loadable_category { // 需要被调用 +load 方法的分类
    Category cat;  // may be nil
    IMP method; // +load 方法对应的 imp
};


// List of classes that need +load called (pending superclass +load)
// This list always has superclasses first because of the way it is constructed
static struct loadable_class *loadable_classes = nil; // 这个列表中存放所有需要调用 +load 方法的类
static int loadable_classes_used = 0; // loadable_classes 列表中已经被使用了多少个位置
static int loadable_classes_allocated = 0; // loadable_classes 列表开辟了多少位置，如果位置不够用了，会进行扩容

// List of categories that need +load called (pending parent class +load)
static struct loadable_category *loadable_categories = nil; // 这个列表中存放所有需要执行 +load 方法的分类
static int loadable_categories_used = 0; // loadable_categories 列表中已经被使用了多少个位置
static int loadable_categories_allocated = 0; // loadable_categories 列表开辟了多少位置，如果位置不够用了，会进行扩容


/***********************************************************************
* add_class_to_loadable_list
* Class cls has just become connected. Schedule it for +load if
* it implements a +load method.
**********************************************************************/
// 将 cls 类添加到 loadable_classes 列表中，
// 其中会检查 cls 类是否确实有 +load 方法，只有拥有 +load 方法，并且确实有对应的 imp，才会将其添加到 loadable_classes 列表，
// 调用者：schedule_class_load()
void add_class_to_loadable_list(Class cls)
{
    IMP method;

    loadMethodLock.assertLocked(); // loadMethodLock 需要事先加锁

    method = cls->getLoadMethod(); // 取得 cls 类的 +load 方法的 imp
    
    if (!method) return;  // Don't bother if cls has no +load method
                        // 如果 cls 类压根儿就没有 +load 方法，那也没有将其添加到 loadable_classes 列表的必要
                        // 直接返回
    
    if (PrintLoading) {
        _objc_inform("LOAD: class '%s' scheduled for +load", 
                     cls->nameForLogging());
    }
    
    // 如果 loadable_classes 列表已经满了
    if (loadable_classes_used == loadable_classes_allocated) {
        // 重新计算一下新的大小
        loadable_classes_allocated = loadable_classes_allocated*2 + 16;
        // 重新开辟新的内存空间，并将原来的数据拷贝过去
        loadable_classes = (struct loadable_class *)
            realloc(loadable_classes,
                              loadable_classes_allocated *
                              sizeof(struct loadable_class));
    }
    
    // cls 插入到列表末尾
    loadable_classes[loadable_classes_used].cls = cls;
    loadable_classes[loadable_classes_used].method = method;
    
    loadable_classes_used++; // 元素数量 +1
}


/***********************************************************************
* add_category_to_loadable_list
* Category cat's parent class exists and the category has been attached
* to its class. Schedule this category for +load after its parent class
* becomes connected and has its own +load method called.
**********************************************************************/
// 将分类 cat 添加到 loadable_categories 列表中
void add_category_to_loadable_list(Category cat)
{
    IMP method;

    loadMethodLock.assertLocked();

    method = _category_getLoadMethod(cat);

    // Don't bother if cat has no +load method
    if (!method) return;

    if (PrintLoading) {
        _objc_inform("LOAD: category '%s(%s)' scheduled for +load", 
                     _category_getClassName(cat), _category_getName(cat));
    }
    
    if (loadable_categories_used == loadable_categories_allocated) {
        loadable_categories_allocated = loadable_categories_allocated*2 + 16;
        loadable_categories = (struct loadable_category *)
            realloc(loadable_categories,
                              loadable_categories_allocated *
                              sizeof(struct loadable_category));
    }

    loadable_categories[loadable_categories_used].cat = cat;
    loadable_categories[loadable_categories_used].method = method;
    loadable_categories_used++;
}


/***********************************************************************
* remove_class_from_loadable_list
* Class cls may have been loadable before, but it is now no longer 
* loadable (because its image is being unmapped). 
**********************************************************************/
// 将 cls 类从 loadable_classes 列表中删除
// 类原来可能是 loadable 的，但是现在它将不是 loadable 的，因为镜像已经被取消映射了
// 调用者：_unload_image()
void remove_class_from_loadable_list(Class cls)
{
    loadMethodLock.assertLocked();

    if (loadable_classes) {
        int i;
        for (i = 0; i < loadable_classes_used; i++) { // 遍历 loadable_classes 列表
            if (loadable_classes[i].cls == cls) { // 找到匹配的类
                loadable_classes[i].cls = nil; // 就将其从 loadable_classes 中删除，直接置为 nil
                if (PrintLoading) {
                    _objc_inform("LOAD: class '%s' unscheduled for +load", 
                                 cls->nameForLogging());
                }
                return;
            }
        }
    }
}


/***********************************************************************
* remove_category_from_loadable_list
* Category cat may have been loadable before, but it is now no longer 
* loadable (because its image is being unmapped). 
**********************************************************************/
// 将分类 cat 从 loadable_categories 列表中删除
// 分类原来可能是 loadable 的，但是现在它将不是 loadable 的，因为镜像已经被取消映射了
// 调用者：_unload_image()
void remove_category_from_loadable_list(Category cat)
{
    loadMethodLock.assertLocked();

    if (loadable_categories) { // 如果 loadable_categories 非空，即里面有元素才继续
        int i;
        for (i = 0; i < loadable_categories_used; i++) { // 遍历 loadable_categories 的元素
            if (loadable_categories[i].cat == cat) { // 如果有匹配的分类
                loadable_categories[i].cat = nil; // 就将其从 loadable_categories 中删除，直接置为 nil
                if (PrintLoading) {
                    _objc_inform("LOAD: category '%s(%s)' unscheduled for +load",
                                 _category_getClassName(cat), 
                                 _category_getName(cat));
                }
                return;
            }
        }
    }
}


/***********************************************************************
* call_class_loads
* Call all pending class +load methods.
* If new classes become loadable, +load is NOT called for them.
*
* Called only by call_load_methods().
**********************************************************************/
// 调用 loadable_classes 中所有类的 +load 方法
// 会先将列表暂存起来，然后将原来的列表清空，
// 后面会只调用暂存起来的类的 +load，而新列表中即使插入了新的类，也不管它们，
// 调用者：call_load_methods()
static void call_class_loads(void)
{
    int i;
    
    // Detach current loadable list.
    struct loadable_class *classes = loadable_classes; // 先将列表暂存起来，即另一个指针指向列表的内存
    int used = loadable_classes_used; // 暂存列表中类的数量
    loadable_classes = nil; // loadable_classes 指向指向 nil，与原来的列表脱离关系
    loadable_classes_allocated = 0; // 容量清零
    loadable_classes_used = 0; // 类的个数清零
    
    // Call all +loads for the detached list.
    for (i = 0; i < used; i++) { // 遍历暂存的列表
        Class cls = classes[i].cls;
        // 取得该类的 +load 方法的 imp
        load_method_t load_method = (load_method_t)classes[i].method;
        if (!cls) continue;  // 如果 imp 不存在，没得玩，跳过
                             // 一般情况下，不会这么糟糕，因为 add_class_to_loadable_list() 中对
                             // 没有 +load imp 的类进行了排除

        if (PrintLoading) {
            _objc_inform("LOAD: +[%s load]\n", cls->nameForLogging());
        }
        (*load_method)(cls, SEL_load); // 直接调用 +load 的 imp 函数，跳过 objc_msgSend 速度更快
    }
    
    // Destroy the detached list.
    if (classes) free(classes); // 将暂存的列表销毁释放
}


/***********************************************************************
* call_category_loads
* Call some pending category +load methods.
* The parent class of the +load-implementing categories has all of 
*   its categories attached, in case some are lazily waiting for +initalize.
* Don't call +load unless the parent class is connected.
* If new categories become loadable, +load is NOT called, and they 
*   are added to the end of the loadable list, and we return TRUE.
* Return FALSE if no new categories became loadable.
*
* Called only by call_load_methods().
**********************************************************************/
// 调用分类中的 +load 方法
// 调用者：call_load_methods()
static bool call_category_loads(void)
{
    int i, shift;
    bool new_categories_added = NO;
    
    // Detach current loadable list.
    struct loadable_category *cats = loadable_categories;
    int used = loadable_categories_used;
    int allocated = loadable_categories_allocated;
    loadable_categories = nil;
    loadable_categories_allocated = 0;
    loadable_categories_used = 0;

    // Call all +loads for the detached list.
    for (i = 0; i < used; i++) {
        Category cat = cats[i].cat;
        load_method_t load_method = (load_method_t)cats[i].method;
        Class cls;
        if (!cat) continue;

        cls = _category_getClass(cat);
        if (cls  &&  cls->isLoadable()) {
            if (PrintLoading) {
                _objc_inform("LOAD: +[%s(%s) load]\n", 
                             cls->nameForLogging(), 
                             _category_getName(cat));
            }
            (*load_method)(cls, SEL_load);
            cats[i].cat = nil;
        }
    }

    // Compact detached list (order-preserving)
    shift = 0;
    for (i = 0; i < used; i++) {
        if (cats[i].cat) {
            cats[i-shift] = cats[i];
        } else {
            shift++;
        }
    }
    used -= shift;

    // Copy any new +load candidates from the new list to the detached list.
    new_categories_added = (loadable_categories_used > 0);
    for (i = 0; i < loadable_categories_used; i++) {
        if (used == allocated) {
            allocated = allocated*2 + 16;
            cats = (struct loadable_category *)
                realloc(cats, allocated *
                                  sizeof(struct loadable_category));
        }
        cats[used++] = loadable_categories[i];
    }

    // Destroy the new list.
    if (loadable_categories) free(loadable_categories);

    // Reattach the (now augmented) detached list. 
    // But if there's nothing left to load, destroy the list.
    if (used) {
        loadable_categories = cats;
        loadable_categories_used = used;
        loadable_categories_allocated = allocated;
    } else {
        if (cats) free(cats);
        loadable_categories = nil;
        loadable_categories_used = 0;
        loadable_categories_allocated = 0;
    }

    if (PrintLoading) {
        if (loadable_categories_used != 0) {
            _objc_inform("LOAD: %d categories still waiting for +load\n",
                         loadable_categories_used);
        }
    }

    return new_categories_added;
}


/***********************************************************************
* call_load_methods
* Call all pending class and category +load methods.
* Class +load methods are called superclass-first. 
* Category +load methods are not called until after the parent class's +load.
* 
* This method must be RE-ENTRANT, because a +load could trigger 
* more image mapping. In addition, the superclass-first ordering 
* must be preserved in the face of re-entrant calls. Therefore, 
* only the OUTERMOST call of this function will do anything, and 
* that call will handle all loadable classes, even those generated 
* while it was running.
*
* The sequence below preserves +load ordering in the face of 
* image loading during a +load, and make sure that no 
* +load method is forgotten because it was added during 
* a +load call.
* Sequence:
* 1. Repeatedly call class +loads until there aren't any more
* 2. Call category +loads ONCE.
* 3. Run more +loads if:
*    (a) there are more classes to load, OR
*    (b) there are some potential category +loads that have 
*        still never been attempted.
* Category +loads are only run once to ensure "parent class first" 
* ordering, even if a category +load triggers a new loadable class 
* and a new loadable category attached to that class. 
*
* Locking: loadMethodLock must be held by the caller 
*   All other locks must not be held.
**********************************************************************/
// 这个函数中调用类的 +load 方法
void call_load_methods(void)
{
    static bool loading = NO;
    bool more_categories;

    loadMethodLock.assertLocked();

    // Re-entrant calls do nothing; the outermost call will finish the job.
    if (loading) return;
    loading = YES;

    void *pool = objc_autoreleasePoolPush();

    do {
        // 1. Repeatedly call class +loads until there aren't any more
        while (loadable_classes_used > 0) {
            call_class_loads();
        }

        // 2. Call category +loads ONCE
        more_categories = call_category_loads();

        // 3. Run more +loads if there are classes OR more untried categories
    } while (loadable_classes_used > 0  ||  more_categories);

    objc_autoreleasePoolPop(pool);

    loading = NO;
}


