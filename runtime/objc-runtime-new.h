/*
 * Copyright (c) 2005-2007 Apple Inc.  All Rights Reserved.
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

#ifndef _OBJC_RUNTIME_NEW_H
#define _OBJC_RUNTIME_NEW_H

#if __LP64__
typedef uint32_t mask_t;  // unsigned int  32 位 // x86_64 & arm64 asm are less efficient with 16-bits
#else
typedef uint16_t mask_t;  // unsigned short 16 位
#endif
typedef uintptr_t cache_key_t;  // 也就是 unsigned long

struct swift_class_t;

#pragma mark - bucket_t

// cache_t 中存的实体，单一的一个 key - value 对
// bucket 可以翻译为 槽

struct bucket_t {
private:
    cache_key_t _key;  // key，观察 objc-cache.mm 中 cache_key_t getKey(SEL sel) 方法
                       // key 只不过是 (cache_key_t)sel 将 sel 强转为 cache_key_t 类型
                       // 如果 SEL 也就是 objc_select 本质上是一个 char * 字符串的话，就说得通了
                       // 都是内存地址，强转没有问题
    IMP _imp;   // value，是指向方法的函数实现的指针，IMP 的定义在 objc.h

public:
    // 取得 key
    inline cache_key_t key() const {
        return _key;
    }
    // 取得 IMP
    inline IMP imp() const {
        return (IMP)_imp;
    }
    // 设置 key
    inline void setKey(cache_key_t newKey) {
        _key = newKey;
    }
    // 设置 IMP
    inline void setImp(IMP newImp) {
        _imp = newImp;
    }
    // 同时设置 key 和 IMP，
    // 因为不同的平台的实现不一样，所以没写在这里，实现在 objc-cache.mm 里
    // 同时设置 key 和 IMP，需要保证原子性(atomic)，所以用了汇编，这个很有意思
    void set(cache_key_t newKey, IMP newImp);
};

#pragma mark - cache_t

// 缓存结构体，被用在了 objc_class 中
// 方法实现都在 objc-cache.mm 中

struct cache_t {
    struct bucket_t *_buckets; // 存数据的，用数组表示的 hash 表
                               // 为什么要用散列表呢？因为散列表检索起来更快
    
    mask_t _mask;      // 数值上等于 capacity - 1
                       // 因为 capacity 都是 2 的幂
                       // 所以 _mask 都是 0b11  0b111  0b1111  0b11111 这样的数
                       // 在 cache_hash() 中哈希时起到了掩码的作用
                       // 还起到了代表最大的索引值的作用，因为索引从 0 开始，最大就是 capacity - 1，也就是 _mask
    
    mask_t _occupied;  // 被占用的槽位，因为缓存是以散列表的形式存在的，所以会有空槽，
                       // 而occupied表示当前被占用的数目

public:
    struct bucket_t *buckets(); // 取得 cache_t 存的所有 buckets
    mask_t mask();              // 取得 _mask
    mask_t occupied();          // 取得 _occupied
    void incrementOccupied();   // _occupied 加 1
    // 设置存储的 buckets 和 mask
    void setBucketsAndMask(struct bucket_t *newBuckets, mask_t newMask);
    
    void initializeToEmpty();   // 初始化得到一个空的 cache，结构体里所有 bit 都置为 0

    mask_t capacity();          // 取得容量
    
    bool isConstantEmptyCache();// 判断 buckets 自从初次创建后是否被用过
    
    bool canBeFreed();          // 判断是否需要释放旧的 _buckets 内存

    // 取得指定容量所需的内存大小
    static size_t bytesForCapacity(uint32_t cap);
    // 取得 end marker
    static struct bucket_t * endMarker(struct bucket_t *b, uint32_t cap);

    // 扩容
    void expand();
    
    // 为 _buckets 在堆中重新分配适应更大容量的内存区域
    // 如果可以的话，将老的 _buckets 放入垃圾桶
    void reallocate(mask_t oldCapacity, mask_t newCapacity);
    
    // _buckets 数组中存入新的 bucket 时，寻找第一个没有用过的 bucket
    // 或者命中 key 的 bucket，来存新的 bucket
    // 注意，objc_msgSend 中进行对类的方法缓存进行查找的实现在 objc-msg-arm.s 文件中的
    //     .macro CacheLookup 中，并不是这里的 find() 方法
    struct bucket_t * find(cache_key_t key, id receiver);
    
    // cache 出现错误，打印错误信息，然后程序挂掉
    static void bad_cache(id receiver, SEL sel, Class isa) __attribute__((noreturn));
};


// classref_t is unremapped class_t*
typedef struct classref * classref_t; // classref_t 是 unremapped 的类 类型，其实与 Class / objc_class * 没有什么区别
                                      // 只是专门用于 unremapped 的类

#pragma mark - entsize_list_tt

/***********************************************************************
* entsize_list_tt<Element, List, FlagMask>
* Generic implementation of an array of non-fragile（不易脆裂，也就是稳定的）structs.
*
* Element is the struct type (e.g. method_t)
* List is the specialization of entsize_list_tt (e.g. method_list_t)
* FlagMask is used to stash extra bits in the entsize field
*   (e.g. method list fixup markers)
**********************************************************************/
// entsize_list_tt 可以理解为一个容器，拥有自己的迭代器用于遍历所有元素。
// Element 表示元素类型，List 用于指定容器类型，
// 最后一个参数为标记位, 用来在 entsize field 里存放一些额外的 bits，也就是 flags
template <typename Element, typename List, uint32_t FlagMask>
struct entsize_list_tt {
    // entsize 和 flags 存在了一起，需要用 FlagMask 进行区分哪些 bits 里存的是 flags
    // entsize 就是每个元素的大小
    uint32_t entsizeAndFlags;
    uint32_t count; // 元素的总数
    Element first;  // 第一个元素，其他的元素紧跟在其后面

    // 取出 entsize
    uint32_t entsize() const {
        return entsizeAndFlags & ~FlagMask;
    }
    // 取出 flags
    uint32_t flags() const {
        return entsizeAndFlags & FlagMask;
    }

    // 取得指定 索引 处的元素，i <= count
    // 如果 i 等于 count，取得的就是最后一个元素的末尾地址
    Element& getOrEnd(uint32_t i) const { 
        assert(i <= count);
        // 从第一个元素开始，加上偏移量 i * 单个元素的大小
        // 就是 i 索引处的元素
        return *(Element *)((uint8_t *)&first + i*entsize()); 
    }
    // 取得指定 索引 处的元素
    // i 必须小于总数
    Element& get(uint32_t i) const { 
        assert(i < count);
        return getOrEnd(i);
    }

    // 取得整个 entsize_list_tt 对象以及其保存的所有元素占多少内存
    size_t byteSize() const {
        // sizeof(*this) 计算是对象本身占的大小，其中还包括了第一个元素
        // (count-1)*entsize() 计算的是除了第一个元素外，其他所有元素占的大小
        return sizeof(*this) + (count-1)*entsize();
    }

    // 拷贝对象
    List *duplicate() const {
        // memdup 里用 malloc 在堆中开辟了一块长度为 this->byteSize() 大小的内存
        // 并将 this 也就是当前对象的内存拷贝到其中
        return (List *)memdup(this, this->byteSize());
    }

    // 向前声明
    struct iterator;
    
    // 取得指向容器的第一个元素的迭代器，返回值是常量
    const iterator begin() const { 
        return iterator(*static_cast<const List*>(this), 0); 
    }
    // 取得指向容器的第一个元素的迭代器，返回值是变量，可以变
    iterator begin() { 
        return iterator(*static_cast<const List*>(this), 0); 
    }
    // 取得指向容器尾部的迭代器，注意是尾部，也就是最后一个元素的末尾，并不是最后的一个元素，返回值是常量
    const iterator end() const { 
        return iterator(*static_cast<const List*>(this), count); 
    }
    // 取得指向容器尾部的迭代器，注意是尾部，也就是最后一个元素的末尾，并不是最后的一个元素
    iterator end() { 
        return iterator(*static_cast<const List*>(this), count); 
    }

    // 向前声明
    struct iterator {
        uint32_t entsize; // 元素的大小
        uint32_t index;  // 当前的索引  // keeping track of this saves a divide in operator-
        
        Element* element;  // 指向当前的元素的指针

        typedef std::random_access_iterator_tag iterator_category; // 不知道干嘛的，也没有用到
        typedef Element value_type;  // 元素类型
        typedef ptrdiff_t difference_type;  // 索引的差值 delta 的类型
        typedef Element* pointer;    // 指针类型
        typedef Element& reference;  // 引用类型

        iterator() { }   // 默认的空的构造函数

        // 真正有用的构造函数，参数 list 是迭代器用在哪个 List 上
        // start 是当前的索引
        iterator(const List& list, uint32_t start = 0)
            : entsize(list.entsize())  // 记录 List 中单个元素的大小
            , index(start)   // 记录当前的索引
            , element(&list.getOrEnd(start))  // 保存当前的元素的地址
        { }

        // 迭代器向后移动 delta 个位置
        const iterator& operator += (ptrdiff_t delta) {
            // 计算出新元素的地址，保存起来
            element = (Element*)((uint8_t *)element + delta*entsize);
            // 索引也加上 delta
            index += (int32_t)delta;
            return *this;
        }
        // 与 += 相反，迭代器向前移动 delta 个位置
        const iterator& operator -= (ptrdiff_t delta) {
            element = (Element*)((uint8_t *)element - delta*entsize);
            index -= (int32_t)delta;
            return *this;
        }
        // 与 += 一样
        const iterator operator + (ptrdiff_t delta) const {
            return iterator(*this) += delta;
        }
        // 与 -= 一样
        const iterator operator - (ptrdiff_t delta) const {
            return iterator(*this) -= delta;
        }

        // 重载前缀 ++ ，原理还是用的上面重载的 +=
        iterator& operator ++ () {
            *this += 1;
            return *this;
        }
        // 重载前缀 -- ，原理还是用的上面重载的 -=
        iterator& operator -- () {
            *this -= 1; return *this;
        }
        
        // 重载后缀 ++ ，返回的 ++ 前的值，但本身已经做了加 1
        iterator operator ++ (int) {
            iterator result(*this);
            *this += 1;
            return result;
        }
        // 重载后缀 -- ，返回的 -- 前的值，但本身已经做了减 1
        iterator operator -- (int) {
            iterator result(*this);
            *this -= 1;
            return result;
        }

        // 取得当前迭代器与另一个迭代器的差值，差值就是索引的差值
        ptrdiff_t operator - (const iterator& rhs) const {
            return (ptrdiff_t)this->index - (ptrdiff_t)rhs.index;
        }

        // 重载 * 运算符，得到迭代器当前存的元素，得到的是引用类型，就是元素本身
        Element& operator * () const { return *element; }
        
        // 重载 -> 运算符，得到迭代器当前存的元素，得到的是指针类型，是指向元素的指针
        Element* operator -> () const { return element; }

        // 重载 & 运算符，得到迭代器当前存的元素，得到的是引用类型，就是元素本身
        operator Element& () const { return *element; }

        // 判断迭代器存的元素与另一个迭代器存的元素是否一致
        bool operator == (const iterator& rhs) const {
            return this->element == rhs.element;
        }
        // 与上面重载的 == 正好相反，判断迭代器存的元素与另一个迭代器存的元素是否不一致
        bool operator != (const iterator& rhs) const {
            return this->element != rhs.element;
        }

        // 判断 当前迭代器保存的元素的地址 是否比 另一个迭代器保存的元素的地址 靠前
        bool operator < (const iterator& rhs) const {
            return this->element < rhs.element;
        }
        // 判断 当前迭代器保存的元素的地址 是否比 另一个迭代器保存的元素的地址 靠后
        bool operator > (const iterator& rhs) const {
            return this->element > rhs.element;
        }
    };
};

#pragma mark - method_t

// 方法结构体
struct method_t {
    SEL name;          // 方法名，就是 SEL
    const char *types; // 方法类型，有的地方又称 method signature 方法签名
    IMP imp;           // 指向方法的函数实现的指针
    
    /* 
       一个结构体，用来做排序 Sort by selector address.
       只在 objc_runtime_new.m 中的 fixupMethodList 一个方法里用了
     */
    struct SortBySELAddress :
        public std::binary_function<const method_t&, const method_t&, bool>
    {
        // 按照 method_t 中的 name 字段进行排序，地址小的放前面
        // 这里只是排序的方式，实际做排序是用 std::stable_sort() 做的，这个函数是其中的参数
        // 见 fixupMethodList() 函数
        bool operator() (const method_t& lhs, const method_t& rhs) {
            return lhs.name < rhs.name;
        }
    };
};

#pragma mark - ivar_t

// 成员变量结构体
struct ivar_t {
#if __x86_64__
    // *offset was originally 64-bit on some x86_64 platforms.
    // We read and write only 32 bits of it.
    // Some metadata provides all 64 bits. This is harmless for unsigned 
    // little-endian values.
    // Some code uses all 64 bits. class_addIvar() over-allocates the 
    // offset for their benefit.
#endif
    int32_t *offset; // 偏移量 用 __OFFSETOFIVAR__ 计算
    const char *name; // 成员变量名  比如 "_name"
    const char *type; // 成员变量的类型 比如 "@\"NSString\""
    // alignment is sometimes -1; use alignment() instead
    uint32_t alignment_raw; // 对齐
    uint32_t size;  // 成员变量占多少内存

    // 取得对齐的值（即以多少字节对齐），因为 alignment_raw 有时为 -1，alignment() 会进行纠正，返回正确的值
    // 在 moveIvars() 和 reconcileInstanceVariables() 有用到
    // 用于遍历类的所有成员变量，哪个成员变量的 alignment 最大，类的所有成员变量们以它的 alignment 进行对齐布局
    uint32_t alignment() const {
        if (alignment_raw == ~(uint32_t)0) {
            return 1U << WORD_SHIFT;
        }
        return 1 << alignment_raw;
    }
};

#pragma mark - property_t

// 属性结构体
struct property_t {
    const char *name;  // 属性名，堆中分配
    const char *attributes; // 属性的特性字符串，标识了属性有哪些特性
                            // 该字符串是在堆中分配的
};

#pragma mark - method_list_t

// Two bits of entsize are used for fixup markers.
// 方法列表，是一个容器，继承自 entsize_list_tt，
// 元素类型是 method_t ，容器类型是 method_list_t
struct method_list_t : entsize_list_tt<method_t, method_list_t, 0x3> { // 0x3 就是 0b11
                                                                       // 即 flag 占 2 个 bit，用来放 fixedup markers
    
    bool isFixedUp() const; // 该 method_list_t 是否是 fixed-up 的，也就是唯一且有序的
    void setFixedUp(); // 设置该 method_list_t 是 fixed-up 的

    // 方法在容器中的索引
    uint32_t indexOfMethod(const method_t *meth) const {
        uint32_t i = 
            (uint32_t)(((uintptr_t)meth - (uintptr_t)this) / entsize());
        assert(i < count);
        return i;
    }
};

#pragma mark - ivar_list_t & property_list_t

// 成员变量列表
struct ivar_list_t : entsize_list_tt<ivar_t, ivar_list_t, 0> { // flag 占 0 个 bit
};

// 属性列表
struct property_list_t : entsize_list_tt<property_t, property_list_t, 0> { // flag 占 0 个 bit
};

#pragma mark - protocol_t

typedef uintptr_t protocol_ref_t;  // protocol_t *, but unremapped
                                   // 与 protocol_t * 一模一样，但是用于未重映射的协议

// Values for protocol_t->flags
// protocol_t->flags 里存的值
#define PROTOCOL_FIXED_UP_2 (1<<31) // 即最高的两位是 0b10   // must never be set by compiler
#define PROTOCOL_FIXED_UP_1 (1<<30) // 即最高的两位是 0b01   // must never be set by compiler
#define PROTOCOL_FIXED_UP_MASK (PROTOCOL_FIXED_UP_1 | PROTOCOL_FIXED_UP_2) 
                                    // 取标识 fixed-up 位的掩码，这里取到的就是最高的 2 位

// 协议结构体，继承自 objc_object
struct protocol_t : objc_object {
    const char *mangledName;    // 重整后的协议名称，为了兼容 swift 协议而准备的，
                                // 它在 objc_allocateProtocol() 中被赋值，
                                // 普通 oc 的协议重整前后的名字是一样的，而 swift 的协议重整前后名字不一样，
                                // 重整名字是编译器给出的，加了 swift 复杂前缀的，用于混编时区分 oc协议 和 swift协议，
                                // 而 demangledName 取消重整的名称，应该就是去掉前缀的正常的名字
    
    struct protocol_list_t *protocols;  // 子协议列表，见 protocol_addProtocol()
                                        // 又可以称为 incorporated protocols 合并的协议
    
    method_list_t *instanceMethods;  // 必选(required)的实例方法
    method_list_t *classMethods;   //  必选(required)的类方法
    method_list_t *optionalInstanceMethods; // 可选(optional)的实例方法
    method_list_t *optionalClassMethods;  // 可选(optional)的类方法
    
    property_list_t *instanceProperties;  // 实例属性，当前协议只支持 required 的实例属性，
                                          // 协议中也是可以添加属性的，
                                          // 不知道会不会生成成员变量，但生成 set 和 get 方法是一定有的
                                          // 比如 NSObject 协议，就有几个 readonly 的属性
    
    uint32_t size;   // 这个协议的大小，其中也包括了 extendedMethodTypes 整个数组的大小
    uint32_t flags;  // 标记 跟 PROTOCOL_FIXED_UP_1 / PROTOCOL_FIXED_UP_2 有关系
    
    // Fields below this point are not always present on disk.
    // 这句话的意思，好像是下面这几个成员变量不一定有，
    // 所以用到它们的时候都检查了下 size 是否足够大，比如 hasExtendedMethodTypesField() 和 protocol_t::demangledName()
    
    const char **extendedMethodTypes; // 扩展方法类型数组，每个元素是一个扩展类型字符串
    
    const char *_demangledName; // 取消重整的协议名称，为了兼容 swift 协议而准备的，
                                // 普通 oc 的协议重整前后的名字是一样的，而 swift 的协议重整前后名字不一样
                                // 见 demangledName()
                                // demangledName 取消重整的名称，应该就是去掉 swift 前缀的正常的名字

    const char *demangledName(); // 取得取消重整的协议名称

    const char *nameForLogging() {
        return demangledName();
    }

    bool isFixedUp() const;
    void setFixedUp();

    // 存在扩展方法类型的内存区域
    bool hasExtendedMethodTypesField() const {
        // 整个协议的大小超过了 extendedMethodTypes 前面的成员变量的总大小
        // 加上 extendedMethodTypes 指针本身的大小，那么 extendedMethodTypes 一定是有分配了内存的
        return size >= (offsetof(protocol_t, extendedMethodTypes) 
                        + sizeof(extendedMethodTypes));
    }
    
    // 是否有扩展方法类型
    bool hasExtendedMethodTypes() const {
        // 协议里存在扩展方法类型的内存区域，且 extendedMethodTypes 不为空
        return hasExtendedMethodTypesField() && extendedMethodTypes;
    }
};

#pragma mark - protocol_list_t

// 协议列表，注意，协议列表和 method_list_t 等不一样，没继承 entsize_list_tt
// 我猜，可能是跟协议列表里存的变量类型有关系
// protocol_ref_t list[0]; 数组里存的是协议的地址，即指针，而不是协议本身
// 这与 entsize_list_tt 不一样，entsize_list_tt 中直接存了 Element first; 元素本身
// 比如 method_list_t，继承自 entsize_list_tt，里面的元素就是 method_t，而不是 method_t *

struct protocol_list_t {
    // count is 64-bit by accident（偶然的）.
    uintptr_t count;  // 列表中协议的总数
    protocol_ref_t list[0]; // variable-size
                // 列表的首地址，列表中存的元素是 protocol_ref_t 结构体对象的地址，
                // protocol_ref_t 与 protocol_t * 一模一样，但是用于未重映射的协议

    // 对象本身和所存储的所有协议的总大小
    size_t byteSize() const {
        // sizeof(*this) 是对象本身的大小
        // count*sizeof(list[0]) 是存储的所有协议的大小
        // 因为成员变量 protocol_ref_t list[0] 存的只是第一个元素的地址，即数组首地址，而并不是第一个元素本身
        // 所以这里用了总数 count ，并不是 count-1，这与 entsize_list_tt 的做法是不一样的
        return sizeof(*this) + count*sizeof(list[0]);
    }

    // 复制一份整个列表
    protocol_list_t *duplicate() const {
        return (protocol_list_t *)memdup(this, this->byteSize());
    }

    // 冒充迭代器，类型是指向 protocol_ref_t 的指针，protocol_ref_t 其实也是个指针
    // 所以是指向指针的指针
    typedef protocol_ref_t* iterator;
    // 常量迭代器
    typedef const protocol_ref_t* const_iterator;

    // 取得列表的头，且无法更改
    const_iterator begin() const {
        return list;
    }
    // 取得列表的头，但可以更改
    iterator begin() {
        return list;
    }
    // 取得列表的尾，且无法更改
    const_iterator end() const {
        return list + count;
    }
    // 取得列表的尾，但可以更改
    iterator end() {
        return list + count;
    }
};

// 本地的盖了戳的 category，即已经被添加进了 unattachedCategories
struct locstamped_category_t {
    category_t *cat;   //  category
    struct header_info *hi;  // 所属的 header，即所属的镜像
};

// 存放 locstamped_category_t 的列表
struct locstamped_category_list_t {
    uint32_t count;  // 数组有几个元素
#if __LP64__
    uint32_t reserved;
#endif
    locstamped_category_t list[0]; // 数组的起始地址
};


// class_data_bits_t is the class_t->data field (class_rw_t pointer plus flags)
// The extra bits are optimized for the retain/release and alloc/dealloc paths.

// ---------- class_ro_t 用的 ------------

// Values for class_ro_t->flags
// These are emitted by the compiler（是编译器发出的） and are part of the ABI.
// class is a metaclass
#define RO_META               (1<<0)  // 是否是元类
// class is a root class
#define RO_ROOT               (1<<1)  // 是否是根类
// class has .cxx_construct/destruct implementations
#define RO_HAS_CXX_STRUCTORS  (1<<2)  // 是否有 C++ 构造器和析构器
// class has +load implementation
// #define RO_HAS_LOAD_METHOD    (1<<3) // 确实是被注释了，不要怀疑
// class has visibility=hidden set
#define RO_HIDDEN             (1<<4)  // 类被隐藏了 ？
// class has attribute(objc_exception): OBJC_EHTYPE_$_ThisClass is non-weak
#define RO_EXCEPTION          (1<<5)  // 被标记上 attribute(objc_exception)
// this bit is available for reassignment
// #define RO_REUSE_ME           (1<<6) 
// class compiled with -fobjc-arc (automatic retain/release)
#define RO_IS_ARR             (1<<7)  // ARC 自动管理引用计数
// class has .cxx_destruct but no .cxx_construct (with RO_HAS_CXX_STRUCTORS)
#define RO_HAS_CXX_DTOR_ONLY  (1<<8)  // 有 C++ 析构器，但是没有 C++ 构造器

// class is in an unloadable bundle - must never be set by compiler
#define RO_FROM_BUNDLE        (1<<29) // 类处于没有被 load 的 bundle 中
// class is unrealized future class - must never be set by compiler
#define RO_FUTURE             (1<<30) // 类没有被 realized 但是被 future 了
                                      // future 模式：http://ymbian.blog.51cto.com/725073/147086
                                      // 就是说，现在没有 realized，一会儿就 realized 了
// class is realized - must never be set by compiler
#define RO_REALIZED           (1<<31) // 类是否已经被 realized

// ---------- class_rw_t 用的 ------------

// Values for class_rw_t->flags
// These are not emitted by the compiler（不是编译器发出的） and are never used in class_ro_t.
// Their presence（存在） should be considered in future ABI( Application Binary Interface 应用程序二进制接口 ) versions.
// class_t->data is class_rw_t, not class_ro_t
#define RW_REALIZED           (1<<31)  // 类是否已经被 realized
// class is unresolved future class
#define RW_FUTURE             (1<<30)  // 类还没有 realized，但是已经 future 了，
                                       // 就是现在暂时没有 realized，一会儿就 realized
// class is initialized
#define RW_INITIALIZED        (1<<29)  // 类已经被初始化
// class is initializing
#define RW_INITIALIZING       (1<<28)  // 类正在被初始化
// class_rw_t->ro is heap copy of class_ro_t
#define RW_COPIED_RO          (1<<27)  // class_rw_t->ro 是 class_ro_t 堆拷贝过来的
                                       // 即先在堆中分配内存，然后将 ro 拷贝过去，这时的 ro 就是可读可写的
// class allocated but not yet registered
#define RW_CONSTRUCTING       (1<<26)  // 类已经被 allocated，但是没有注册
// class allocated and registered
#define RW_CONSTRUCTED        (1<<25)  // 类已经 allocated，并且已经注册
// GC:  class has unsafe finalize method
#define RW_FINALIZE_ON_MAIN_THREAD (1<<24)  // 在主线程结束，与 initialize 对应
// class +load has been called
#define RW_LOADED             (1<<23)  // 已经被 load

#if !SUPPORT_NONPOINTER_ISA   // 如果不支持 SUPPORT_NONPOINTER_ISA
// class instances may have associative references
#define RW_INSTANCES_HAVE_ASSOCIATED_OBJECTS (1<<22) // 类的实例变量有关联对象
#endif


// class has instance-specific GC layout
#define RW_HAS_INSTANCE_SPECIFIC_LAYOUT (1 << 21)  // 指定了 Instance-specific object layout，
                                                   // 见 _class_setIvarLayoutAccessor
// available for use
// #define RW_20       (1<<20)
// class has started realizing but not yet completed it
#define RW_REALIZING          (1<<19)   // 类开始 realizing 但还没有结束

// NOTE: MORE RW_ FLAGS DEFINED BELOW


// Values for class_rw_t->flags or class_t->bits
// These flags are optimized for retain/release and alloc/dealloc
// 64-bit stores more of them in class_t->bits to reduce pointer indirection.

#if !__LP64__   // 如果不是 64 位的

// class or superclass has .cxx_construct implementation
#define RW_HAS_CXX_CTOR       (1<<18)
// class or superclass has .cxx_destruct implementation
#define RW_HAS_CXX_DTOR       (1<<17)
// class or superclass has default alloc/allocWithZone: implementation
// Note this is is stored in the metaclass.
#define RW_HAS_DEFAULT_AWZ    (1<<16)
// class's instances requires raw isa
// not tracked for 32-bit because it only applies to non-pointer isa
// #define RW_REQUIRES_RAW_ISA

// class is a Swift class
#define FAST_IS_SWIFT         (1UL<<0)
// class or superclass has default retain/release/autorelease/retainCount/
//   _tryRetain/_isDeallocating/retainWeakReference/allowsWeakReference
#define FAST_HAS_DEFAULT_RR   (1UL<<1)
// data pointer
#define FAST_DATA_MASK        0xfffffffcUL

#elif 1   // 如果是 64 位的

// Leaks-compatible(兼容内存泄漏？) version that steals low bits only.

// class or superclass has .cxx_construct implementation
#define RW_HAS_CXX_CTOR       (1<<18)  // 是否有 C++ 的构造器
// class or superclass has .cxx_destruct implementation
#define RW_HAS_CXX_DTOR       (1<<17)  // 是否有 C++ 的析构器
// class or superclass has default alloc/allocWithZone: implementation
// Note this is is stored in the metaclass.
#define RW_HAS_DEFAULT_AWZ    (1<<16)  // 是否有默认的 allocWithZone

// class is a Swift class
#define FAST_IS_SWIFT           (1UL<<0)  // 用于判断 Swift 类
// class or superclass has default retain/release/autorelease/retainCount/
//   _tryRetain/_isDeallocating/retainWeakReference/allowsWeakReference
#define FAST_HAS_DEFAULT_RR     (1UL<<1)  // 当前类或者父类含有默认的 retain/release/autorelease/retainCount/_tryRetain/_isDeallocating/retainWeakReference/allowsWeakReference 方法
// class's instances requires raw isa
#define FAST_REQUIRES_RAW_ISA   (1UL<<2)  // 当前类的实例需要 raw isa
// data pointer
#define FAST_DATA_MASK          0x00007ffffffffff8UL // 存 class_rw_t 结构体的位置

#else    // 靠，上面是 #elif 1 ，这个 #else 会走 ？？？？

// Leaks-incompatible version that steals lots of bits.

// class is a Swift class
#define FAST_IS_SWIFT           (1UL<<0)  // 是否是 swift 类
// class's instances requires raw isa
#define FAST_REQUIRES_RAW_ISA   (1UL<<1)  // 是否需要 raw isa
// class or superclass has .cxx_destruct implementation
//   This bit is aligned with isa_t->hasCxxDtor to save an instruction.
#define FAST_HAS_CXX_DTOR       (1UL<<2)  // 类或者父类是否有 C++ 析构器
// data pointer
#define FAST_DATA_MASK          0x00007ffffffffff8UL  // 存 class_rw_t 结构体的位置
// class or superclass has .cxx_construct implementation
#define FAST_HAS_CXX_CTOR       (1UL<<47) // 类或者父类是否有 C++ 构造器
// class or superclass has default alloc/allocWithZone: implementation
// Note this is is stored in the metaclass.
#define FAST_HAS_DEFAULT_AWZ    (1UL<<48) // 是否用的是默认的 allocWithZone
// class or superclass has default retain/release/autorelease/retainCount/
//   _tryRetain/_isDeallocating/retainWeakReference/allowsWeakReference
#define FAST_HAS_DEFAULT_RR     (1UL<<49) // 类或者父类是否用的是默认的 retain/release...
// summary bit for fast alloc path: !hasCxxCtor and 
//   !requiresRawIsa and instanceSize fits into shiftedSize
#define FAST_ALLOC              (1UL<<50) // 是否可以快速 alloc，
                                          // 快速 alloc ，必须没有 c++ 构造器，不需要 raw isa
                                          // 还要将需要给成员变量分配的内存大小存在 shiftedSize 中，见 FAST_SHIFTED_SIZE_SHIFT
// instance size in units of 16 bytes
//   or 0 if the instance size is too big in this field
//   This field must be LAST
#define FAST_SHIFTED_SIZE_SHIFT 51 // 快速 alloc 时，给成员变量分配的大小，单位是 16 字节
                                   // 也就是说存的数是实际大小的 1/16，取值的时候需要乘以 16才是实际的大小

// FAST_ALLOC means
//   FAST_HAS_CXX_CTOR is set          // 没有 C++ 构造器
//   FAST_REQUIRES_RAW_ISA is not set  // 不需要 raw isa
//   FAST_SHIFTED_SIZE is not zero     // shiftedSize 不是 0
// FAST_ALLOC does NOT check FAST_HAS_DEFAULT_AWZ because that 
// bit is stored on the metaclass.
#define FAST_ALLOC_MASK  (FAST_HAS_CXX_CTOR | FAST_REQUIRES_RAW_ISA) // 我猜是用来判断是否支持 fast alloc
#define FAST_ALLOC_VALUE (0)     // 快速 alloc 时，将分配的内存初始化为 0

#endif

/*  例子   完整代码见 objc4/TestCase/TestNSObject-太经典 别删/TestNSObject
 
#ifndef _REWRITER_typedef_AXPerson
#define _REWRITER_typedef_AXPerson
typedef struct objc_object AXPerson;   // AXPerson 只是 objc_object 的别名
                                       // 所有类都只是 objc_object 类罢了
typedef struct {} _objc_exc_AXPerson;
#endif

 // 用来记录属性 name 所对应的成员 _name 位于 AXPerson_IMPL 结构体中的偏移量的
extern "C" unsigned long OBJC_IVAR_$_AXPerson$_name;
 
struct AXPerson_IMPL {     // 类对应的 C 结构体，用来放父类的成员变量 和 本类的成员变量
    struct NSObject_IMPL NSObject_IVARS; // 父类的成员变量
    NSString *_name;     // 成员变量 _name
};

// @property (nonatomic,copy) NSString *name;
<!-- @end -->


// @implementation AXPerson

// AXPerson 类中属性 name 的 get 方法
// 其实只是一个全局的 C 函数
static NSString * _I_AXPerson_name(AXPerson * self, SEL _cmd) { 
    return (*(NSString **)((char *)self + OBJC_IVAR_$_AXPerson$_name)); 
}
extern "C" __declspec(dllimport) void objc_setProperty (id, SEL, long, id, bool, bool);
 
// AXPerson 类中属性 name 的 set 方法
static void _I_AXPerson_setName_(AXPerson * self, SEL _cmd, NSString *name) {
    objc_setProperty (self, _cmd, __OFFSETOFIVAR__(struct AXPerson, _name), (id)name, 0, 1);
 }
// @end


int main(int argc, const char * argv[]) {
    <!-- @autoreleasepool --> { __AtAutoreleasePool __autoreleasepool;
        NSObject * obj = ((NSObject *(*)(id, SEL))(void *)objc_msgSend)((id)((NSObject *(*)(id, SEL))(void *)objc_msgSend)((id)objc_getClass("NSObject"), sel_registerName("alloc")), sel_registerName("init"));
        NSLog((NSString *)&__NSConstantStringImpl__var_folders_cp_sc2q63f937j88dcxp23f471w0000gn_T_main_e0087b_mi_0, obj);
    }
    return 0;
}
 
struct _prop_t {
    const char *name;
    const char *attributes;
};

struct _protocol_t;

struct _objc_method {
    struct objc_selector * _cmd;
    const char *method_type;
    void  *_imp;
};

struct _protocol_t {
    void * isa;  // NULL
    const char *protocol_name;
    const struct _protocol_list_t * protocol_list; // super protocols
    const struct method_list_t *instance_methods;
    const struct method_list_t *class_methods;
    const struct method_list_t *optionalInstanceMethods;
    const struct method_list_t *optionalClassMethods;
    const struct _prop_list_t * properties;
    const unsigned int size;  // sizeof(struct _protocol_t)
    const unsigned int flags;  // = 0
    const char ** extendedMethodTypes;
};

struct _ivar_t {
    unsigned long int *offset;  // pointer to ivar offset location
    const char *name;
    const char *type;
    unsigned int alignment;
    unsigned int  size;
};

struct _class_ro_t {
    unsigned int flags;
    unsigned int instanceStart;
    unsigned int instanceSize;
    unsigned int reserved;
    const unsigned char *ivarLayout;
    const char *name;
    const struct _method_list_t *baseMethods;
    const struct _objc_protocol_list *baseProtocols;
    const struct _ivar_list_t *ivars;
    const unsigned char *weakIvarLayout;
    const struct _prop_list_t *properties;
};

struct _class_t {
    struct _class_t *isa;
    struct _class_t *superclass;
    void *cache;
    void *vtable;
    struct _class_ro_t *ro;
};

struct _category_t {
    const char *name;
    struct _class_t *cls;
    const struct _method_list_t *instance_methods;
    const struct _method_list_t *class_methods;
    const struct _protocol_list_t *protocols;
    const struct _prop_list_t *properties;
};
extern "C" __declspec(dllimport) struct objc_cache _objc_empty_cache;
#pragma warning(disable:4273)

 
 // 计算 OBJC_IVAR_$_AXPerson$_name ，
 // 也就是属性 name 所对应的成员 _name 位于 AXPerson_IMPL 结构体中的偏移量
 // 原理是用 __OFFSETOFIVAR__
 // 它是一个宏定义：
 //    #define __OFFSETOFIVAR__(TYPE, MEMBER) ((long long) &((TYPE *)0)->MEMBER)
 
extern "C" unsigned long int OBJC_IVAR_$_AXPerson$_name __attribute__ ((used, section ("__DATA,__objc_ivar"))) = __OFFSETOFIVAR__(struct AXPerson, _name);

 
// AXPerson 类的成员变量列表
static struct <!-- _ivar_list_t --> {
    unsigned int entsize;  // sizeof(struct _prop_t)
    unsigned int count;
    struct _ivar_t ivar_list[1];
} _OBJC_$_INSTANCE_VARIABLES_AXPerson __attribute__ ((used, section ("__DATA,__objc_const"))) = {
    sizeof(_ivar_t),  // 每个成员变量占的空间
    1,  // 一共有几个成员变量
        // 成员变量列表
    {
        {
            (unsigned long int *)&OBJC_IVAR_$_AXPerson$_name, 
                             // 成员变量 name 位于类中的偏移量
            "_name",         // 名称
            "@\"NSString\"", // 类型，这里是 NSString 类型
            3,               // aligment 按 3 个字节对齐 ？？？
            8                // size 大小  因为是指针类型，并且是64位，所以占 8 个字节
        }
    }
};

// AXPerson 类的方法列表
static struct <!-- _method_list_t --> {
    unsigned int entsize;  // sizeof(struct _objc_method)
    unsigned int method_count;
    struct _objc_method method_list[2];
} _OBJC_$_INSTANCE_METHODS_AXPerson __attribute__ ((used, section ("__DATA,__objc_const"))) = {
    sizeof(_objc_method),  // 每个方法占的空间，也就是下面的 _objc_method 结构体对象占的空间
    2,  // 有 2 个方法，都是 _objc_method 结构体的对象，_objc_method 的声明在上面可以找到
    {   // 方法列表：
        //     1、属性 name 的 get 方法
        {
            (struct objc_selector *)"name",  // _cmd
            "@16@0:8",                       // method_type
            (void *)_I_AXPerson_name         // _imp 指向方法所对应的函数实现的指针
                                             //     方法本质上只是一个全局的 C 函数
                                             //     见上面的 _I_AXPerson_name 函数
        },
        //     2、属性 name 的 set 方法
        {
            (struct objc_selector *)"setName:", 
            "v24@0:8@16", 
            (void *)_I_AXPerson_setName_
        }
    }
};

 // 属性列表
static struct <!-- _prop_list_t --> {
    unsigned int entsize;  // sizeof(struct _prop_t)
    unsigned int count_of_properties;
    struct _prop_t prop_list[1];
} _OBJC_$_PROP_LIST_AXPerson __attribute__ ((used, section ("__DATA,__objc_const"))) = {
    sizeof(_prop_t),   // 每个属性占的空间
    1,                 // 一共有几个属性
    {                  // 属性列表
        {
            "name",    // 属性名
            "T@\"NSString\",C,N,V_name"  // 属性有哪些 attributes
        }
    }
};
 
static struct _class_ro_t _OBJC_METACLASS_RO_$_AXPerson __attribute__ ((used, section ("__DATA,__objc_const"))) = {
    1,
    sizeof(struct _class_t),
    sizeof(struct _class_t),
    (unsigned int)0,
    0,
    "AXPerson",
    0,
    0,
    0,
    0,
    0,
};

 // AXPerson 类的 ro
static struct _class_ro_t _OBJC_CLASS_RO_$_AXPerson __attribute__ ((used, section ("__DATA,__objc_const"))) = {
    0,         // flags
    __OFFSETOFIVAR__(struct AXPerson, _name), // instanceStart  成员变量 _name 开始的位置
    sizeof(struct AXPerson_IMPL),  // instanceSize  成员变量的总大小
    (unsigned int)0,    // reserved
    0,                  // ivarLayout
    "AXPerson",         // name
    (const struct _method_list_t *)&_OBJC_$_INSTANCE_METHODS_AXPerson, 
                    // baseMethodList
    0,              // baseProtocols
    (const struct _ivar_list_t *)&_OBJC_$_INSTANCE_VARIABLES_AXPerson,
                    // ivars
    0,              // weakIvarLayout
    (const struct _prop_list_t *)&_OBJC_$_PROP_LIST_AXPerson,
                    // baseProperties
};
*/

#pragma mark -
#pragma mark - class_ro_t

// class_ro_t 用来存储类在编译期就已经确定的属性、方法以及遵循的协议
// 上面的例子，AXPerson 类对应的 class_ro_t 结构体对象 _OBJC_CLASS_RO_$_AXPerson
// 就是在编译器就确定的, 细看，结构体里的字段 与 下面 class_ro_t 里的字段是一一对应的
//
// RO 就是 Read Only
struct class_ro_t {
    uint32_t flags; // 利用 bit 位存了很多信息，其中包括是否是元类等
    uint32_t instanceStart; // 结构体中实例变量开始的地址
    uint32_t instanceSize;  // 实例变量的大小
#ifdef __LP64__
    uint32_t reserved;  // 64 位系统下，才有这个字段。 保留字段... 不用深究
#endif

    const uint8_t * ivarLayout; // 记录了哪些是 strong 的 ivar，
                                // 也有可能是 
    
    const char * name;   // 从上面的实例看，应该是类本身的名字
    
    method_list_t * baseMethodList;  // 基本方法列表，存储编译期确定的方法
    protocol_list_t * baseProtocols; // 基本协议列表，存储编译期确定的协议
    const ivar_list_t * ivars;       // 类的成员变量列表，存储编译期确定的成员变量
    
    const uint8_t * weakIvarLayout;  // 记录了哪些是 weak 的 ivar
    
    /*
     参考 ：http://blog.sunnyxx.com/2015/09/13/class-ivar-layout/
     
     ivar (instance variable) 也是可以指定修饰符的
     这使得 ivar (instance variable) 可以像属性一样在 ARC 下进行正确的引用计数管理
     
     ivarLayout 和 weakIvarLayout 分别记录了哪些 ivar 是 strong 或是 weak，都未记录的就是基本类型和 __unsafe_unretained 的对象类型。
     
     @interface Sark : NSObject {
        __strong id _gayFriend; // 无修饰符的对象默认会加 __strong
        __weak id _girlFriend;
        __unsafe_unretained id _company;
     }
     @end
     */
    property_list_t *baseProperties; // 基本属性列表，存储编译期确定的属性

    // 获取基本方法列表
    method_list_t *baseMethods() const {
        return baseMethodList;
    }
};


/***********************************************************************
* list_array_tt<Element, List>
* Generic implementation for metadata that can be augmented by categories.
*
* Element is the underlying metadata type (e.g. method_t)
* List is the metadata's list type (e.g. method_list_t)
*
* A list_array_tt has one of three values:
* - empty
* - a pointer to a single list
* - an array of pointers to lists
*
 
 Element 是元数据类型，比如 method_t
 List 是元数据的列表类型，比如 method_list_t
 
 一个 list_array_tt 的值可能有三种情况：
 - 空的
 - 一个指针指向一个单独的列表
 - 一个数组，数组中都是指针，每个指针分别指向一个列表
 
* countLists/beginLists/endLists iterate the metadata lists
* count/begin/end iterate the underlying metadata elements
**********************************************************************/
template <typename Element, typename List>
class list_array_tt {
    struct array_t {
        uint32_t count;
        List* lists[0];

        static size_t byteSize(uint32_t count) {
            return sizeof(array_t) + count*sizeof(lists[0]);
        }
        size_t byteSize() {
            return byteSize(count);
        }
    };

 protected:
    class iterator {
        List **lists;
        List **listsEnd;
        typename List::iterator m, mEnd;

     public:
        iterator(List **begin, List **end) 
            : lists(begin), listsEnd(end)
        {
            if (begin != end) {
                m = (*begin)->begin();
                mEnd = (*begin)->end();
            }
        }

        const Element& operator * () const {
            return *m;
        }
        Element& operator * () {
            return *m;
        }

        bool operator != (const iterator& rhs) const {
            if (lists != rhs.lists) return true;
            if (lists == listsEnd) return false;  // m is undefined
            if (m != rhs.m) return true;
            return false;
        }

        const iterator& operator ++ () {
            assert(m != mEnd);
            m++;
            if (m == mEnd) {
                assert(lists != listsEnd);
                lists++;
                if (lists != listsEnd) {
                    m = (*lists)->begin();
                    mEnd = (*lists)->end();
                }
            }
            return *this;
        }
    };

 private:
    union {
        List* list;
        uintptr_t arrayAndFlag;
    };

    bool hasArray() const {
        return arrayAndFlag & 1;
    }

    array_t *array() {
        return (array_t *)(arrayAndFlag & ~1);
    }

    void setArray(array_t *array) {
        arrayAndFlag = (uintptr_t)array | 1;
    }

 public:

    uint32_t count() {
        uint32_t result = 0;
        for (auto lists = beginLists(), end = endLists(); 
             lists != end;
             ++lists)
        {
            result += (*lists)->count;
        }
        return result;
    }

    iterator begin() {
        return iterator(beginLists(), endLists());
    }

    iterator end() {
        List **e = endLists();
        return iterator(e, e);
    }


    uint32_t countLists() {
        if (hasArray()) {
            return array()->count;
        } else if (list) {
            return 1;
        } else {
            return 0;
        }
    }

    List** beginLists() {
        if (hasArray()) {
            return array()->lists;
        } else {
            return &list;
        }
    }

    List** endLists() {
        if (hasArray()) {
            return array()->lists + array()->count;
        } else if (list) {
            return &list + 1;
        } else {
            return &list;
        }
    }

    void attachLists(List* const * addedLists, uint32_t addedCount) {
        if (addedCount == 0) return;

        if (hasArray()) {
            // many lists -> many lists
            uint32_t oldCount = array()->count;
            uint32_t newCount = oldCount + addedCount;
            setArray((array_t *)realloc(array(), array_t::byteSize(newCount)));
            array()->count = newCount;
            memmove(array()->lists + addedCount, array()->lists, 
                    oldCount * sizeof(array()->lists[0]));
            memcpy(array()->lists, addedLists, 
                   addedCount * sizeof(array()->lists[0]));
        }
        else if (!list  &&  addedCount == 1) {
            // 0 lists -> 1 list
            list = addedLists[0];
        } 
        else {
            // 1 list -> many lists
            List* oldList = list;
            uint32_t oldCount = oldList ? 1 : 0;
            uint32_t newCount = oldCount + addedCount;
            setArray((array_t *)malloc(array_t::byteSize(newCount)));
            array()->count = newCount;
            if (oldList) array()->lists[addedCount] = oldList;
            memcpy(array()->lists, addedLists, 
                   addedCount * sizeof(array()->lists[0]));
        }
    }

    void tryFree() {
        if (hasArray()) {
            for (uint32_t i = 0; i < array()->count; i++) {
                try_free(array()->lists[i]);
            }
            try_free(array());
        }
        else if (list) {
            try_free(list);
        }
    }

    template<typename Result>
    Result duplicate() {
        Result result;

        if (hasArray()) {
            array_t *a = array();
            result.setArray((array_t *)memdup(a, a->byteSize()));
            for (uint32_t i = 0; i < a->count; i++) {
                result.array()->lists[i] = a->lists[i]->duplicate();
            }
        } else if (list) {
            result.list = list->duplicate();
        } else {
            result.list = nil;
        }

        return result;
    }
};

// 方法数组，每个元素都是一个方法列表 method_list_t，base methods list 放在最后
class method_array_t : 
    public list_array_tt<method_t, method_list_t> 
{
    typedef list_array_tt<method_t, method_list_t> Super;

 public:
    // 取得分类方法列表的起点，其实就是 array 的头，因为前面的元素都是分类方法列表，只有最后一个元素可能是 base methods 方法列表
    method_list_t **beginCategoryMethodLists() {
        return beginLists();
    }
    
    // 取得分类方法列表的尾部，如果没有 base methods ，则尾部就是 array 的尾部，否则就是尾部的前一个元素
    method_list_t **endCategoryMethodLists(Class cls);

    method_array_t duplicate() {
        return Super::duplicate<method_array_t>();
    }
};


class property_array_t : 
    public list_array_tt<property_t, property_list_t> 
{
    typedef list_array_tt<property_t, property_list_t> Super;

 public:
    property_array_t duplicate() {
        return Super::duplicate<property_array_t>();
    }
};


class protocol_array_t : 
    public list_array_tt<protocol_ref_t, protocol_list_t> 
{
    typedef list_array_tt<protocol_ref_t, protocol_list_t> Super;

 public:
    protocol_array_t duplicate() {
        return Super::duplicate<protocol_array_t>();
    }
};

#pragma mark -
#pragma mark - class_rw_t

// RW 就是 Read Write 可读可写
struct class_rw_t {
    
    uint32_t flags; // 存了是否有 C++ 构造器、C++ 析构器、默认 RR 等信息
    
    uint32_t version; // 版本，元类是 7，普通类是 0

    const class_ro_t *ro; // 指向 ro 的指针，ro 中存储了当前类在编译期就已经确定的属性、方法以及遵循的协议
                          // 成员变量也在其中

    method_array_t methods;  // 方法列表数组，每个元素是一个指针，指向一个方法列表 method_list_t，
                             // 前面是分类方法列表，一个分类一个列表，base methods list放在最后
    property_array_t properties; // 属性列表数组
    protocol_array_t protocols;  // 协议列表数组

    Class firstSubclass;    // 第一个子类
    Class nextSiblingClass; // 兄弟类
                            // 由此看来，类与类之间的关系是由树来管理的
                            // 从 foreach_realized_class_and_subclass_2 方法中对子类的遍历
                            // 可以看到确实是如此

    char *demangledName; // 取消重整的名字，为了兼容 swift 而准备的，普通 OC 类，重整前后的名字是一样的，
                         // 而 swift 类重整前后的名字不一样，见 objc_class::demangledName()
                         // 取消重整的名字，没有乱七八糟的字符，看上去正常一点

    // 将 set 给定的 bit 位设为 1
    void setFlags(uint32_t set) 
    {
        // Atomic bitwise OR(按位或) of two 32-bit values with barrier
        // 参考：http://blog.csdn.net/swj6125/article/details/9791085
        OSAtomicOr32Barrier(set, &flags);
    }

    // 将 clear 给定的 bit 位清为 0
    void clearFlags(uint32_t clear) 
    {
        // 按位异或
        OSAtomicXor32Barrier(clear, &flags);
    }

    // set and clear must not overlap（不能重叠）
    // set 和 clear 同时进行，将 set 给定的 bit 位设为 1，将 clear 给定的 bit 位清为 0
    void changeFlags(uint32_t set, uint32_t clear) 
    {
        // set 和 clear 不能有任何一位都等于 1，即 set 和 clear 不能重叠
        assert((set & clear) == 0);

        uint32_t oldf, newf;
        do {
            oldf = flags;
            newf = (oldf | set) & ~clear;
        } while (!OSAtomicCompareAndSwap32Barrier(oldf, newf, (volatile int32_t *)&flags));
                     // 比较 oldf 和 flags内存处的值，可能就是保证中间过程中，flags处的值没变化
                     // 如果比较结果是一样的，那么就将 newf 存到 flags 处
    }
};

#pragma mark -
#pragma mark - class_data_bits_t

struct class_data_bits_t {

    // Values are the FAST_ flags above.
    uintptr_t bits; // 只有这个一个成员变量，所有数据都存在这里
                    // 1. 在 realized 之前，bits 存的是 class_ro_t，
                    // 2. realized 后，bits 存 class_rw_t ，class_rw_t 里的 ro 变量存 class_ro_t
private:
    // 取得指定 bit 处的数据
    bool getBit(uintptr_t bit)
    {
        return bits & bit;
    }

#if FAST_ALLOC  // 如果支持快速 alloc
    
    // 不知道干嘛的
    // 看字面意思，好像是如果是支持 fast alloc 的话，更新需要做一些调整
    static uintptr_t updateFastAlloc(uintptr_t oldBits, uintptr_t change)
    {
        if (change & FAST_ALLOC_MASK) {
            if (((oldBits & FAST_ALLOC_MASK) == FAST_ALLOC_VALUE)  &&  
                ((oldBits >> FAST_SHIFTED_SIZE_SHIFT) != 0)) 
            {
                oldBits |= FAST_ALLOC;
            } else {
                oldBits &= ~FAST_ALLOC;
            }
        }
        return oldBits;
    }
#else
    // 如果是不支持 fast alloc 就直接返回旧值
    static uintptr_t updateFastAlloc(uintptr_t oldBits, uintptr_t change) {
        return oldBits;
    }
#endif

    // 设置指定 bit 位置的位为 1
    void setBits(uintptr_t set) 
    {
        uintptr_t oldBits;
        uintptr_t newBits;
        do {
            // 先取得 bits 现在的值
            oldBits = LoadExclusive(&bits);
            // oldBits | set 就是合并后的新值，如果支持 fast alloc 的话，
            // 需要在 updateFastAlloc 中做一些调整
            newBits = updateFastAlloc(oldBits | set, set);
        } while (!StoreReleaseExclusive(&bits, oldBits, newBits)); // 将新值装进 bits
    }

    // 将指定的 bit 位置的位清为 0
    void clearBits(uintptr_t clear) 
    {
        uintptr_t oldBits;
        uintptr_t newBits;
        do {
            oldBits = LoadExclusive(&bits);
            // oldBits & ~clear 就能看出是清零
            // 如果 clear 是 000111000，取反是 111000111，与 oldBits 进行 & 运算
            // 指定的位都会变成 0
            newBits = updateFastAlloc(oldBits & ~clear, clear);
        } while (!StoreReleaseExclusive(&bits, oldBits, newBits));
    }

public:

    // 取出 bits 中存的 class_rw_t
    class_rw_t* data() {
        return (class_rw_t *)(bits & FAST_DATA_MASK);
    }
    
    // 设置 bit 中存的 class_rw_t 用 newData 替换
    void setData(class_rw_t *newData)
    {
        // 如果 data 中原来有值，并且newData标记的状态既不是 realizing 状态也不是 future 状态
        // 就报错
        assert(!data()  ||  (newData->flags & (RW_REALIZING | RW_FUTURE)));
        // Set during realization or construction only. No locking needed.
        
        // 1. bits & ~FAST_DATA_MASK 先将存 class_rw_t 的位置上的那些 bit 置为 0
        // 2. 然后 | (uintptr_t)newData ，将刚才置 0 的那些位用 newData 填充
        bits = (bits & ~FAST_DATA_MASK) | (uintptr_t)newData;
    }

    // -----------------------
    // 是否有默认的 RR
    // 和是否有默认的 AWZ/C++构造器/C++析构器 等不一样，它们在是否支持 fast alloc 的情况下存的位置不一样
    // 而是否有默认的 RR ，无论是否支持 fast alloc，都是存在 bits 中的 FAST_HAS_DEFAULT_RR 位置
    // 与 class_rw_t 没有关系
    
    // 是否用默认的 retain/release
    bool hasDefaultRR() {
        // 取出 bits 中 FAST_HAS_DEFAULT_RR 位的值
        return getBit(FAST_HAS_DEFAULT_RR);
    }
    // 设置有默认的 retain/release
    void setHasDefaultRR() {
        // 设置 bits 中 FAST_HAS_DEFAULT_RR 位的值为 1
        setBits(FAST_HAS_DEFAULT_RR);
    }
    // 标记含有自定义 retain/release
    void setHasCustomRR() {
        // 将 bits 中 FAST_HAS_DEFAULT_RR 位的值为 0
        clearBits(FAST_HAS_DEFAULT_RR);
    }

#if FAST_HAS_DEFAULT_AWZ   // 如果支持 fast alloc
    //
    // 好像如果支持 fast alloc 的话，是否有默认的 allocWithZone 的选项
    // 是存在 bits 中的，在 FAST_HAS_DEFAULT_AWZ 位置上存着
    // 而不支持 fast alloc 的话，就不一样，是否有默认的 allocWithZone 的选项
    // 存在了 bits 中的 class_rw_t 结构体里的 flags 变量中的 RW_HAS_DEFAULT_AWZ 位置上
    //
    
    // 是否有默认的 allocWithZone
    bool hasDefaultAWZ() {
        return getBit(FAST_HAS_DEFAULT_AWZ);
    }
    // 设置有默认的 allocWithZone
    void setHasDefaultAWZ() {
        setBits(FAST_HAS_DEFAULT_AWZ);
    }
    // 设置有自定义的 allocWithZone
    void setHasCustomAWZ() {
        clearBits(FAST_HAS_DEFAULT_AWZ);
    }
    
#else // 只要看下面的部分就好了
    
    // 是否有默认的 RR
    bool hasDefaultAWZ() {
        return data()->flags & RW_HAS_DEFAULT_AWZ;
    }
    // 设置有默认的 allocWithZone
    void setHasDefaultAWZ() {
        data()->setFlags(RW_HAS_DEFAULT_AWZ);
    }
    // 设置有自定义的 allocWithZone
    void setHasCustomAWZ() {
        data()->clearFlags(RW_HAS_DEFAULT_AWZ);
    }
    
#endif

    
#if FAST_HAS_CXX_CTOR // 如果支持 fast alloc
    
    // 和上面的 hasDefaultAWZ 一样，是否支持 fast alloc的两种情况下，
    // 是否有 C++ 构造器的选项存的位置不一样
    
    bool hasCxxCtor() {
        return getBit(FAST_HAS_CXX_CTOR);
    }
    void setHasCxxCtor() {
        setBits(FAST_HAS_CXX_CTOR);
    }
#else  // 不支持 fast alloc
    bool hasCxxCtor() {
        return data()->flags & RW_HAS_CXX_CTOR;
    }
    void setHasCxxCtor() {
        data()->setFlags(RW_HAS_CXX_CTOR);
    }
#endif

    
#if FAST_HAS_CXX_DTOR    // 如果支持 fast alloc
    bool hasCxxDtor() {
        return getBit(FAST_HAS_CXX_DTOR);
    }
    void setHasCxxDtor() {
        setBits(FAST_HAS_CXX_DTOR);
    }
#else   // 不支持 fast alloc
    bool hasCxxDtor() {
        return data()->flags & RW_HAS_CXX_DTOR;
    }
    void setHasCxxDtor() {
        data()->setFlags(RW_HAS_CXX_DTOR);
    }
#endif

    
#if FAST_REQUIRES_RAW_ISA  // 是否支持 raw isa，无论是否支持 fast alloc，
                           // 都是可以支持 raw isa 的
    // 是否需要 raw isa，也是直接存在 bits 的 FAST_REQUIRES_RAW_ISA 位置
    // 而不是 class_rw_t 中
    
    // 是否需要 raw isa
    bool requiresRawIsa() {
        return getBit(FAST_REQUIRES_RAW_ISA);
    }
    // 设置需要 raw isa
    void setRequiresRawIsa() {
        setBits(FAST_REQUIRES_RAW_ISA);
    }
#else   // 下面不用看，不会有下面的这种情况
# if SUPPORT_NONPOINTER_ISA
#   error oops
# endif
    bool requiresRawIsa() {
        return true;
    }
    void setRequiresRawIsa() {
        // nothing
    }
#endif
    
    
#if FAST_ALLOC // 如果可以快速 alloc
    
    // 取出快速 alloc 时成员变量的大小
    size_t fastInstanceSize() 
    {
        assert(bits & FAST_ALLOC);
        // 因为 FAST_SHIFTED_SIZE_SHIFT 位置存的数是实际大小的 1/16，所以需要乘以 16
        return (bits >> FAST_SHIFTED_SIZE_SHIFT) * 16;
    }
    
    // 设置快速 alloc 时，给成员变量分配的内存大小
    void setFastInstanceSize(size_t newSize) 
    {
        // Set during realization or construction only. No locking needed.
        assert(data()->flags & RW_REALIZING);

        // Round up to 16-byte boundary, then divide to get 16-byte units
        // 看上去像先得到 16 的整数倍，然后除以 16
        // 所以进一步验证了 FAST_SHIFTED_SIZE_SHIFT 处存的数是实际大小的 1/16
        newSize = ((newSize + 15) & ~15) / 16;
        
        uintptr_t newBits = newSize << FAST_SHIFTED_SIZE_SHIFT;
        
        // 先左移，再右移，看值变没变，这个有何意义呢。。。。
        if ((newBits >> FAST_SHIFTED_SIZE_SHIFT) == newSize) {
            // WORD_BITS 在 64 位系统上是 64 ，在 32 位系统上是 32
            // WORD_BITS 减 FAST_SHIFTED_SIZE_SHIFT，其实就是 shiftSize 占的大小
            // 因为 FAST_SHIFTED_SIZE_SHIFT 是需要位移的长度，需要位移 51 bits
            // 那么 实际 shiftSize 占的大小就是 64 - 51 = 13 bits
            int shift = WORD_BITS - FAST_SHIFTED_SIZE_SHIFT;
            uintptr_t oldBits = (bits << shift) >> shift;
            // 下面这个真心看不懂，完全不知道在干嘛
            if ((oldBits & FAST_ALLOC_MASK) == FAST_ALLOC_VALUE) {
                newBits |= FAST_ALLOC;
            }
            bits = oldBits | newBits;
        }
    }

    // 类是否可以 fast alloc
    bool canAllocFast() {
        return bits & FAST_ALLOC;
    }
#else
    size_t fastInstanceSize() {
        abort();
    }
    // 如果不支持快速 alloc ，就啥都不干
    void setFastInstanceSize(size_t) {
        // nothing
    }
    // 不支持 fast alloc 的话，那么这个类也肯定不能 fast alloc
    bool canAllocFast() {
        return false;
    }
#endif

    // 是否是 swift 类
    bool isSwift() {
        return getBit(FAST_IS_SWIFT);
    }
    // 设置该类是 swift 类
    void setIsSwift() {
        setBits(FAST_IS_SWIFT);
    }
};

#pragma mark -
#pragma mark - objc_class

// 参考文章：http://draveness.me/method-struct/

// 结构体之间的关系是：
// objc_class -> class_data_bits_t -> class_rw_t -> class_ro_t

// RW : Read Write   RO : Read Only

// 1. 在 realized 之前，class_data_bits_t 里的 bits 存的是 class_ro_t，
// 2. realized 后，class_data_bits_t 里的 bits 存 class_rw_t ，
//        class_rw_t 有一个变量存 class_ro_t

// http://7ni3rk.com1.z0.glb.clouddn.com/Runtime/class-diagram.jpg
// 元类的 isa 指向根元类，根元类的 isa 指向自己

// 当创建一个 Objective-C对象时，runtime会在实例变量存储区域后面再分配一点额外的空间。这么做的目的是什么呢？你可以获取这块空间起始指针（用 object_getIndexedIvars），然后就可以索引实例变量（ivars）

struct objc_class : objc_object {
//    Class ISA;    // 别疑惑，确实是被apple注释了。
                    // 原来是用来存储元类信息的，但是现在不是了，因为 objc_class 继承自 objc_object
                    // 元类（也就是类的类型）被存在了 objc_object 中的 isa_t isa 结构体中
    Class superclass; // 指向当前类的父类
    cache_t cache;    // cache 缓存 sel 和 imp 的对应关系，加速方法的调用  // formerly cache pointer and vtable
    class_data_bits_t bits;  // 存储类的方法、属性、遵循的协议等信息  // class_rw_t * plus custom rr/alloc flags
                        // objc_class 中对 class_data_bits_t 中的很多方法重新做了封装
                        // 对外界隐藏了 class_data_bits_t

    // 取得 bits 中存的 data，就是 class_data_bits_t 里的 bits 中的 data 部分
    // 在 realized 之前，data 存的是 ro，用的时候需要强转为 class_ro_t
    // 在 realized 之后，存的才是 rw
    class_rw_t *data() { 
        return bits.data();
    }
    
    // 设置 bits 中的 data 部分
    void setData(class_rw_t *newData) {
        bits.setData(newData);
    }

    // 设置 bits 中的 class_rw_t 结构体中存的 flag
    // 本质上是按位或，将指定的位置变为 1
    void setInfo(uint32_t set) {
        // 既没有 realized ，又没有 future ，说明 class 还没有准备好，后面的操作都做不了
        assert(isFuture()  ||  isRealized());
        data()->setFlags(set);
    }

    // 清空 bits 中的 class_rw_t 结构体中存的 flag
    // 本质上是按位异或，将指定的位置变为 0
    void clearInfo(uint32_t clear) {
        assert(isFuture()  ||  isRealized());
        data()->clearFlags(clear);
    }

    // set and clear must not overlap （不能重叠）
    // 既 set 又 clear，按位或和按位异或一起做，但是更新的位置不能重叠，不然就有歧义了
    void changeInfo(uint32_t set, uint32_t clear) {
        assert(isFuture()  ||  isRealized());
        assert((set & clear) == 0);
        data()->changeFlags(set, clear);
    }

    // 当前类或者父类含有自定义的的 retain/release/autorelease/retainCount/_tryRetain/_isDeallocating/retainWeakReference/allowsWeakReference 方法
    bool hasCustomRR() {
        return ! bits.hasDefaultRR(); // 没有默认的，就是有自定义的 RR
    }
    
    // 设置有默认的 RR，也就是没有自定义的 RR，这是在类的 bits 中存的
    void setHasDefaultRR() {
        assert(isInitializing());
        bits.setHasDefaultRR();
    }
    
    // 设置本类以及其所有的子类有自定义的 RR，参数 inherited 好像没啥用
    void setHasCustomRR(bool inherited = false);
    // 打印自定义 RR 的信息，inherited 表示该类的自定义 RR 是否是继承来的
    void printCustomRR(bool inherited);

    // 是否有自定义的 AWZ - allocWithZone
    bool hasCustomAWZ() {
        return ! bits.hasDefaultAWZ();
    }
    // 设置本类以及其所有的子类有自定义的 AWZ - allocWithZone/alloc，这是在元类的 bits 中存的
    void setHasDefaultAWZ() {
        assert(isInitializing());
        bits.setHasDefaultAWZ();
    }
    
    // 设置本类以及其所有的子类有自定义 allocWithZone
    void setHasCustomAWZ(bool inherited = false);
    // 打印自定义 allocWithZone 的信息
    void printCustomAWZ(bool inherited);

    // 是否需要 raw isa
    bool requiresRawIsa() {
        return bits.requiresRawIsa();
    }
    // 设置本类以及其所有的子类需要 raw isa
    void setRequiresRawIsa(bool inherited = false);
    // 打印本类有关 raw isa 的信息
    void printRequiresRawIsa(bool inherited);

    // 是否可以 indexed alloc （以索引的方式 alloc ?）
    bool canAllocIndexed() {
        assert(!isFuture());
        // 如果需要 raw isa ，就不可以 alloc indexed
        return !requiresRawIsa();
    }
    // 是否可以快速 alloc
    bool canAllocFast() {
        assert(!isFuture());
        return bits.canAllocFast();
    }

    // 是否有 C++ 构造器
    bool hasCxxCtor() {
        // addSubclass() propagates this flag from the superclass.
        assert(isRealized());
        return bits.hasCxxCtor();
    }
    // 设置有 C++ 构造器
    void setHasCxxCtor() { 
        bits.setHasCxxCtor();
    }

    // 有 C++ 析构器
    bool hasCxxDtor() {
        // addSubclass() propagates this flag from the superclass.
        assert(isRealized());
        return bits.hasCxxDtor();
    }
    // 设置有 C++ 析构器
    void setHasCxxDtor() { 
        bits.setHasCxxDtor();
    }

    // 是否是 swift 类型
    bool isSwift() {
        return bits.isSwift();
    }


#if SUPPORT_NONPOINTER_ISA
    // Tracked in non-pointer isas; not tracked otherwise
#else // 如果不支持 NONPOINTER_ISA
    // 实例变量是否有关联的对象
    bool instancesHaveAssociatedObjects() {
        // this may be an unrealized future class in the CF-bridged case
        assert(isFuture()  ||  isRealized());
        return data()->flags & RW_INSTANCES_HAVE_ASSOCIATED_OBJECTS;
    }
    // 设置实例变量有关联的对象
    void setInstancesHaveAssociatedObjects() {
        // this may be an unrealized future class in the CF-bridged case
        assert(isFuture()  ||  isRealized());
        setInfo(RW_INSTANCES_HAVE_ASSOCIATED_OBJECTS);
    }
#endif

    // 是否应该增大缓存
    bool shouldGrowCache() {
        return true;
    }

    // 设置需要增大缓存，啥事儿都没干，可能以后会有用
    void setShouldGrowCache(bool) {
        // fixme good or bad for memory use?
    }

    // 是否应该在主线程结束，在 _finishInitializing 中被调用过
    // 其中会将本类是否在主线程结束这个选项设置为和父类一致
    bool shouldFinalizeOnMainThread() {
        // finishInitializing() propagates（传送） this flag from the superclass.
        assert(isRealized());
        return data()->flags & RW_FINALIZE_ON_MAIN_THREAD;
    }
    // 设置应该在主线程结束
    void setShouldFinalizeOnMainThread() {
        assert(isRealized());
        setInfo(RW_FINALIZE_ON_MAIN_THREAD);
    }

    // 是否正在被初始化
    bool isInitializing() {
        return getMeta()->data()->flags & RW_INITIALIZING;
    }
    // 设置正在被初始化
    void setInitializing() {
        assert(!isMetaClass());
        ISA()->setInfo(RW_INITIALIZING);
    }

    // 是否已经被初始化
    bool isInitialized() {
        return getMeta()->data()->flags & RW_INITIALIZED;
    }
    // 设置已经被初始化
    void setInitialized();

    // 任何类都是可以被 Load 的
    bool isLoadable() {
        // 如果没有被 Realized ，就没法儿玩了
        assert(isRealized());
        return true;  // any class registered for +load is definitely loadable
    }

    // 获取 load 方法的函数指针
    IMP getLoadMethod();

    // Locking: To prevent concurrent realization（并发实现）, hold runtimeLock.
    // 是否已经被 Realized
    bool isRealized() {
        return data()->flags & RW_REALIZED;
    }

    // Returns true if this is an unrealized future class.
    // Locking: To prevent concurrent realization, hold runtimeLock.
    // 类是否处于 future 状态
    bool isFuture() { 
        return data()->flags & RW_FUTURE;
    }

    // 是否是元类
    bool isMetaClass() {
        assert(this);
        assert(isRealized());
        return data()->ro->flags & RO_META;
    }

    // NOT identical to this->ISA when this is a metaclass
    // 获得本类的元类
    Class getMeta() {
        if (isMetaClass()) {
            // 如果自己就是元类，就返回自身
            return (Class)this;
        } else {
            // 因为 objc_class 继承自 objc_object，所以它的类也存在了 isa_t isa 结构体对象中
            // ISA() 是取出 isa_t isa 中存的类型
            return this->ISA();
        }
    }

    // 是否是根类，注意：根类只有一个，元类的根类不是自己，而是统一的那个根类
    // http://7ni3rk.com1.z0.glb.clouddn.com/Runtime/class-diagram.jpg
    bool isRootClass() {
        return superclass == nil; // 根类就是没有父类
    }
    // 是否是根的元类
    bool isRootMetaclass() {
        return ISA() == (Class)this; // 根元类的 isa 指向自己
    }

    // 取得重整后的名字，即 ro 中存的名字，
    // 但是普通 OC 类，重整前后的名字是一样的
    // 而 swift 类重整前后的名字不一样
    const char *mangledName() { 
        // fixme can't assert locks here
        assert(this);

        // 如果已经 Realized 或者 是 future 的
        if (isRealized()  ||  isFuture()) {
            return data()->ro->name; // 直接取出 ro 中的 name
        } else {
            // 否则，还需要将 data 先强转成 class_ro_t 类型
            // 也就是说 Realized 之前，class_data_bits_t 里的 bits 里存的是 class_ro_t
            // Realized 之后，里面存的是 class_rw_t ，class_rw_t 中存有 class_ro_t
            return ((const class_ro_t *)data())->name;
        }
    }
    
    // 得到 demangledName，即取消重整后的名字
    // 如果传入的参数 realize 是 false，那么类必须已经被 realized 或者 future
    // 普通 OC 类，重整前后的名字是一样的，而 swift 类重整前后的名字不一样
    const char *demangledName(bool realize = false);
    const char *nameForLogging();

    // May be unaligned depending on class's ivars.
    // 没有对齐的实例变量（成员变量）的大小
    uint32_t unalignedInstanceSize() {
        assert(isRealized());
        return data()->ro->instanceSize;
    }

    // Class's ivar size rounded up to a pointer-size boundary.
    // 对齐后的实例变量（成员变量）的大小
    uint32_t alignedInstanceSize() {
        return word_align(unalignedInstanceSize());
    }

    // 计算成员变量加上额外的字节后的大小，大小最小是 16 字节
    size_t instanceSize(size_t extraBytes) {
        size_t size = alignedInstanceSize() + extraBytes;
        // CF requires all objects be at least 16 bytes.
        if (size < 16) size = 16;
        return size;
    }

    // 设置成员变量的新的大小
    void setInstanceSize(uint32_t newSize) {
        assert(isRealized());
        // 1. data()->ro->instanceSize 需要保持一致，但是只有与旧值不一样，才更改
        if (newSize != data()->ro->instanceSize) {
            // 确定已经将 class_ro_t 拷贝到 class_rw_t->ro
            assert(data()->flags & RW_COPIED_RO);
            // 直接修改 ro->instanceSize 所处的那块内存的值
            *const_cast<uint32_t *>(&data()->ro->instanceSize) = newSize;
        }
        // 2. class_data_bits_t 里的 bits 里存的 Instance size 也需要保持一致
        //    但仅限于支持 fast alloc 时，才有用，否则，啥都不干
        bits.setFastInstanceSize(newSize);
    }
};

// swift 的类，继承自 objc_class，且多了一些变量
// 应该是为了更好地与 swift 兼容
// 内存布局是这样的：[前缀] + [objc_class=[自身数据]+[额外空间]] + [额外空间]
// classAddressOffset = 前缀数据的大小
// classSize = 前缀 + objc_class
struct swift_class_t : objc_class {
    uint32_t flags;
    uint32_t instanceAddressOffset;
    uint32_t instanceSize;
    uint16_t instanceAlignMask;
    uint16_t reserved;

    uint32_t classSize; // 类的大小，包括前缀数据和本身的数据，但是不包括 extraBytes
    uint32_t classAddressOffset; // swift_class_t 中 objc_class 部分相对于 swift_class_t 起始地址的偏移量
                                 // 即前缀数据的大小
    void *description;
    // ...

    void *baseAddress() { // alloc_class_for_subclass() 函数中可以看出 baseAddress() 取得的是 swift 类
                          // 中数据的起始地址，每个 swift 类都有前缀数据和后缀数据，this 减去 classAddressOffset 取得的
                          // 应该就是前缀数据的起始地址
        return (void *)((uint8_t *)this - classAddressOffset);
    }
};


struct category_t {
    const char *name; // 分类的名字
    classref_t cls;   // 分类所属的类，classref_t 专门用于 unremapped 的类
    struct method_list_t *instanceMethods;  // 实例方法列表
    struct method_list_t *classMethods;     // 类方法列表
    struct protocol_list_t *protocols;      // 遵循的协议列表
    struct property_list_t *instanceProperties; // 属性列表，但是并没有卵用... 唉....

    // 如果是元类，就返回类方法列表；否则返回实例方法列表
    method_list_t *methodsForMeta(bool isMeta) {
        if (isMeta) {
            return classMethods;
        } else {
            return instanceMethods;
        }
    }

    // 如果是元类，就返回 nil，因为元类没有属性；否则返回实例属性列表，但是...实例属性
    property_list_t *propertiesForMeta(bool isMeta) {
        if (isMeta) {
            return nil; // classProperties;
        } else {
            return instanceProperties;
        }
    }
};

struct objc_super2 {
    id receiver;
    Class current_class;
};

// imp 和 sel 组成的结构体，用的地方不多
// 比如 objc-runtime-new.mm 中的 fixupMessageRef() 函数
struct message_ref_t {
    IMP imp;
    SEL sel;
};


extern Method protocol_getMethod(protocol_t *p, SEL sel, bool isRequiredMethod, bool isInstanceMethod, bool recursive);


// 深度遍历 top 类及其子孙类，只在 foreach_realized_class_and_subclass() 里被调用
static inline void
foreach_realized_class_and_subclass_2(Class top, bool (^code)(Class)) 
{
    // runtimeLock.assertWriting();
    assert(top);
    Class cls = top;
    // 深度遍历算法，就跟遍历树一样。一直往下走，走不通就掉头，继续走相邻的另一个树枝，直到把树遍历完。
    while (1) {
        // 这个相当没有道理，本方法只在 foreach_realized_class_and_subclass 一个地方用了
        // 而它全都是返回 true 的，所以下面这行代码中的 if 判断永远都是 false
        if (!code(cls)) { // 执行传入的 block
            break;
        }
        
        // 如果有第一个子类
        if (cls->data()->firstSubclass) {
            // 就将 cls 设为第一个子类
            cls = cls->data()->firstSubclass;
        }
        // 如果没有子类了，就向上回溯找兄弟类
        else {
            // 从 cls 开始向上追溯（包括 cls），找到第一个有兄弟类的类 或者 直到到达 top 就停止
            while (!cls->data()->nextSiblingClass  &&  cls != top) {
                cls = cls->superclass;
            }
            // 如果找到的是 top ，就说明遍历完了，就停止
            if (cls == top) {
                break;
            }
            // 否则将 cls 设为前面找到的那个类的兄弟类
            cls = cls->data()->nextSiblingClass;
        }
    }
}

// 深度遍历 top 类及其子孙类
static inline void
foreach_realized_class_and_subclass(Class top, void (^code)(Class)) 
{
    // 实际上还是调用 foreach_realized_class_and_subclass_2() 函数
    foreach_realized_class_and_subclass_2(top, ^bool(Class cls) { 
        code(cls);
        // 全都返回 true，
        return true;
    });
}

#endif
