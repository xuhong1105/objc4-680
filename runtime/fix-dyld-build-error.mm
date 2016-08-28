//
//  hehe.m
//  objc
//
//  Created by Allen on 16/8/28.
//
//

/* 因为一直报:
 
 "_dyld_register_image_state_change_handler", referenced from:
 _map_images_nolock in objc-os.o
 __objc_init in objc-os.o
 ld: symbol(s) not found for architecture x86_64
 
 这个错误，即 dyld_register_image_state_change_handler 函数在 xcode 8 的 libdyld.dylib 动态库中没有实现，
 所以我直接从 dyld 库的源码中把 dyld_register_image_state_change_handler 函数的实现抄过来用，
 然后，还需要链接 dylib1.o，
 唉，现在是凌晨 2 点钟，终于编译通过了，这个 bug 真是坑死我了，研究了整整一天才找到解决方法。
 老外也不怎么靠谱，google 上都没人提过这个问题，关键时刻还是得靠自己。
 */

#include <mach-o/dyld_priv.h>
#include <pthread.h>

#define DYLD_LOCK_THIS_BLOCK			LockHelper _dyld_lock;
#define DYLD_NO_LOCK_THIS_BLOCK

// used by dyld wrapper functions in libSystem
class __attribute__((visibility("hidden"))) LockHelper
{
public:
    LockHelper();
    ~LockHelper();
};

static pthread_mutex_t	sGlobalMutex = PTHREAD_RECURSIVE_MUTEX_INITIALIZER;

// <rdar://problem/6361143> Need a way to determine if a gdb call to dlopen() would block
int	__attribute__((visibility("hidden")))			_dyld_global_lock_held = 0;

void dyldGlobalLockAcquire()
{
    pthread_mutex_lock(&sGlobalMutex);
    ++_dyld_global_lock_held;
}

void dyldGlobalLockRelease()
{
    --_dyld_global_lock_held;
    pthread_mutex_unlock(&sGlobalMutex);
}

LockHelper::LockHelper()
{
    dyldGlobalLockAcquire();
}

LockHelper::~LockHelper()
{
    dyldGlobalLockRelease();
}

// xcode 7 中没有问题，xcode 8 中需要添加这个函数的实现
void
dyld_register_image_state_change_handler(enum dyld_image_states state, bool batch, dyld_image_state_change_handler handler)
{
    LockHelper _dyld_lock;
    static void* (*p)(dyld_image_states, bool, dyld_image_state_change_handler) = NULL;
    
    if(p == NULL)
        _dyld_func_lookup("__dyld_dyld_register_image_state_change_handler", (void**)&p);
    p(state, batch, handler);
}

