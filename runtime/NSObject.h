/*	NSObject.h
	Copyright (c) 1994-2012, Apple Inc. All rights reserved.
*/

#ifndef _OBJC_NSOBJECT_H_
#define _OBJC_NSOBJECT_H_

#if __OBJC__

#include <objc/objc.h>
#include <objc/NSObjCRuntime.h>

@class NSString, NSMethodSignature, NSInvocation;

@protocol NSObject

- (BOOL)isEqual:(id)object;
@property (readonly) NSUInteger hash;

@property (readonly) Class superclass;
- (Class)class OBJC_SWIFT_UNAVAILABLE("use 'anObject.dynamicType' instead");
- (instancetype)self;

- (id)performSelector:(SEL)aSelector;
- (id)performSelector:(SEL)aSelector withObject:(id)object;
- (id)performSelector:(SEL)aSelector withObject:(id)object1 withObject:(id)object2;

- (BOOL)isProxy;

- (BOOL)isKindOfClass:(Class)aClass;
- (BOOL)isMemberOfClass:(Class)aClass;
- (BOOL)conformsToProtocol:(Protocol *)aProtocol;

- (BOOL)respondsToSelector:(SEL)aSelector;

- (instancetype)retain OBJC_ARC_UNAVAILABLE;
- (oneway void)release OBJC_ARC_UNAVAILABLE;
- (instancetype)autorelease OBJC_ARC_UNAVAILABLE;
- (NSUInteger)retainCount OBJC_ARC_UNAVAILABLE;

- (struct _NSZone *)zone OBJC_ARC_UNAVAILABLE;

@property (readonly, copy) NSString *description;
@optional
@property (readonly, copy) NSString *debugDescription;

@end


__OSX_AVAILABLE_STARTING(__MAC_10_0, __IPHONE_2_0)
OBJC_ROOT_CLASS
OBJC_EXPORT

/*
 比较让人难以理解的一点是，NSObject 和 objc_object 是如何联系起来的呢
 在 clang -rewrite-objc 后有这么一段：
     #ifndef _REWRITER_typedef_NSObject
     #define _REWRITER_typedef_NSObject
     typedef struct objc_object NSObject;
     typedef struct {} _objc_exc_NSObject;
     #endif
     
     struct NSObject_IMPL {
        Class isa;
     };
 
 看起来 NSObject 本质也是 objc_object
 到 runtime 的时候，估计已经没有这些OC类的分别了，大家都是 objc_object
 
 试一下，如果我们定义一个类 AXPerson ：
 
 ---------------------------
 
 @interface AXPerson : NSObject
 @property (nonatomic,copy) NSString *name;
 @end
 
 @implementation AXPerson
 @end

 ---------------------------
 
 经过 rewrite 之后，就变成了
 
 ---------------------------
 
 #ifndef _REWRITER_typedef_AXPerson
 #define _REWRITER_typedef_AXPerson
 typedef struct objc_object AXPerson;  // AXPerson 变成了 struct objc_object 的别名
 typedef struct {} _objc_exc_AXPerson;
 #endif
 
 extern "C" unsigned long OBJC_IVAR_$_AXPerson$_name;
 struct AXPerson_IMPL {
	struct NSObject_IMPL NSObject_IVARS; // 没错，这就是继承
	NSString *_name;
 };
 
 // @property (nonatomic,copy) NSString *name;
 // @end


// @implementation AXPerson


static NSString * _I_AXPerson_name(AXPerson * self, SEL _cmd) { return (*(NSString **)((char *)self + OBJC_IVAR_$_AXPerson$_name)); }
extern "C" __declspec(dllimport) void objc_setProperty (id, SEL, long, id, bool, bool);

static void _I_AXPerson_setName_(AXPerson * self, SEL _cmd, NSString *name) { objc_setProperty (self, _cmd, __OFFSETOFIVAR__(struct AXPerson, _name), (id)name, 0, 1); }
// @end
  ---------------------------
 
 多么神奇啊，AXPerson 类也只不过是 objc_object 结构体，
 存储变量的 @interface 变成了 AXPerson_IMPL 结构体，
 @implementation 中的自动添加了 setter 和 getter 方法，并且它们都是静态方法
 看方法的第一个参数，就很有 Python 的感觉，传入的是对象本身，方法和对象的绑定，只是靠一个参数罢了
 
 OC 经过编译器一处理，就变成了纯粹的 C 的世界，一切都是由最基础的 struct 和 function 组成的
 继承只不过是当前类的结构体里包含了父类的结构体罢了，重载方法只是多写了个带当前类的前缀的函数罢了
 
 -------------------------------
 
 在实例化对象的时候，OC代码是这样的：
    Son * son = [Son new];
 
 经过rewrite后的代码是这样的：
    Son * son = ((Son *(*)(id, SEL))(void *)objc_msgSend)((id)objc_getClass("Son"), sel_registerName("new"));
 
 其中，Son 是类名，其实，根据上面的经验，Son 在这里只是 objc_object 的别名
 objc_getClass("Son") 拿到了 Son 类对应的 objc_class 对象，里面存了类的所有信息
 向这个对象发送 new 消息，实例化得到了 objc_object 对象
 
 所以，真正存在的一直只有 objc_object 对象，并没有什么 Son 类、Son 类的对象
 只是 objc_object 中存的 isa_t 结构体中记录了它的 Class
 */
@interface NSObject <NSObject> {
    Class isa  OBJC_ISA_AVAILABILITY;
    // 这个 isa 其实没啥用，已经被废弃了， isa 存在 objc_object 中，并且是 isa_t 结构体类型的
    // 即使写 anObject->isa
    // Xcode 也报错：Direct accesss to Objective-C's isa deprecated in favor of object_getClass()
    // 建议我们用 object_getClass(), 它会返回 isa_t 中存的 Class cls
}

+ (void)load;

+ (void)initialize;
- (instancetype)init
#if NS_ENFORCE_NSOBJECT_DESIGNATED_INITIALIZER
    NS_DESIGNATED_INITIALIZER
#endif
    ;

+ (instancetype)new OBJC_SWIFT_UNAVAILABLE("use object initializers instead");
+ (instancetype)allocWithZone:(struct _NSZone *)zone OBJC_SWIFT_UNAVAILABLE("use object initializers instead");
+ (instancetype)alloc OBJC_SWIFT_UNAVAILABLE("use object initializers instead");
- (void)dealloc OBJC_SWIFT_UNAVAILABLE("use 'deinit' to define a de-initializer");

// 对象从内存中清除出去之前做必要的清理工作
- (void)finalize;

- (id)copy;
- (id)mutableCopy;

+ (id)copyWithZone:(struct _NSZone *)zone OBJC_ARC_UNAVAILABLE;
+ (id)mutableCopyWithZone:(struct _NSZone *)zone OBJC_ARC_UNAVAILABLE;

+ (BOOL)instancesRespondToSelector:(SEL)aSelector;
+ (BOOL)conformsToProtocol:(Protocol *)protocol;
// 找到 selector 对应的 IMP 也就是函数指针
- (IMP)methodForSelector:(SEL)aSelector;
+ (IMP)instanceMethodForSelector:(SEL)aSelector;
- (void)doesNotRecognizeSelector:(SEL)aSelector;

- (id)forwardingTargetForSelector:(SEL)aSelector __OSX_AVAILABLE_STARTING(__MAC_10_5, __IPHONE_2_0);
- (void)forwardInvocation:(NSInvocation *)anInvocation OBJC_SWIFT_UNAVAILABLE("");
- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector OBJC_SWIFT_UNAVAILABLE("");

+ (NSMethodSignature *)instanceMethodSignatureForSelector:(SEL)aSelector OBJC_SWIFT_UNAVAILABLE("");

- (BOOL)allowsWeakReference UNAVAILABLE_ATTRIBUTE;
- (BOOL)retainWeakReference UNAVAILABLE_ATTRIBUTE;

+ (BOOL)isSubclassOfClass:(Class)aClass;

+ (BOOL)resolveClassMethod:(SEL)sel __OSX_AVAILABLE_STARTING(__MAC_10_5, __IPHONE_2_0);
+ (BOOL)resolveInstanceMethod:(SEL)sel __OSX_AVAILABLE_STARTING(__MAC_10_5, __IPHONE_2_0);

+ (NSUInteger)hash;
+ (Class)superclass;
+ (Class)class OBJC_SWIFT_UNAVAILABLE("use 'aClass.self' instead");
+ (NSString *)description;
+ (NSString *)debugDescription;

@end

#endif

#endif
