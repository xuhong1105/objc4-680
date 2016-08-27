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
/*
 *	objc.h
 *	Copyright 1988-1996, NeXT Software, Inc.
 */

#ifndef _OBJC_OBJC_H_
#define _OBJC_OBJC_H_

#include <sys/types.h>      // for __DARWIN_NULL
#include <Availability.h>
#include <objc/objc-api.h>
#include <stdbool.h>

#if !OBJC_TYPES_DEFINED  // 在 objc_private.h 中定义了 #define OBJC_TYPES_DEFINED 1
                         // 所以底下的这部分代码是不会编译的，只是暴露出来给大家看看的

// Class 的本质，其实就是一个结构体
/// An opaque type that represents an Objective-C class.
typedef struct objc_class *Class;

/// Represents an instance of a class.
struct objc_object {
    // 实际在objc_private.h中objc_object是没有Class isa这个字段的
    // 有的只是isa_t isa这个私有的字段，代表对象类型的Class cls字段存储在 isa_t 结构体中
    // Apple玩这么一手，轻易的就把底层实现给隐藏了
    Class isa  OBJC_ISA_AVAILABILITY;
};

/// A pointer to an instance of a class.
typedef struct objc_object *id;
#endif

/// An opaque type that represents a method selector.
// objc_selector 的定义在源码中并没有给出，网上的说法是映射到一个 char * 字符串
// 也就是本质上是一个 char * 字符串
// 经过下面的实验，确实如此  struct objc_selector *  == SEL == char *
//
/*
- (void)methedWithStr1:(NSString *)str1 str2:(NSString *)str2 {
    NSLog(@"%@,%@", str1, str2);
}

- (void)test {
    struct objc_selector * sel_1 = @selector(methedWithStr1:str2:);
    SEL sel_2 = @selector(methedWithStr1:str2:);
    if (sel_1 == sel_2) {
        NSLog(@"一样");    // 确实一样
    } else {
        NSLog(@"不一样");
    }
    
    // 转为 char *
    char * str_1 = (char *)sel_1;
    printf("%s\n", str_1);  // methedWithStr1:str2:
}
 */

// 在 rewrite-objc 代码中也可以看到，
// 字符串 "name" 和 "setName" 被直接强转为 struct objc_selector * 类型
/*
 static struct <!-- _method_list_t --> {
     unsigned int entsize;  // sizeof(struct _objc_method)
     unsigned int method_count;
     struct _objc_method method_list[2];
 } _OBJC_$_INSTANCE_METHODS_AXPerson __attribute__ ((used, section ("__DATA,__objc_const"))) = {
     sizeof(_objc_method),
     2,
     {{(struct objc_selector *)"name", "@16@0:8", (void *)_I_AXPerson_name},
         {(struct objc_selector *)"setName:", "v24@0:8@16", (void *)_I_AXPerson_setName_}}
 };
 */

typedef struct objc_selector *SEL;

/// A pointer to the function of a method implementation.
// IMP 的定义
// IMP 是一个指向方法的函数实现的指针
#if !OBJC_OLD_DISPATCH_PROTOTYPES
typedef void (*IMP)(void /* id, SEL, ... */ ); 
#else
typedef id (*IMP)(id, SEL, ...); 
#endif

#define OBJC_BOOL_DEFINED

/// Type to represent a boolean value.
#if (TARGET_OS_IPHONE && __LP64__)  ||  TARGET_OS_WATCH
#define OBJC_BOOL_IS_BOOL 1
typedef bool BOOL;
#else
#define OBJC_BOOL_IS_CHAR 1
typedef signed char BOOL; 
// BOOL is explicitly signed so @encode(BOOL) == "c" rather than "C" 
// even if -funsigned-char is used.
#endif

#if __has_feature(objc_bool)
#define YES __objc_yes
#define NO  __objc_no
#else
#define YES ((BOOL)1)
#define NO  ((BOOL)0)
#endif

#ifndef Nil
# if __has_feature(cxx_nullptr)
#   define Nil nullptr
# else
#   define Nil __DARWIN_NULL
# endif
#endif

#ifndef nil
# if __has_feature(cxx_nullptr)
#   define nil nullptr
# else
#   define nil __DARWIN_NULL
# endif
#endif

#if ! (defined(__OBJC_GC__)  ||  __has_feature(objc_arc))
#define __strong /* empty */
#endif

#if !__has_feature(objc_arc)
#define __unsafe_unretained /* empty */
#define __autoreleasing /* empty */
#endif


/** 
 * Returns the name of the method specified by a given selector.
 * 
 * @param sel A pointer of type \c SEL. Pass the selector whose name you wish to determine.
 * 
 * @return A C string indicating the name of the selector.
 */
// 取得 sel 中的方法名，其实 sel 就是一个 char * 字符串
// 强转为 char * ，就得到了方法名
OBJC_EXPORT const char *sel_getName(SEL sel)
    __OSX_AVAILABLE_STARTING(__MAC_10_0, __IPHONE_2_0);

/** 
 * Registers a method with the Objective-C runtime system, maps the method 
 * name to a selector, and returns the selector value.
 * 
 * @param str A pointer to a C string. Pass the name of the method you wish to register.
 * 
 * @return A pointer of type SEL specifying the selector for the named method.
 * 
 * @note You must register a method name with the Objective-C runtime system to obtain the
 *  method’s selector before you can add the method to a class definition. If the method name
 *  has already been registered, this function simply returns the selector.
 */
OBJC_EXPORT SEL sel_registerName(const char *str)
    __OSX_AVAILABLE_STARTING(__MAC_10_0, __IPHONE_2_0);

/** 
 * Returns the class name of a given object.
 * 
 * @param obj An Objective-C object.
 * 
 * @return The name of the class of which \e obj is an instance.
 */
// 取得对象的类名
// 本质上是对象的类的 demangledName
OBJC_EXPORT const char *object_getClassName(id obj)
    __OSX_AVAILABLE_STARTING(__MAC_10_0, __IPHONE_2_0);

/** 
 * Returns a pointer to any extra bytes allocated with an instance given object.
 * 
 * @param obj An Objective-C object.
 * 
 * @return A pointer to any extra bytes allocated with \e obj. If \e obj was
 *   not allocated with any extra bytes, then dereferencing the returned pointer is undefined.
 * 
 * @note This function returns a pointer to any extra bytes allocated with the instance
 *  (as specified by \c class_createInstance with extraBytes>0). This memory follows the
 *  object's ordinary ivars, but may not be adjacent to the last ivar.
 * @note The returned pointer is guaranteed to be pointer-size aligned, even if the area following
 *  the object's last ivar is less aligned than that. Alignment greater than pointer-size is never
 *  guaranteed, even if the area following the object's last ivar is more aligned than that.
 * @note In a garbage-collected environment, the memory is scanned conservatively.
 */
OBJC_EXPORT void *object_getIndexedIvars(id obj)
    __OSX_AVAILABLE_STARTING(__MAC_10_0, __IPHONE_2_0);

/** 
 * Identifies a selector as being valid or invalid.
 * 
 * @param sel The selector you want to identify.
 * 
 * @return YES if selector is valid and has a function implementation, NO otherwise. 
 * 
 * @warning On some platforms, an invalid reference (to invalid memory addresses) can cause
 *  a crash. 
 */
OBJC_EXPORT BOOL sel_isMapped(SEL sel)
    __OSX_AVAILABLE_STARTING(__MAC_10_0, __IPHONE_2_0);

/** 
 * Registers a method name with the Objective-C runtime system.
 * 
 * @param str A pointer to a C string. Pass the name of the method you wish to register.
 * 
 * @return A pointer of type SEL specifying the selector for the named method.
 * 
 * @note The implementation of this method is identical to the implementation of \c sel_registerName.
 * @note Prior to OS X version 10.0, this method tried to find the selector mapped to the given name
 *  and returned \c NULL if the selector was not found. This was changed for safety, because it was
 *  observed that many of the callers of this function did not check the return value for \c NULL.
 */
OBJC_EXPORT SEL sel_getUid(const char *str)
    __OSX_AVAILABLE_STARTING(__MAC_10_0, __IPHONE_2_0);


// Obsolete ARC conversions. Deprecation forthcoming.
// Use CFBridgingRetain, CFBridgingRelease, and __bridge casts instead.

typedef const void* objc_objectptr_t;

#if __has_feature(objc_arc)
#   define objc_retainedObject(o) ((__bridge_transfer id)(objc_objectptr_t)(o))
#   define objc_unretainedObject(o) ((__bridge id)(objc_objectptr_t)(o))
#   define objc_unretainedPointer(o) ((__bridge objc_objectptr_t)(id)(o))
#else
#   define objc_retainedObject(o) ((id)(objc_objectptr_t)(o))
#   define objc_unretainedObject(o) ((id)(objc_objectptr_t)(o))
#   define objc_unretainedPointer(o) ((objc_objectptr_t)(id)(o))
#endif


#if !__OBJC2__

// The following declarations are provided here for source compatibility.

#if defined(__LP64__)
    typedef long arith_t;
    typedef unsigned long uarith_t;
#   define ARITH_SHIFT 32
#else
    typedef int arith_t;
    typedef unsigned uarith_t;
#   define ARITH_SHIFT 16
#endif

typedef char *STR;

#define ISSELECTOR(sel) sel_isMapped(sel)
#define SELNAME(sel)	sel_getName(sel)
#define SELUID(str)	sel_getUid(str)
#define NAMEOF(obj)     object_getClassName(obj)
#define IV(obj)         object_getIndexedIvars(obj)

#endif

#endif  /* _OBJC_OBJC_H_ */
