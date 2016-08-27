
#ifndef _OBJC_CACHE_H
#define _OBJC_CACHE_H

#include "objc-private.h"

__BEGIN_DECLS

// 获得 cls 类中 sel 选择子对应的函数实现 IMP
// 实现在 objc-msg-arm.s 和 objc-msg-x86_64.s 中
extern IMP cache_getImp(Class cls, SEL sel);

// 填充 cache，也就是将 sel(key)/imp 组成 bucket，存入 cache 中的 _buckets 数组
extern void cache_fill(Class cls, SEL sel, IMP imp, id receiver);

// 清空指定 class 的缓存，但不缩小容量
extern void cache_erase_nolock(Class cls);

// 删除指定 class 的缓存，也就是将 _buckets 的内存释放掉
extern void cache_delete(Class cls);

// 清空垃圾桶，参数 collectALot 是是否强制地释放内存
extern void cache_collect(bool collectALot);

__END_DECLS

#endif
