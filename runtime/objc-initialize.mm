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
* objc-initialize.m
* +initialize support
**********************************************************************/

/***********************************************************************
 * Thread-safety during class initialization (GrP 2001-9-24)
 *
 * Initial state: CLS_INITIALIZING and CLS_INITIALIZED both clear. 
 * During initialization: CLS_INITIALIZING is set
 * After initialization: CLS_INITIALIZING clear and CLS_INITIALIZED set.
 * CLS_INITIALIZING and CLS_INITIALIZED are never set at the same time.
 * CLS_INITIALIZED is never cleared once set.
 *
 * Only one thread is allowed to actually initialize a class and send 
 * +initialize. Enforced by allowing only one thread to set CLS_INITIALIZING.
 *
 * Additionally, threads trying to send messages to a class must wait for 
 * +initialize to finish. During initialization of a class, that class's 
 * method cache is kept empty. objc_msgSend will revert to 
 * class_lookupMethodAndLoadCache, which checks CLS_INITIALIZED before 
 * messaging. If CLS_INITIALIZED is clear but CLS_INITIALIZING is set, 
 * the thread must block, unless it is the thread that started 
 * initializing the class in the first place. 
 *
 * Each thread keeps a list of classes it's initializing. 
 * The global classInitLock is used to synchronize changes to CLS_INITIALIZED 
 * and CLS_INITIALIZING: the transition to CLS_INITIALIZING must be 
 * an atomic test-and-set with respect to itself and the transition 
 * to CLS_INITIALIZED.
 * The global classInitWaitCond is used to block threads waiting for an 
 * initialization to complete. The classInitLock synchronizes
 * condition checking and the condition variable.
 
 class 的初始化是线程安全的
 
 初始状态：CLS_INITIALIZING 和 CLS_INITIALIZED 标志位都是 0
 初始化中：CLS_INITIALIZING 标志位是 1，CLS_INITIALIZED 标志位是 0
 初始化完成后：CLS_INITIALIZING 标志位是 0，CLS_INITIALIZED 标志位是 1
 CLS_INITIALIZED 永远都不会被清为 0
 
 只有一个线程允许初始化一个类和向这个类发送 +initialize 消息，这是由只有一个
 线程修改 CLS_INITIALIZING 标志位来强制实现的（所以要加锁）
 
 另外，线程必须等到类的 +initialize 方法结束之后才能给类发送消息。在一个类初始化期间，这个类的方法缓存是保持为空的。
 objc_msgSend 将会跳转到 class_lookupMethodAndLoadCache（其实是 _class_lookupMethodAndLoadCache3 ），
 在发送消息之前，这个函数中将会检查 CLS_INITIALIZED 标志位，如果CLS_INITIALIZED 标志位是 0，CLS_INITIALIZING 标志位是 1，
 线程必须阻塞，除非这个线程就是首先初始化这个类的线程
 
 每个线程维护一个正在初始化的类的列表。
 全局的 classInitLock 锁用来同步对 CLS_INITIALIZED 和 CLS_INITIALIZING 的修改，
 对 CLS_INITIALIZING 和 CLS_INITIALIZED 的修改必须是原子的。
 全局的 classInitWaitCond（其实没这玩意儿，互斥锁和条件变量都在classInitLock里面）条件变量用来阻塞线程等待一个初始化操作完成。classInitLock 用来同步条件检查和条件变量。
 
 **********************************************************************/

/***********************************************************************
 *  +initialize deadlock case when a class is marked initializing while 
 *  its superclass is initialized. Solved by completely initializing 
 *  superclasses before beginning to initialize a class.
 *
 *  OmniWeb class hierarchy:
 *                 OBObject 
 *                     |    ` OBPostLoader
 *                 OFObject
 *                 /     \
 *      OWAddressEntry  OWController
 *                        | 
 *                      OWConsoleController
 *
 *  Thread 1 (evil testing thread):
 *    initialize OWAddressEntry
 *    super init OFObject
 *    super init OBObject		     
 *    [OBObject initialize] runs OBPostLoader, which inits lots of classes...
 *    initialize OWConsoleController
 *    super init OWController - wait for Thread 2 to finish OWController init
 *
 *  Thread 2 (normal OmniWeb thread):
 *    initialize OWController
 *    super init OFObject - wait for Thread 1 to finish OFObject init
 *
 *  deadlock!
 *
 *  Solution: fully initialize super classes before beginning to initialize 
 *  a subclass. Then the initializing+initialized part of the class hierarchy
 *  will be a contiguous subtree starting at the root, so other threads 
 *  can't jump into the middle between two initializing classes, and we won't 
 *  get stuck while a superclass waits for its subclass which waits for the 
 *  superclass.
 
 上面是 +initialize 发生死锁的例子：
    线程 1 ：
        初始化 OWAddressEntry 类 ->
        初始化 OFObject 类 ->
        初始化 OBObject 类 ->
        [OBObject initialize] 中用了 OBPostLoader 类，里面需要初始化好多类 ->
        初始化 OWConsoleController 类 ->
        初始化 OWController 类，发现线程2正在初始化 OWController 类，就阻塞等待线程2完成对 OWController 的初始化工作 ....
 
    线程 2 ：
        初始化 OWController 类 ->
        初始化 OFObject 类，发现线程1正在初始化 OFObject 类，就阻塞等待线程1完成对 OFObject 类的初始化工作....
 
    就很悲催地死锁了！
 
    解决方案：完全初始化父类以后，才能开始初始化子类。（这句话有错误，应该是父类必须比子类先开始初始化，即父类比子类先进入 initializing 状态）
            那么类之间的初始化关系就是从根类开始的一个邻接的子树，
            其他线程不能插入两个正在初始化的类之间，也不会出现父类和子类相互等待的情况
 
 
 I. 进入 +initialize 方法的顺序是（进入 +initialize 的顺序就是开始 initializing 的顺序）
 OBObject -> OBPostLoader -> OFObject -> OWController -> OWConsoleController -> OWAddressEntry
 
 
 II. 退出 +initialize 方法的顺序是（只是完成这个方法的顺序，并不是变为 initialized 状态的顺序，那个顺序因为 pendingInitializeMap 的原因所以一定是从上到下有序排列的）
    OFObject -> OWController -> OWConsoleController -> OBPostLoader -> OBObject -> OWAddressEntry
 
 很奇怪的是，都是在一个线程中，原因在后面讲。
 
 路径是:
     -> OWAddressEntry 找父类
        -> OFObject 找父类
            -> OBObject  ① 进入 +initialize
                -> OBPostLoader ② 进入 +initialize
                    -> OWConsoleController 找父类
                        -> OWController 找父类
                            -> OFObject ③ 进入 +initialize
                            <- 0. OFObject 退出 +initialize
                        <- OWController ④ 进入退出 +initialize
                    <- OWConsoleController ⑤ 进入退出 +initialize
                <- OBPostLoader ⑥ 退出 +initialize
            <- 4. OBObject ⑦ 退出 +initialize
        <- 已经完成 +initialize 所以 skip
     <- OWAddressEntry ⑧ 进入退出 +initialize

 有几个关键点：
 1. 首先，从 OWAddressEntry 一路向上找到 OBObject 类，因为 OBObject 类的父类 NSObject 已经完成了初始化，所以 OBObject 类第一个进入 +initialize 方法，
 2. 从 OBPostLoader 一路找到 OFObject，因为 OBObject 已经处于 Initialized 并且是同一个线程，所以 _class_initialize 直接返回了，那么 OFObject 就可以开始初始化，进入 +initialize 方法，因为它没有调用其他类，所以第一个退出 +initialize 方法

 
 _class_initialize 解锁上面的死锁问题的要点是：父类一定比子类先开始初始化。
 因为 OWController的父类 OFObject 还没有初始化，所以它也不会开始初始化，而是等到父类在同一线程开始初始化，或者在另一线程完成初始化后，才会进行初始化。所以线程2并没有在初始化OWController，线程1也并不需要等待，也就是没有了竞争和死锁。
 真实情况是线程2在查看OFObject时，发现它正在线程1中被初始化，线程2需要挂起等待，或者它已经被初始化了，无论如何，它是没有机会的，这也是这个例子中所有类都是在一个线程上初始化的原因。如果两个线程初始化的类是树上两条路径，并且这两条路径在一个树杈上，即根节点相同，那么竞争的只有这个根节点，所以将根节点置为initializing状态时，需要加互斥锁，为的就是两个线程在争抢根节点时能线程安全；而且，还要将其加入当前线程正在初始化的类的列表，为的就是宣示当前线程对该根节点的持有权。
 **********************************************************************/

#include "objc-private.h"
#include "message.h"
#include "objc-initialize.h"

/* classInitLock protects CLS_INITIALIZED and CLS_INITIALIZING, and
 * is signalled when any class is done initializing.
 * Threads that are waiting for a class to finish initializing wait on this. */
// classInitLock 保护 CLS_INITIALIZED 和 CLS_INITIALIZING
// 并且会在所有的类都完成 initializing 后被 signal
// 线程们等待一个类完成 initializing，就是在 wait 这个锁(条件变量)
static monitor_t classInitLock;


/***********************************************************************
* struct _objc_initializing_classes
* Per-thread list of classes currently being initialized by that thread. 
* During initialization, that thread is allowed to send messages to that 
* class, but other threads have to wait.
* The list is a simple array of metaclasses (the metaclass stores 
* the initialization state). 
**********************************************************************/
// 一个线程当前正在 initialize 的类的列表
// 在 initialization 期间，允许这个线程发送消息给那些类，但是其他的线程必须等待
// 这个列表是一个简单的 元类的 数组（元类中存有 initialization 的状态）
typedef struct _objc_initializing_classes {
    int classesAllocated; // metaclasses 数组的容量，并不是元素的个数
    Class *metaclasses;   // 存有元类的数组
} _objc_initializing_classes;


/***********************************************************************
* _fetchInitializingClassList
* Return the list of classes being initialized by this thread.
* If create == YES, create the list when no classes are being initialized by this thread.
* If create == NO, return nil when no classes are being initialized by this thread.

 返回这个线程正在初始化的类的列表。注意，列表中是元类。
 如果 create == YES，当现在没有类正在被这个线程初始化的时候，创建这个列表，也就是说返回的是个空列表
 如果 create == NO，当还没有类被这个线程初始化的时候，返回 nil
 **********************************************************************/
static _objc_initializing_classes *_fetchInitializingClassList(BOOL create)
{
    _objc_pthread_data *data; // 用来保存取到的线程数据
    _objc_initializing_classes *list; // 用来保存线程数据中的 initializingClasses 列表
    
    Class *classes; // 用来保存 list->metaclasses

    // 取得当前线程的 线程数据（pthread data）
    data = _objc_fetch_pthread_data(create);
    // 如果线程数据都没有，无论是否指定 create，都直接返回 nil，因为根本没法儿玩
    if (data == nil) {
        return nil;
    }

    // 从线程数据中，取出这个线程正在初始化的类的列表，
    list = data->initializingClasses;
    
    if (list == nil) {
        // 如果 list 为 nil，且没有指定 create，就直接返回 nil
        if (!create) {
            return nil;
        } else {// 如果指定了 create
            // 就为列表开辟空间
            list = (_objc_initializing_classes *)
                calloc(1, sizeof(_objc_initializing_classes));
            // 将它保存到线程数据的 initializingClasses 字段中
            data->initializingClasses = list;
        }
    }

    // 取出列表中的元类数组
    classes = list->metaclasses;
    // 如果元类数组为 nil
    if (classes == nil) { // classes == nil，说明 list 里的字段压根儿没初始化
        // If _objc_initializing_classes exists, allocate metaclass array, 
        // even if create == NO.
        // Allow 4 simultaneous class inits on this thread before realloc.
        
        // 将 list 里的字段初始化，线程中允许同时初始化的类的数量最初是 4 个
        list->classesAllocated = 4;
        // 为 list->metaclasses 在堆中开辟内存空间
        classes = (Class *)
            calloc(list->classesAllocated, sizeof(Class));
        list->metaclasses = classes;
    }
    // 返回列表
    return list;
}


/***********************************************************************
* _destroyInitializingClassList
* Deallocate memory used by the given initialization list. 
* Any part of the list may be nil.
* Called from _objc_pthread_destroyspecific().
 
 销毁 _objc_initializing_classes 列表，释放内存，
 列表中可能有些元素是 nil
 这个函数被 _objc_pthread_destroyspecific() 函数调用
**********************************************************************/
void _destroyInitializingClassList(struct _objc_initializing_classes *list)
{
    if (list != nil) {
        if (list->metaclasses != nil) {
            free(list->metaclasses);
        }
        free(list);
    }
}


/***********************************************************************
* _thisThreadIsInitializingClass
* Return TRUE if this thread is currently initializing the given class.
**********************************************************************/
// 检查当前线程是否正在初始化 cls 类
static BOOL _thisThreadIsInitializingClass(Class cls)
{
    int i;

    // 取得这个线程正在初始化的类的列表，列表中是元类
    _objc_initializing_classes *list = _fetchInitializingClassList(NO);
    if (list) {
        // 获取 cls 类的元类
        cls = cls->getMeta();
        // 遍历 list，看 cls 是否在其中
        for (i = 0; i < list->classesAllocated; i++) {
            if (cls == list->metaclasses[i]) return YES;
        }
    }

    // no list or not found in list
    return NO;
}


/***********************************************************************
* _setThisThreadIsInitializingClass
* Record that this thread is currently initializing the given class. 
* This thread will be allowed to send messages to the class, but 
*   other threads will have to wait.
 
 记录下这个线程，正在初始化给定的类 cls
 线程将会被允许给这个类发消息，但是其他的线程还得继续等
 如果传入的类 cls 出现在线程中正在初始化的类的列表中，也就是意味着它又要被初始化一次，
    这是致命的错误，那么就报错
 否则，就将其添加到线程数据中专门保存正在初始化的类的结构体 _objc_initializing_classes 中
**********************************************************************/
static void _setThisThreadIsInitializingClass(Class cls)
{
    int i; // 做遍历的时候用
    
    // 取到这个线程正在初始化的类的列表，列表中是元类
    _objc_initializing_classes *list = _fetchInitializingClassList(YES);
    
    // 取到这个类的元类
    cls = cls->getMeta();
  
    // paranoia: explicitly disallow duplicates  明确不允许复制
    // 遍历线程正在初始化的元类列表 list->metaclasses，
    // 如果 cls 的元类（ 因为前面有 getMeta ），与列表中的某个元类相同，就报错
    for (i = 0; i < list->classesAllocated; i++) {
        if (cls == list->metaclasses[i]) {
            _objc_fatal("thread is already initializing this class!");
            return; // already the initializer
        }
    }
  
    // 遍历 list->metaclasses 数组，找到第一个空位置，把 cls 的元类放进去
    for (i = 0; i < list->classesAllocated; i++) {
        if (! list->metaclasses[i]) {
            list->metaclasses[i] = cls;
            return;
        }
    }

    // 如果 list->metaclasses 数组中一个空位置都没有，那就扩容
    
    // class list is full - reallocate
    // 容量翻倍
    list->classesAllocated = list->classesAllocated * 2 + 1;
    // 用 realloc 重新开辟内存，因为是 realloc，所以原来的数据会被拷贝到新内存
    list->metaclasses = (Class *) 
        realloc(list->metaclasses,
                          list->classesAllocated * sizeof(Class));
    // zero out the new entries
    // 将 cls 放在 i 索引处（ i 是经过上面的遍历后记录下来的）
    list->metaclasses[i++] = cls;
    // 将除 cls 之外的 所有刚开辟的索引位置都置为 nil，方便下次取的时候，知道哪些索引处是真正有数据的
    for ( ; i < list->classesAllocated; i++) {
        list->metaclasses[i] = nil;
    }
}


/***********************************************************************
* _setThisThreadIsNotInitializingClass
* Record that this thread is no longer initializing the given class. 
**********************************************************************/
// 记录下这个线程完成初始化这个类了，即将它从 _objc_initializing_classes 列表中删除
static void _setThisThreadIsNotInitializingClass(Class cls)
{
    int i;

    // 返回这个线程正在初始化的类的列表，参数传 NO，表示当还没有类被这个线程初始化的时候，返回 nil
    _objc_initializing_classes *list = _fetchInitializingClassList(NO);
    if (list) {
        // 取得 cls 的元类
        cls = cls->getMeta();
        // 遍历 metaclasses 数组
        for (i = 0; i < list->classesAllocated; i++) {
            // 找到 cls 所在的位置，比较的是 cls 的地址和 list 中存储的地址
            if (cls == list->metaclasses[i]) {
                // 将 cls 从 metaclasses 中删除，删除的只是存储的地址，cls 本身的内存不会有影响的
                list->metaclasses[i] = nil;
                return;
            }
        }
    }

    // 如果在列表中找不到 cls ，则前面出了严重的错误
    // no list or not found in list
    _objc_fatal("thread is not initializing this class!");  
}

// 待处理的初始化结构体，是一个链表，每个元素存了某个类的一个子类，以及指向下一个 pending 的指针
typedef struct PendingInitialize {
    Class subclass;                 // 子类
    struct PendingInitialize *next; // 下一个，看来是一个链表
} PendingInitialize;


// 当一个类初始化后，会判断父类有没有完成初始化，若父类还没有完成初始化，就等待；
// pendingInitializeMap 中记录的就是 正在初始化的父类们 与 正在等待的子类们 的关系
// 父类是 key ，pending 链表的首地址是 value，pending 的类型就是上面的 PendingInitialize，
// 它是一个链表，链表中每个元素存一个子类，
// 有新的等待的子类进来时，会插入到链表中，
// 当父类完成初始化后，会将链表中存的所有子类都置为 Initialized，即完成初始化，
// 然后将链表的头从 pendingInitializeMap 中删除，并将链表释放
// _finishInitializing() 和 _finishInitializingAfter() 两个函数会操作它
static NXMapTable *pendingInitializeMap; // 一个 MapTable key：class；value：pending

/***********************************************************************
* _finishInitializing
* cls has completed its +initialize method, and so has its superclass.
* Mark cls as initialized as well, then mark any of cls's subclasses 
* that have already finished their own +initialize methods.
 
 cls 类和它的父类都已经完成 +initialize 方法
 就将 cls 类标记为 initialized，然后标记 cls 类的所有子类都已经完成 +initialize，
 （ 标记操作是递归进行的，子类记录在 PendingInitialize 中 ）
 进入这个函数前，需要 classInitLock 被加锁（_class_initialize 中加了锁）
**********************************************************************/
static void _finishInitializing(Class cls, Class supercls)
{
    // cls 对应的 pending，是一个链表，因为一个类可能会有很多子类，所以是用链表把每个子类串在一起的
    PendingInitialize *pending;

    // 判断 classInitLock 有没有被正确地上锁
    classInitLock.assertLocked();
    
    // 如果它有父类，且父类没有完成 Initialized，就说明 _class_initialize() 函数中有错误
    assert(!supercls  ||  supercls->isInitialized());

    // 打印，说类已经完全完成 +initialized
    if (PrintInitializing) {
        _objc_inform("INITIALIZE: %s is fully +initialized",
                     cls->nameForLogging());
    }

    // propagate finalization affinity.
    // 如果用的是GC && 有父类 && 父类需要在主线程结束
    if (UseGC && supercls && supercls->shouldFinalizeOnMainThread()) {
        // 那么 cls 类也必须和父类一致，在主线程结束
        cls->setShouldFinalizeOnMainThread();
    }

    // mark this class as fully +initialized
    // 将 cls 设置为已经被 Initialized，里面会做设置是否有自定义 AWZ/RR 的工作，并将 cls 的状态由 Initializing 变为 Initialized
    cls->setInitialized();
    
    // signal classInitLock 锁，重启动等待 classInitLock 的所有线程
    classInitLock.notifyAll();
    // 记录下这个线程完成初始化这个类了，即将它从 _objc_initializing_classes 列表中删除
    _setThisThreadIsNotInitializingClass(cls);
    
    // mark any subclasses that were merely waiting for this class
    // 如果 pendingInitializeMap 是空的，就不用继续干了
    if (!pendingInitializeMap) {
        return;
    }
    // 从 pendingInitializeMap 中根据 key cls 取出对应的 pending
    pending = (PendingInitialize *)NXMapGet(pendingInitializeMap, cls);
    // 如果 pending 是空，不用继续玩了，因为 cls 没有子类
    if (!pending) return;

    // 利用 key cls 将 pending链表 从 pendingInitializeMap 中移除
    NXMapRemove(pendingInitializeMap, cls);
    
    // Destroy the pending table if it's now empty, to save memory.
    if (NXCountMapTable(pendingInitializeMap) == 0) { // 如果 pendingInitializeMap 中元素数量等于0，即它是空的了
        NXFreeMapTable(pendingInitializeMap); // 就把 pendingInitializeMap 释放了，节约内存
        pendingInitializeMap = nil; // 置为 nil，防止野指针
    }

    // 因为 pending 是一个链表，所以需要遍历，将每个 pending 中存的子类都设为完成 Initializing，
    // 状态变为 Initialized，并将 pending 释放
    while (pending) {
        PendingInitialize *next = pending->next; // 先保存下一个元素的地址
        if (pending->subclass) { // 如果 pending 中确实存有子类，
            _finishInitializing(pending->subclass, cls); // 就递归本函数，将子类标记为已经完成 Initializing
        }
        free(pending);  // 将 pending 释放
        pending = next; // 指针指向下一个元素
    }
}


/***********************************************************************
* _finishInitializingAfter
* cls has completed its +initialize method, but its superclass has not.
* Wait until supercls finishes before marking cls as initialized.
 
 cls 已经完成了 +initialize 方法，但是它的父类还没有完成
 等待父类完成 +initialize，再将 cls 标记为 initialized
 等待的关系是在 pendingInitializeMap 里存的，key 是父类，value 是 pending，
**********************************************************************/
static void _finishInitializingAfter(Class cls, Class supercls)
{
    PendingInitialize *pending;

    // _class_initialize 中已经对 classInitLock 加过锁了，这里只是判断 classInitLock 有没有被正确地加锁，防止意外
    classInitLock.assertLocked();

    // 打印信息， cls 类正在等待父类 supercls 完成 +initialize
    if (PrintInitializing) {
        _objc_inform("INITIALIZE: %s waiting for superclass +[%s initialize]",
                     cls->nameForLogging(), supercls->nameForLogging());
    }

    // 如果 pendingInitializeMap 还是 nil，就创建它
    if (!pendingInitializeMap) {
        pendingInitializeMap = 
            NXCreateMapTable(NXPtrValueMapPrototype, 10);
        // fixme pre-size this table for CF/NSObject +initialize
    }

    // 在堆中新建一个 penging
    pending = (PendingInitialize *)malloc(sizeof(*pending));
    pending->subclass = cls; // pending 记录子类 cls
    // next 指向下一个 pending，因为类会多个子类，所以还是才用了树的结构，next 指向的是兄弟节点
    pending->next = (PendingInitialize *) NXMapGet(pendingInitializeMap, supercls);
    // 将 pending 插入 pendingInitializeMap 中，key 是父类
    NXMapInsert(pendingInitializeMap, supercls, pending);
}


/***********************************************************************
* class_initialize.  Send the '+initialize' message on demand to any
* uninitialized class. Force initialization of superclasses first.（强制先初始化父类）
**********************************************************************/
// initialize 指定的类 cls，其中会调用类的 +initialize 方法
// 非常重要的一个函数，类的初始化和状态的转换都是在这个函数中做的
// 本函数被 lookUpImpOrForward() / object_setClass() / storeWeak() 三个函数调用
// 也就是说，一个类只有在被第一次使用的时候，才会被初始化
// 本函数有点复杂，理解不了的话，可以看这篇文章参考下：http://draveness.me/initialize/
// 不过相信我，它还没注释写得详细
void _class_initialize(Class cls)
{
    /*
     一定要谨记这是一个递归函数，所以要按照递归函数的思维去理解，不然很难搞懂它的意思
     这个函数的逻辑是：
     一. 如果有父类，且父类不是 initialized 状态，即没有完成初始化，就对父类递归调用本函数，当父类正在当前线程上初始化或者在其他线程上初始化完毕，就能继续往下走；如果没有父类（比如NSObject）或者父类已经是 initialized 状态就能直接往下走
     二. cls 类不在 isInitialized or isInitializing 状态，就将其标记为需要初始化，并调用 setInitializing 将状态设为 isInitializing 正在初始化
     三. 判断条件：
        i. 如果需要初始化：
            1. 记录下当前线程正在初始化 cls 类
            2. 向 cls 发送 SEL_initialize 消息，即调用 +initialize 方法
            3. ①. 如果父类也完成了初始化，就调用 _finishInitializing 函数将 cls 的状态变为 isInitialized，_finishInitializing 函数中还会将 cls 从当前线程正在初始化的类列表中删除，并且将 pendingInitializeMap 中等待 cls 类的子类们的状态都置为完成初始化
               ②. 如果父类还没有完成初始化，就调用 _finishInitializingAfter 将 cls 和父类 插入 pendingInitializeMap 中等待
        ii. 如果 cls 类正在初始化：
            1. 如果初始化 cls 的是当前线程，就直接返回，一切照常（这给了同一个线程上子类比父类先完成初始化的机会）
            2. 如果初始化 cls 的是其他线程，那悲剧了，必须把线程挂起，一直等待到 cls 完成初始化
        iii. 如果 cls 类已经完成初始化，就啥都不干
        iv. else 分支，进了 else 就是致命错误
     */
    
    // 元类不用 initialize
    assert(!cls->isMetaClass());

    Class supercls;
    BOOL reallyInitialize = NO; // 标记是否真正需要 Initialize

    // Make sure super is done initializing BEFORE beginning to initialize cls.
    // See note about deadlock above.
    // 确保 cls 开始 initialize 之前，父类已经是在 initializing 了
    supercls = cls->superclass;
    if (supercls  &&  !supercls->isInitialized()) { // 如果有父类，并且父类还没有完成初始化就将必须先将父类初始化
                                                    // 那么就有 2 个点很关键：
                                                    // 1. NSObject 类没有父类，所以能够直接初始化
                                                    // 2. 如果父类已经是 Initialized，那么子类就能直接初始化
        _class_initialize(supercls); // 将父类初始化，也是递归，递归的思想在这个函数中很重要，不然无法看明白这个函数
                                     // 比较关键的一点是，_class_initialize 在父类处于 initializing 状态的时候是直接 return 的，所以这时，子类就可以继续向下走，开始 initializing，而不是掉进无尽的递归里，
        
//                   OBObject
//                       |    ` OBPostLoader
//                   OFObject
//                   /     \
//        OWAddressEntry  OWController
//                          |
//                        OWConsoleController
//
//   回头看上面那个死锁的例子，如果这时 cls 是 OBPostLoader，父类 OBObject 还没有完成初始化，
//   就对父类 OBObject 调用 _class_initialize(OBObject)，但是看下面的代码，因为 OBObject 是处于 isInitializing 状态，
//   并且是在同一个线程，那么 _class_initialize(OBObject) 是直接返回的呀，没做其他事儿。
//   按照实际实验看，确实是没做什么事儿，所以 OBPostLoader 比 OBObject 先退出 +initialize
    }
    
    // 疑问：奇怪啊，如果这里是递归调用 _class_initialize，那么子类初始化时父类肯定已经初始化完毕了呀，怎么还会有子类初始化完，父类还没有初始化完的情况呢；即使检查到父类是在其他线程中初始化的，那么当前线程应该立即被挂起，肯定保证了返回的时候，父类已经被初始化完毕了呀
    // 自问自答：子类初始化时，父类并没有初始化完毕，而只是开始了初始化，进入了 +initialize 方法，在 +initialize 中可能调用了子类，所以子类也开始了初始化，并且因为它在父类的 +initialize 中，所以比父类先完成各自的 +initialize，这就有了子类比父类先完成初始化的情况
    
    
    // 只要满足任一条件，就可以往下走，开始初始化：
    // 1. 没有父类
    // 2. 父类已经完成初始化
    // 3. 父类正在同一个线程上初始化
    // 4. 父类在另一个线程上初始化完毕
    
    
    // Try to atomically set CLS_INITIALIZING.
    {
        // 加锁，是为了保证 atomically ，就是原子操作，保证线程安全
        // monitor_locker_t 类的构造函数中，会自动调用 enter() 方法上锁，当析构的时候,会调用 leave() 释放锁
        monitor_locker_t lock(classInitLock);
        
        // 如果 cls 既不是 isInitialized 状态，也不是 isInitializing 状态
        if (!cls->isInitialized() && !cls->isInitializing()) {
            // 就将它设为 Initializing 状态，表示正在执行 Initialize
            // 其实就是设置 RW_INITIALIZING 标志位
            cls->setInitializing();
            // 标记为真正需要 Initialize
            reallyInitialize = YES;
        }
        
        // 离开这个代码块，锁应该就被释放了
    }
    
    // 以下的每一个分支都是递归的返回点
    
    // 如果确实需要 Initialize
    if (reallyInitialize) {
        // We successfully set the CLS_INITIALIZING bit. Initialize the class.
        // 我们成功设置了 CLS_INITIALIZING 位，也就是将 cls 置为 isInitializing 状态
        // 接下来，开始 Initialize 这个类
        
        // Record that we're initializing this class so we can message it.
        // 记录下这个线程正在 initializing 这个类，这样我们可以给它发消息
        // 其实是将它的元类存在了线程数据里的一个结构体 initializingClasses 中，这个结构体保存当前线程正在初始化的类的列表
        _setThisThreadIsInitializingClass(cls);
        
        // Send the +initialize message.
        // Note that +initialize is sent to the superclass (again) if 
        // this class doesn't implement +initialize.
        
        // 初始化前记录一下
        if (PrintInitializing) {
            _objc_inform("INITIALIZE: calling +[%s initialize]",
                         cls->nameForLogging());
        }
        
        // 调用 +initialize，主要的初始化工作，就是调用这个方法 ↓ ↓ ↓ ↓ ↓ ↓ ↓ ↓ ↓ ↓ ↓ ↓
        // 注意：如果 cls 没有实现 +initialize 方法的话，它会被发给父类
        ((void(*)(Class, SEL))objc_msgSend)(cls, SEL_initialize);

        
        // 某个类的 +initialize 的方法不一定只被调用一次，至少有两种情况会被调用多次：
        // 子类显式调用 [super initialize];
        // 子类没有实现 +initialize 方法；
        // 但走 _class_initialize 函数经历初始化的过程，肯定只有一次
        
        // 初始化后也记录一下
        if (PrintInitializing) {
            _objc_inform("INITIALIZE: finished +[%s initialize]",
                         cls->nameForLogging());
        }        
        
        // Done initializing. 
        // If the superclass is also done initializing, then update 
        //   the info bits and notify waiting threads.
        // If not, update them later. (This can happen if this +initialize 
        //   was itself triggered from inside a superclass +initialize.)
        
        // 完成 initializing，说明上面调用 +initialize 方法是同步的
        // 如果父类也完成了 initializing，就更新 info 位，通知等待的线程们
        // 否则，稍后更新。（这会发生在，当这个类的 +initialize 是在一个父类的 +initialize 方法中被触发的时候，这个类的初始化做完了，但是因为是在父类的 +initialize 中做的，父类的 +initialize 方法还没有结束并返回，所以父类还没有完成 initializing）
        
        // 再加锁，同理，离开代码块，自动释放
        monitor_locker_t lock(classInitLock);
        
        if (!supercls  ||  supercls->isInitialized()) { // 如果没有父类或者父类已经 Initialized 过了
            // 设置 cls 完成 Initializing，它以及等待它的已经提早完成初始化的子类们都会被置为 Initialized 状态
            _finishInitializing(cls, supercls);
        } else { // 有父类，且父类还没有结束 Initializing，就在 pendingInitializeMap 里记录一下，
                 // 等待父类完成初始化后，才会将父类的子类们标记为 Initialized
            _finishInitializingAfter(cls, supercls);
        }
        
        return;
    }
    
    else if (cls->isInitializing()) { // 如果 cls 类正在初始化中
        // We couldn't set INITIALIZING because INITIALIZING was already set.
        // If this thread set it earlier, continue normally.
        // If some other thread set it, block until initialize is done.
        // It's ok if INITIALIZING changes to INITIALIZED while we're here, 
        //   because we safely check for INITIALIZED inside the lock 
        //   before blocking.
        
        // 如果当前线程正在初始化这个类，就直接返回。因为会有循环初始化的情况，所以这个是有可能出现的
        // 上面的死锁 Demo 就是这样的，因为 OFObject 类的父类 OBObject 类已经在 Initializing，
        // 所以可以直接 return，递归就开始一层层的返回，
        
        // 如果是其他线程正在初始化这个类，就阻塞等待，
        // 直到 cls 的状态由 INITIALIZING 变为 INITIALIZED，才恢复执行，保证了线程安全
        if (_thisThreadIsInitializingClass(cls)) {
            return;
        } else {
            monitor_locker_t lock(classInitLock); // 互斥锁加锁
            while (!cls->isInitialized()) { // 判断条件
                classInitLock.wait(); // wait 条件变量，这时互斥锁被释放，线程挂起，不占用 CPU 时间，
                                      // 直到条件变量被触发，会自动把互斥锁加锁
            }
            return; // 一直 wait 到 cls 被初始化完才 return
        }
    }
    
    else if (cls->isInitialized()) {
        // Set CLS_INITIALIZING failed because someone else already 
        //   initialized the class. Continue normally.
        // NOTE this check must come AFTER the ISINITIALIZING case.
        // Otherwise: Another thread is initializing this class. ISINITIALIZED 
        //   is false. Skip this clause. Then the other thread finishes 
        //   initialization and sets INITIALIZING=no and INITIALIZED=yes. 
        //   Skip the ISINITIALIZING clause. Die horribly.
        
        // 因为其他线程已经 initialized 这个类，就什么都不用干了
        return;
    }
    
    else { // 致命错误
        // We shouldn't be here. 
        _objc_fatal("thread-safe class init in objc runtime is buggy!");
    }
}
