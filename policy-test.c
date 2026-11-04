/*
 * Execute the actual patched rde_peer.c policy, not a duplicated model.
 * Only external I/O, walker construction and UPDATE construction are stubs.
 * Linker section GC drops unrelated production entry points and their imports.
 */
#include <assert.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef RDE_PEER_SOURCE
#error Supply the absolute production rde_peer.c path with RDE_PEER_SOURCE
#endif
#include RDE_PEER_SOURCE

#define CHECK(x) do { if (!(x)) { \
    fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); exit(1); \
} } while (0)

struct rde_memstats rdemem;
static unsigned int generated, collected, dequeued, eors, defaults, refreshes;
static unsigned int inbound[64];
static int increase_pending;
static struct rib_entry *last_dequeued;
static struct prefix eligible;
static int have_eligible = 1;

struct captured_dump {
    void *arg;
    uint8_t aid;
    void (*upcall)(struct rib_entry *, void *);
    void (*done)(void *, uint8_t);
    int (*throttled)(void *);
};
static struct captured_dump dumps[16];
static unsigned int ndumps;
static int (*blast_throttled)(void *);
static void (*blast_done)(void *, uint8_t);

void
fatal(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    if (fmt != NULL) vfprintf(stderr, fmt, ap);
    va_end(ap);
    abort();
}

void
fatalx(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    if (fmt != NULL) vfprintf(stderr, fmt, ap);
    va_end(ap);
    abort();
}

uint32_t
ibufq_queuelen(struct ibufqueue *queue)
{
    uintptr_t id = (uintptr_t)queue;
    CHECK(id < sizeof(inbound) / sizeof(inbound[0]));
    return inbound[id];
}

static void
record_generation(void)
{
    generated++;
    if (increase_pending) rdemem.pend_prefix_cnt++;
}

#ifdef OPENBGPD_POLICY_LEGACY_UPDATES
void
up_generate_updates(struct rde_peer *peer, struct rib_entry *re)
{
    (void)peer; (void)re;
    record_generation();
}

void
up_generate_addpath(struct rde_peer *peer, struct rib_entry *re)
{
    up_generate_updates(peer, re);
}
#else
void
up_generate_updates(struct rde_peer *peer, struct rib_entry *re,
    enum eval_mode mode)
{
    (void)peer; (void)re;
    CHECK(mode == EVAL_DEFAULT || mode == EVAL_SYNC || mode == EVAL_REEVAL);
    record_generation();
}

void
up_generate_addpath(struct rde_peer *peer, struct rib_entry *re,
    enum eval_mode mode)
{
    up_generate_updates(peer, re, mode);
}

void
up_generate_addpath_all(struct rde_peer *peer, struct rib_entry *re,
    enum eval_mode mode)
{
    up_generate_updates(peer, re, mode);
}
#endif

#ifndef OPENBGPD_POLICY_LEGACY_UPDATES
void
adjout_prefix_collect(struct pt_entry *prefix)
{
    CHECK(prefix != NULL);
    collected++;
}
#endif

void
#ifdef OPENBGPD_POLICY_LEGACY_UPDATES
rib_dequeue(struct rib_entry *re)
#else
rib_pq_dequeue(struct rib_entry *re)
#endif
{
    last_dequeued = re;
    dequeued++;
}

struct prefix *
prefix_best(struct rib_entry *re)
{
    (void)re;
    return have_eligible ? &eligible : NULL;
}

int
rib_dump_new(uint16_t ribid, uint8_t aid, unsigned int count, void *arg,
    void (*upcall)(struct rib_entry *, void *), void (*done)(void *, uint8_t),
    int (*throttled)(void *))
{
    (void)ribid;
    CHECK(count == RDE_RUNNER_ROUNDS);
    CHECK(ndumps < sizeof(dumps) / sizeof(dumps[0]));
    dumps[ndumps++] = (struct captured_dump){arg, aid, upcall, done, throttled};
    return 0;
}

#ifdef OPENBGPD_POLICY_LEGACY_UPDATES
typedef void (*adjout_upcall)(struct rde_peer *, struct pt_entry *,
    struct adjout_prefix *, void *);
#else
typedef void (*adjout_upcall)(struct pt_entry *, struct adjout_prefix *,
    uint32_t, void *);
#endif

int
adjout_prefix_dump_new(struct rde_peer *peer, uint8_t aid, unsigned int count,
    void *arg, adjout_upcall upcall, void (*done)(void *, uint8_t),
    int (*throttled)(void *))
{
    (void)peer; (void)aid; (void)arg; (void)upcall;
    CHECK(count == RDE_RUNNER_ROUNDS);
    blast_throttled = throttled;
    blast_done = done;
    return 0;
}

void
pend_eor_add(struct rde_peer *peer, uint8_t aid)
{
    CHECK(peer != NULL && aid < AID_MAX);
    eors++;
}

void
pend_prefix_add(struct rde_peer *peer, struct adjout_attr *attrs,
    struct pt_entry *prefix, uint32_t path_id)
{
    (void)peer; (void)attrs; (void)prefix; (void)path_id;
    rdemem.pend_prefix_cnt++;
}

void
up_generate_default(struct rde_peer *peer, uint8_t aid)
{
    (void)peer; (void)aid;
    defaults++;
}

void
prefix_flowspec_dump(uint8_t aid, void *arg,
    void (*upcall)(struct rib_entry *, void *), void (*done)(void *, uint8_t))
{
    (void)upcall;
    done(arg, aid);
}

void
rde_peer_send_rrefresh(struct rde_peer *peer, uint8_t aid, uint8_t type)
{
    (void)peer; (void)aid; (void)type;
    refreshes++;
}

static void
reset_state(void)
{
    RB_INIT(&peertable);
    RB_INIT(&zombietable);
    peerself = NULL;
    dump_active = 0;
    memset(&rdemem, 0, sizeof(rdemem));
    memset(inbound, 0, sizeof(inbound));
    memset(dumps, 0, sizeof(dumps));
    generated = collected = dequeued = eors = defaults = refreshes = ndumps = 0;
    increase_pending = 0;
    have_eligible = 1;
    last_dequeued = NULL;
    blast_throttled = NULL;
    blast_done = NULL;
}

static void
add_peer(struct rde_peer *peer, uint32_t id)
{
    memset(peer, 0, sizeof(*peer));
    peer->conf.id = id;
    peer->state = PEER_UP;
    peer->export_type = EXPORT_UNSET;
    peer->loc_rib_id = RIB_LOC_START;
    peer->capa.mp[AID_INET] = peer->capa.mp[AID_INET6] = 1;
    peer->ibufq = (struct ibufqueue *)(uintptr_t)id;
    TAILQ_INIT(&peer->rib_pq_head);
    CHECK(RB_INSERT(peer_tree, &peertable, peer) == NULL);
}

static void
test_queue_retention_and_boundary(void)
{
    struct rde_peer a, b;
    struct pt_entry prefix = {.aid = AID_INET};
    struct rib_entry re;
    reset_state(); add_peer(&a, 1); add_peer(&b, 2);
    CHECK(RDE_PENDING_LIMIT == 100);
    rdemem.pend_prefix_cnt = 99; CHECK(!peer_pending_throttled(NULL));
    rdemem.pend_prefix_cnt = 100; CHECK(peer_pending_throttled(NULL));
    rdemem.pend_prefix_cnt = 101; CHECK(peer_pending_throttled(NULL));
    memset(&re, 0, sizeof(re));
    re.prefix = &prefix; re.rib_id = RIB_LOC_START; re.pq_mode = EVAL_DEFAULT;
    TAILQ_INSERT_TAIL(&a.rib_pq_head, &re, rib_queue);
#ifndef OPENBGPD_POLICY_NO_RIB_COUNTERS
    a.stats.rib_entry_count = 1; rdemem.rde_rib_entry_count = 1;
#endif
    peer_process_updates(&a, NULL);
    CHECK(TAILQ_FIRST(&a.rib_pq_head) == &re);
#ifndef OPENBGPD_POLICY_NO_RIB_COUNTERS
    CHECK(a.stats.rib_entry_count == 1 && rdemem.rde_rib_entry_count == 1);
#endif
    CHECK(generated == 0 && collected == 0 && dequeued == 0);
    CHECK(!peer_work_pending());
    rdemem.pend_prefix_cnt = 99; increase_pending = 1;
    CHECK(peer_work_pending());
    peer_process_updates(&a, NULL);
    CHECK(TAILQ_EMPTY(&a.rib_pq_head));
#ifndef OPENBGPD_POLICY_NO_RIB_COUNTERS
    CHECK(a.stats.rib_entry_count == 0 && rdemem.rde_rib_entry_count == 0);
#endif
#ifdef OPENBGPD_POLICY_LEGACY_UPDATES
    CHECK(collected == 0);
#else
    CHECK(collected == 1);
#endif
    CHECK(generated == 2 && dequeued == 1 && last_dequeued == &re);
    /* The complete fan-out is preserved: the mark is deliberately soft. */
    CHECK(rdemem.pend_prefix_cnt == 101);
    puts("PASS: production boundary, queued-work retention/resume, complete fan-out soft overshoot");
}

static void
test_owner_and_dump_count(void)
{
    struct rde_peer a, b;
    unsigned int i;
    reset_state(); add_peer(&a, 1); add_peer(&b, 2);
    a.capa.grestart.restart = b.capa.grestart.restart = 1;
    peer_dump(&a, AID_INET); peer_dump(&a, AID_INET6);
    peer_dump(&a, AID_INET); /* Same peer and same AID must count twice. */
    peer_dump(&b, AID_INET);
    CHECK(a.dump_count == 3 && b.dump_count == 1 && ndumps == 4);
    rdemem.pend_prefix_cnt = 100;
    CHECK(dumps[0].throttled != NULL && !dumps[0].throttled(&a));
    CHECK(a.dump_admitted && b.dump_admitted && dump_active == 2);
    CHECK(!dumps[3].throttled(&b));
    CHECK(!dumps[1].throttled(&a) && !dumps[2].throttled(&a));
    for (i = 0; i < 3; i++) {
        dumps[i].done(dumps[i].arg, dumps[i].aid);
        CHECK(a.dump_count == 2 - i);
        if (i != 2) CHECK(a.dump_admitted && dump_active == 2);
    }
    CHECK(dump_active == 1 && !a.dump_admitted && b.dump_admitted && eors == 3);
    rdemem.pend_prefix_cnt = 0;
    CHECK(!dumps[3].throttled(&b) && b.dump_admitted && dump_active == 1);
    dumps[3].done(&b, AID_INET);
    CHECK(b.dump_count == 0 && dump_active == 0 && !b.dump_admitted && eors == 4);
    puts("PASS: production multiple AF/repeated-AID accounting, no early admission release");
}

static void
test_bounded_parallel_dumps(void)
{
    struct rde_peer peers[RDE_PENDING_DUMPS + 1];
    unsigned int i;
    reset_state();
    for (i = 0; i <= RDE_PENDING_DUMPS; i++) {
        add_peer(&peers[i], i + 1);
        peers[i].dump_count = 1;
    }
    rdemem.pend_prefix_cnt = 99;
    CHECK(!peer_dump_throttled(&peers[0]));
    CHECK(dump_active == RDE_PENDING_DUMPS);
    for (i = 0; i < RDE_PENDING_DUMPS; i++) {
        CHECK(!peer_dump_throttled(&peers[i]));
        CHECK(peers[i].dump_admitted && dump_active == RDE_PENDING_DUMPS);
    }
    CHECK(peer_dump_throttled(&peers[RDE_PENDING_DUMPS]));
    rdemem.pend_prefix_cnt = 100;
    for (i = 0; i < RDE_PENDING_DUMPS; i++)
        CHECK(!peer_dump_throttled(&peers[i]));
    peer_dump_done(&peers[0], AID_INET);
    CHECK(dump_active == RDE_PENDING_DUMPS - 1);
    CHECK(peer_dump_throttled(&peers[RDE_PENDING_DUMPS]));
    rdemem.pend_prefix_cnt = 99;
    CHECK(!peer_dump_throttled(&peers[RDE_PENDING_DUMPS]));
    CHECK(dump_active == RDE_PENDING_DUMPS);
    for (i = 1; i <= RDE_PENDING_DUMPS; i++)
        peer_dump_done(&peers[i], AID_INET);
    CHECK(dump_active == 0);
    reset_state();
    for (i = 0; i <= RDE_PENDING_DUMPS; i++) {
        add_peer(&peers[i], i + 1);
        peers[i].dump_count = 1;
    }
    rdemem.pend_prefix_cnt = 100;
    CHECK(!peer_dump_throttled(&peers[0]));
    CHECK(dump_active == RDE_PENDING_DUMPS);
    CHECK(peer_dump_throttled(&peers[RDE_PENDING_DUMPS]));
    for (i = 0; i < RDE_PENDING_DUMPS; i++)
        peer_dump_done(&peers[i], AID_INET);
    CHECK(dump_active == 0);
    puts("PASS: production bounded parallel admissions, no new admission at capacity/pressure, complete drain");
}

static void
test_escape_and_xoff(void)
{
    struct rde_peer a, b;
    reset_state(); add_peer(&a, 1); add_peer(&b, 2);
    a.dump_count = 1;
    a.throttled = b.throttled = 1;
    a.stats.pending_update = 100;
    rdemem.pend_prefix_cnt = 100;
    CHECK(!peer_dump_throttled(&a));
    b.dump_count = 1;
    b.stats.pending_update = 100;
    rdemem.pend_prefix_cnt = 200;
    CHECK(a.dump_admitted && dump_active == 1 && peer_dump_throttled(&b));
    peer_dump_done(&a, AID_INET);
    CHECK(dump_active == 0 && !a.dump_admitted && a.dump_count == 0);
    /* A non-dumping Pending owner can drain, even if it currently has XOFF. */
    a.throttled = 1;
    CHECK(peer_dump_throttled(&b) && dump_active == 0);
    inbound[a.conf.id] = 1;
    CHECK(peer_work_pending()); /* Incoming/control work remains runnable. */
    inbound[a.conf.id] = 0;
    a.stats.pending_update = 0; a.stats.pending_withdraw = 1;
    rdemem.pend_prefix_cnt = 101;
    CHECK(peer_dump_throttled(&b));
    a.stats.pending_withdraw = 0;
    rdemem.pend_prefix_cnt = 100;
    CHECK(!peer_dump_throttled(&b));
    CHECK(b.dump_admitted && dump_active == 1);
    puts("PASS: production all-dump escape, non-dumping UPDATE/withdraw XOFF blocks admission, inbound work survives");
}

static void
test_busy_poll_and_eor(void)
{
    struct rde_peer a, zombie;
    struct rib_entry re;
    reset_state(); add_peer(&a, 1);
    memset(&re, 0, sizeof(re));
    TAILQ_INSERT_TAIL(&a.rib_pq_head, &re, rib_queue);
    rdemem.pend_prefix_cnt = 100;
    CHECK(!peer_work_pending());
    inbound[1] = 1; CHECK(peer_work_pending()); inbound[1] = 0;
    memset(&zombie, 0, sizeof(zombie)); zombie.conf.id = 8;
    CHECK(RB_INSERT(peer_tree, &zombietable, &zombie) == NULL);
    CHECK(peer_work_pending());
    CHECK(RB_REMOVE(peer_tree, &zombietable, &zombie) == &zombie);
    CHECK(!peer_work_pending());
    rdemem.pend_prefix_cnt = 99; CHECK(peer_work_pending());
    a.throttled = 1; peer_blast_done(&a, AID_INET);
    CHECK(a.throttled == 0 && eors == 0);
    a.capa.grestart.restart = 1; a.throttled = 1;
    peer_blast_done(&a, AID_INET6); CHECK(a.throttled == 0 && eors == 1);
    a.export_type = EXPORT_NONE; peer_dump(&a, AID_INET);
#ifdef OPENBGPD_POLICY_LEGACY_UPDATES
    /* These versions finish special exports through an Adj-RIB-Out walk. */
    CHECK(a.throttled && eors == 1 && blast_done != NULL);
    CHECK(blast_throttled == NULL);
    blast_done(&a, AID_INET);
#endif
    CHECK(a.dump_count == 0 && eors == 2);
    a.export_type = EXPORT_DEFAULT_ROUTE; peer_dump(&a, AID_INET6);
#ifdef OPENBGPD_POLICY_LEGACY_UPDATES
    CHECK(a.throttled && eors == 2 && blast_done != NULL);
    CHECK(blast_throttled == NULL);
    blast_done(&a, AID_INET6);
#endif
    CHECK(a.dump_count == 0 && defaults == 1 && eors == 3);
    a.export_type = EXPORT_UNSET;
    peer_blast(&a, AID_INET);
    CHECK(blast_throttled != NULL && blast_done != NULL);
    rdemem.pend_prefix_cnt = 100; CHECK(blast_throttled(&a));
    rdemem.pend_prefix_cnt = 99; CHECK(!blast_throttled(&a));
    puts("PASS: production no busy-poll on paused RIB work, zombies/inbound work survive, EOR/default export retained");
}

int
main(void)
{
    test_queue_retention_and_boundary();
    test_owner_and_dump_count();
    test_bounded_parallel_dumps();
    test_escape_and_xoff();
    test_busy_poll_and_eor();
    puts("All production-policy unit checks passed (actual patched rde_peer.c, limit=100).");
    return 0;
}
