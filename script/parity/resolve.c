/* Process-local resolver double for the transport harness. No DNS packets: only numeric
 * loopback addresses reach libc. Both Ruby and Rust still use their real socket/TLS/HTTP stacks.
 * macOS: DYLD interposition; Linux: LD_PRELOAD. Built into the harness's temporary directory. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <netdb.h>
#include <string.h>

typedef int (*resolver)(const char *, const char *, const struct addrinfo *, struct addrinfo **);

static int local_resolve(const char *node, const char *service,
                         const struct addrinfo *hints, struct addrinfo **result) {
#ifdef __APPLE__
    resolver real_resolve = getaddrinfo;
#else
    resolver real_resolve = (resolver)dlsym(RTLD_NEXT, "getaddrinfo");
#endif
    *result = NULL;
    if (!node) return EAI_NONAME;
    struct addrinfo numeric = {0};
    if (hints) numeric = *hints;
    numeric.ai_flags |= AI_NUMERICHOST;
    if (!strcmp(node, "fallback.parity.invalid")) {
        /* First address refuses; the second has the local listener. */
        int error = real_resolve("127.0.0.2", service, &numeric, result);
        if (error) return error;
        struct addrinfo *tail = *result;
        while (tail->ai_next) tail = tail->ai_next;
        error = real_resolve("127.0.0.1", service, &numeric, &tail->ai_next);
        if (error) { freeaddrinfo(*result); *result = NULL; }
        return error;
    }
    if (!strcmp(node, "localhost")) node = "127.0.0.1";
    if (strcmp(node, "127.0.0.1") && strcmp(node, "127.0.0.2") && strcmp(node, "::1"))
        return EAI_NONAME;
    return real_resolve(node, service, &numeric, result);
}

#ifdef __APPLE__
__attribute__((used)) static struct { const void *replacement; const void *original; }
interpose __attribute__((section("__DATA,__interpose"))) = {
    (const void *)local_resolve, (const void *)getaddrinfo
};
#else
int getaddrinfo(const char *node, const char *service,
                const struct addrinfo *hints, struct addrinfo **result) {
    return local_resolve(node, service, hints, result);
}
#endif
