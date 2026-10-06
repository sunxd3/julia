// This file is a part of Julia. License is MIT: https://julialang.org/license

#include "uv.h"
#include "julia.h"
#include "julia_internal.h"
#include "julia_assert.h"

typedef struct {
    jl_method_instance_t *mi;
    jl_value_t *owner;
} infer_key_t;

typedef struct _reservation_info_t {
    int16_t tid;
    jl_code_instance_t *ci;
    // the reservations of the same MethodInstance for other foreign owners
    struct _reservation_info_t *next;
} reservation_info_t;

// map from MethodInstance to threadid that owns it currently for inference
static htable_t native_reservations;
// map from MethodInstance to its reservations for foreign owners, one per owner. The
// owner of a reservation is that of its placeholder `ci`, which is live as long as the
// reservation is (see `jl_engine_sweep`), and owners are compared by egal, as the caches
// compare them.
static htable_t foreign_reservations;

static uv_mutex_t engine_lock; // n.b. this lock is only ever held briefly
static uv_cond_t engine_wait; // but it may be waiting a while in this state
// vector of which threads are blocked and which lease they need
static arraylist_t awaiting; // (this could be merged into ptls also)

static reservation_info_t *get_reservation(jl_method_instance_t *mi, jl_value_t *owner) JL_NOTSAFEPOINT
{
    if (owner == jl_nothing)
        return (reservation_info_t *)ptrhash_get(&native_reservations, mi);
    reservation_info_t *info = (reservation_info_t *)ptrhash_get(&foreign_reservations, mi);
    if (info == HT_NOTFOUND)
        return info;
    for (; info != NULL; info = info->next) {
        if (jl_egal(info->ci->owner, owner))
            return info;
    }
    return (reservation_info_t *)HT_NOTFOUND;
}

// unlink `info` from the reservations of `mi`, without freeing it
static void remove_reservation(jl_method_instance_t *mi, reservation_info_t *info) JL_NOTSAFEPOINT
{
    if (info->ci->owner == jl_nothing) {
        ptrhash_remove(&native_reservations, mi);
        return;
    }
    reservation_info_t **head = (reservation_info_t **)ptrhash_bp(&foreign_reservations, mi);
    if (*head == info && info->next == NULL) {
        ptrhash_remove(&foreign_reservations, mi);
        return;
    }
    reservation_info_t **link = head;
    while (*link != info)
        link = &(*link)->next;
    *link = info->next;
}

static reservation_info_t *try_insert_reservation(infer_key_t key, reservation_info_t to_insert, int *inserted) JL_NOTSAFEPOINT
{
    reservation_info_t *info = get_reservation(key.mi, key.owner);
    if (info != HT_NOTFOUND) {
        *inserted = 0;
        return info;
    }
    info = (reservation_info_t *)malloc_s(sizeof(reservation_info_t));
    *info = to_insert;
    reservation_info_t **record = (reservation_info_t **)ptrhash_bp(
        key.owner == jl_nothing ? &native_reservations : &foreign_reservations, key.mi);
    info->next = *record == HT_NOTFOUND ? NULL : *record;
    *record = info;
    *inserted = 1;
    return info;
}

jl_code_instance_t *jl_engine_reserve(jl_method_instance_t *mi, jl_value_t *owner)
{
    jl_task_t *ct = jl_current_task;
    ct->ptls->engine_nqueued++; // disables finalizers until inference is finished on this method graph
    jl_code_instance_t *ci = jl_new_codeinst_uninit(mi, owner); // allocate a placeholder
    JL_GC_PUSH1(&ci);
    int16_t tid = jl_atomic_load_relaxed(&ct->tid);
    int cond = 0;
    {
        int8_t gc_state = jl_gc_safe_enter(ct->ptls); // contains jl_gc_safepoint after enter
        uv_mutex_lock(&engine_lock);
        size_t max_tid = awaiting.len;
        if (max_tid < (size_t)tid + 1) {
            size_t n = (size_t)tid + 1 - max_tid;
            arraylist_grow(&awaiting, n);
            memset(&awaiting.items[max_tid], 0, n * sizeof(void *));
            max_tid += n;
        }
        while (1) {
            int inserted = 0;
            reservation_info_t *info = try_insert_reservation(
                (infer_key_t){ mi, owner }, (reservation_info_t){ tid, ci, NULL }, &inserted
            );
            if (inserted)
                break;
            // before waiting, need to run deadlock/cycle detection
            // there is a cycle if the thread holding our lease is blocked
            // and waiting for (transitively) any lease that is held by this thread
            int16_t wait_tid = info->tid;
            while (1) {
                if (wait_tid == tid) {
                    cond = 1;
                    break;
                }
                if (awaiting.len <= (size_t)wait_tid)
                    break; // no cycle, since it is running (and this should be unreachable)
                infer_key_t *key2 = (infer_key_t *)awaiting.items[wait_tid];
                if (key2 == NULL)
                    break; // no cycle, since it is running
                reservation_info_t *info2 = get_reservation(key2->mi, key2->owner);
                if (info2 == HT_NOTFOUND)
                    break; // no cycle, since it is about to resume
                assert(wait_tid != info2->tid);
                wait_tid = info2->tid;
            }
            if (cond)
                break;
            infer_key_t *key = (infer_key_t *)malloc_s(sizeof(infer_key_t));
            key->mi = mi;
            key->owner = owner;
            awaiting.items[tid] = key;
            uv_cond_wait(&engine_wait, &engine_lock);
            awaiting.items[tid] = NULL;
            free(key);
        }
        uv_mutex_unlock(&engine_lock);
        jl_gc_safe_leave(ct->ptls, gc_state); // contains jl_gc_safepoint after leave
    }
    if (cond) {
        ct->ptls->engine_nqueued--;
    }
    JL_GC_POP();
    return ci;
}

int jl_engine_hasreserved(jl_method_instance_t *mi, jl_value_t *owner)
{
    jl_task_t *ct = jl_current_task;
    uv_mutex_lock(&engine_lock);
    reservation_info_t *info = get_reservation(mi, owner);
    int found = info != HT_NOTFOUND && info->tid == jl_atomic_load_relaxed(&ct->tid);
    uv_mutex_unlock(&engine_lock);
    return found;
}

STATIC_INLINE int gc_marked(uintptr_t bits) JL_NOTSAFEPOINT
{
    return (bits & GC_MARKED) != 0;
}

static int sweep_reservations(htable_t *h, jl_ptls_t *gc_all_tls_states) JL_NOTSAFEPOINT
{
    int any = 0;
    for (size_t i = 0; i < h->size; i += 2) {
        if (h->table[i+1] == HT_NOTFOUND)
            continue;
        // drop every reservation of this MethodInstance whose placeholder is dead
        reservation_info_t **link = (reservation_info_t **)&h->table[i+1];
        while (*link != NULL) {
            reservation_info_t *info = *link;
            if (gc_marked(jl_astaggedvalue(info->ci)->bits.gc)) {
                link = &info->next;
                continue;
            }
            *link = info->next;
            jl_ptls_t ptls2 = gc_all_tls_states[info->tid];
            ptls2->engine_nqueued--;
            free(info);
            any = 1;
        }
        if (h->table[i+1] == NULL) {
            h->table[i+1] = HT_NOTFOUND; // remove (tombstone)
            h->live--;
        }
    }
    return any;
}

void jl_engine_sweep(jl_ptls_t *gc_all_tls_states)
{
    uv_mutex_lock(&engine_lock);
    int any = sweep_reservations(&native_reservations, gc_all_tls_states);
    if (sweep_reservations(&foreign_reservations, gc_all_tls_states))
        any = 1;
    if (any)
        uv_cond_broadcast(&engine_wait);
    uv_mutex_unlock(&engine_lock);
}

void jl_engine_fulfill(jl_code_instance_t *ci, jl_code_info_t *src)
{
    jl_task_t *ct = jl_current_task;
    uv_mutex_lock(&engine_lock);
    jl_method_instance_t *mi = jl_get_ci_mi(ci);
    reservation_info_t *info = get_reservation(mi, ci->owner);
    if (info == HT_NOTFOUND || info->ci != ci) {
        uv_mutex_unlock(&engine_lock);
        return;
    }
    assert(jl_atomic_load_relaxed(&ct->tid) == info->tid);
    ct->ptls->engine_nqueued--; // re-enables finalizers, but doesn't immediately try to run them
    remove_reservation(mi, info);
    free(info);
    uv_cond_broadcast(&engine_wait);
    uv_mutex_unlock(&engine_lock);
}

void jl_init_engine(void)
{
    uv_mutex_init(&engine_lock);
    uv_cond_init(&engine_wait);
    htable_new(&native_reservations, 0);
    htable_new(&foreign_reservations, 0);
    arraylist_new(&awaiting, 0);
}
