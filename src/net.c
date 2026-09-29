/*
 * net: minimal, portable, non-blocking UDP for peer-to-peer netplay.
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Everything protocol-related (handshake, rollback, STUN, time sync) is done
 * in Lua; this file only moves datagrams.
 *
 *   local s = net.udp(7777)            -- bind 0.0.0.0:7777 (0 = any port)
 *   s:send("1.2.3.4", 7777, data)      -- -> true | nil, err
 *   local data, ip, port = s:recv()    -- non-blocking, nil when empty
 *   s:port()  s:close()
 *   local r = net.resolve("stun.l.google.com")   -- threaded DNS lookup
 *   r:result()                         -- nil (pending) | "ip" | false, err
 *   net.local_ip()                     -- primary LAN address or nil
 */
#ifdef _WIN32
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#endif

#include "engine.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
typedef SOCKET sock_t;
#define SOCK_BAD INVALID_SOCKET
#define sock_close closesocket
#ifndef SIO_UDP_CONNRESET
#define SIO_UDP_CONNRESET _WSAIOW(IOC_VENDOR, 12)
#endif
static bool wsa_ready;
static int last_err(void) {
    return WSAGetLastError();
}
static bool err_is_transient(int e) {
    return e == WSAEWOULDBLOCK || e == WSAECONNRESET || e == WSAEMSGSIZE;
}
#else
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
typedef int sock_t;
#define SOCK_BAD (-1)
#define sock_close close
static int last_err(void) {
    return errno;
}
static bool err_is_transient(int e) {
    return e == EAGAIN || e == EWOULDBLOCK || e == ECONNREFUSED || e == EINTR;
}
#endif

#define SOCKET_MT "buyo.Socket"
#define RESOLVE_MT "buyo.Resolve"

typedef struct {
    sock_t fd;
    int port;
} Sock;

static void net_startup(void) {
#ifdef _WIN32
    if (!wsa_ready) {
        WSADATA wd;
        wsa_ready = WSAStartup(MAKEWORD(2, 2), &wd) == 0;
    }
#endif
}

void net_shutdown(void) {
#ifdef _WIN32
    if (wsa_ready)
        WSACleanup();
    wsa_ready = false;
#endif
}

static bool set_nonblocking(sock_t fd) {
#ifdef _WIN32
    u_long on = 1;
    return ioctlsocket(fd, FIONBIO, &on) == 0;
#else
    int flags = fcntl(fd, F_GETFL, 0);
    return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
#endif
}

static bool parse_ipv4(const char *ip, int port, struct sockaddr_in *out) {
    memset(out, 0, sizeof *out);
    out->sin_family = AF_INET;
    out->sin_port = htons((unsigned short)port);
    return inet_pton(AF_INET, ip, &out->sin_addr) == 1;
}

/* ------------------------------------------------------------------ */
/* sockets                                                             */
/* ------------------------------------------------------------------ */

/* NULL if the socket was closed (callers raise the Lua error, which keeps
 * static analyzers aware that the fd is valid afterwards) */
static Sock *check_sock(lua_State *L) {
    Sock *s = (Sock *)luaL_checkudata(L, 1, SOCKET_MT);
    return s->fd == SOCK_BAD ? NULL : s;
}

/* net.udp([port]) -> Socket | nil, err */
static int l_udp(lua_State *L) {
    net_startup();
    int port = (int)luaL_optinteger(L, 1, 0);
    sock_t fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd == SOCK_BAD) {
        lua_pushnil(L);
        lua_pushfstring(L, "socket() failed (%d)", last_err());
        return 2;
    }
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, (const char *)&yes, sizeof yes);
#ifdef _WIN32
    { /* don't turn ICMP "port unreachable" into recvfrom() errors */
        BOOL off = FALSE;
        DWORD ret = 0;
        WSAIoctl(fd, SIO_UDP_CONNRESET, &off, sizeof off, NULL, 0, &ret, NULL, NULL);
    }
#endif
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons((unsigned short)port);
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
        int e = last_err();
        sock_close(fd);
        lua_pushnil(L);
        lua_pushfstring(L, "cannot bind UDP port %d (error %d)", port, e);
        return 2;
    }
    set_nonblocking(fd);
    socklen_t alen = sizeof addr;
    getsockname(fd, (struct sockaddr *)&addr, &alen);

    Sock *s = (Sock *)lua_newuserdatauv(L, sizeof *s, 0);
    s->fd = fd;
    s->port = ntohs(addr.sin_port);
    luaL_setmetatable(L, SOCKET_MT);
    return 1;
}

static int l_sock_send(lua_State *L) {
    Sock *s = check_sock(L);
    if (!s)
        return luaL_error(L, "socket is closed");
    const char *ip = luaL_checkstring(L, 2);
    int port = (int)luaL_checkinteger(L, 3);
    size_t len;
    const char *data = luaL_checklstring(L, 4, &len);
    struct sockaddr_in to;
    if (port <= 0 || port > 65535 || !parse_ipv4(ip, port, &to)) {
        lua_pushnil(L);
        lua_pushstring(L, "bad address");
        return 2;
    }
    int n = (int)sendto(s->fd, data, (int)len, 0, (struct sockaddr *)&to, sizeof to);
    if (n < 0) {
        lua_pushnil(L);
        lua_pushfstring(L, "sendto failed (%d)", last_err());
        return 2;
    }
    lua_pushboolean(L, 1);
    return 1;
}

static int l_sock_recv(lua_State *L) {
    Sock *s = check_sock(L);
    if (!s)
        return luaL_error(L, "socket is closed");
    char buf[2048];
    for (;;) {
        struct sockaddr_in from;
        memset(&from, 0, sizeof from);
        socklen_t flen = sizeof from;
        int n = (int)recvfrom(s->fd, buf, sizeof buf, 0, (struct sockaddr *)&from, &flen);
        if (n < 0) {
            int e = last_err();
            if (err_is_transient(e)) {
#ifdef _WIN32
                if (e == WSAECONNRESET || e == WSAEMSGSIZE)
                    continue;
#else
                if (e == ECONNREFUSED || e == EINTR)
                    continue;
#endif
                return 0; /* nothing pending */
            }
            return 0;
        }
        char ip[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &from.sin_addr, ip, sizeof ip);
        lua_pushlstring(L, buf, (size_t)n);
        lua_pushstring(L, ip);
        lua_pushinteger(L, ntohs(from.sin_port));
        return 3;
    }
}

static int l_sock_port(lua_State *L) {
    Sock *s = check_sock(L);
    if (!s)
        return luaL_error(L, "socket is closed");
    lua_pushinteger(L, s->port);
    return 1;
}

static int l_sock_close(lua_State *L) {
    Sock *s = (Sock *)luaL_checkudata(L, 1, SOCKET_MT);
    if (s->fd != SOCK_BAD)
        sock_close(s->fd);
    s->fd = SOCK_BAD;
    return 0;
}

/* ------------------------------------------------------------------ */
/* threaded DNS                                                        */
/* ------------------------------------------------------------------ */

typedef struct {
    SDL_atomic_t state; /* 0 pending, 1 ok, 2 failed */
    SDL_atomic_t refs;  /* Lua object + worker thread */
    char host[256];
    char result[320];
} Resolve;

typedef struct {
    Resolve *r;
} ResolveUD;

static void resolve_release(Resolve *r) {
    if (SDL_AtomicAdd(&r->refs, -1) == 1)
        free(r);
}

static int resolve_worker(void *p) {
    Resolve *r = (Resolve *)p;
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    if (getaddrinfo(r->host, NULL, &hints, &res) == 0 && res) {
        inet_ntop(AF_INET, &((struct sockaddr_in *)res->ai_addr)->sin_addr, r->result,
                  sizeof r->result);
        freeaddrinfo(res);
        SDL_AtomicSet(&r->state, 1);
    } else {
        snprintf(r->result, sizeof r->result, "cannot resolve %s", r->host);
        SDL_AtomicSet(&r->state, 2);
    }
    resolve_release(r);
    return 0;
}

static int l_resolve(lua_State *L) {
    net_startup();
    const char *host = luaL_checkstring(L, 1);
    Resolve *r = (Resolve *)calloc(1, sizeof *r);
    if (!r)
        return luaL_error(L, "out of memory");
    snprintf(r->host, sizeof r->host, "%s", host);
    SDL_AtomicSet(&r->refs, 2);
    ResolveUD *ud = (ResolveUD *)lua_newuserdatauv(L, sizeof *ud, 0);
    ud->r = r;
    luaL_setmetatable(L, RESOLVE_MT);
    SDL_Thread *t = SDL_CreateThread(resolve_worker, "dns", r);
    if (t) {
        SDL_DetachThread(t);
    } else {
        snprintf(r->result, sizeof r->result, "cannot start resolver thread");
        SDL_AtomicSet(&r->state, 2);
        resolve_release(r);
    }
    return 1;
}

static int l_resolve_result(lua_State *L) {
    ResolveUD *ud = (ResolveUD *)luaL_checkudata(L, 1, RESOLVE_MT);
    int st = SDL_AtomicGet(&ud->r->state);
    if (st == 0)
        return 0;
    if (st == 1) {
        lua_pushstring(L, ud->r->result);
        return 1;
    }
    lua_pushboolean(L, 0);
    lua_pushstring(L, ud->r->result);
    return 2;
}

static int l_resolve_gc(lua_State *L) {
    ResolveUD *ud = (ResolveUD *)luaL_checkudata(L, 1, RESOLVE_MT);
    if (ud->r)
        resolve_release(ud->r);
    ud->r = NULL;
    return 0;
}

/* primary LAN address: "connect" a UDP socket (no packet is sent) and ask
 * the OS which local address it would use */
static int l_local_ip(lua_State *L) {
    net_startup();
    sock_t fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd == SOCK_BAD)
        return 0;
    struct sockaddr_in to, me;
    parse_ipv4("8.8.8.8", 53, &to);
    socklen_t mlen = sizeof me;
    int ok = connect(fd, (struct sockaddr *)&to, sizeof to) == 0 &&
             getsockname(fd, (struct sockaddr *)&me, &mlen) == 0;
    sock_close(fd);
    if (!ok)
        return 0;
    char ip[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &me.sin_addr, ip, sizeof ip);
    lua_pushstring(L, ip);
    return 1;
}

int luaopen_net(lua_State *L) {
    static const luaL_Reg sock_methods[] = {
        {"send", l_sock_send},   {"recv", l_sock_recv}, {"port", l_sock_port},
        {"close", l_sock_close}, {NULL, NULL},
    };
    luaL_newmetatable(L, SOCKET_MT);
    lua_pushcfunction(L, l_sock_close);
    lua_setfield(L, -2, "__gc");
    luaL_newlib(L, sock_methods);
    lua_setfield(L, -2, "__index");
    lua_pop(L, 1);

    static const luaL_Reg res_methods[] = {{"result", l_resolve_result}, {NULL, NULL}};
    luaL_newmetatable(L, RESOLVE_MT);
    lua_pushcfunction(L, l_resolve_gc);
    lua_setfield(L, -2, "__gc");
    luaL_newlib(L, res_methods);
    lua_setfield(L, -2, "__index");
    lua_pop(L, 1);

    static const luaL_Reg fns[] = {
        {"udp", l_udp},
        {"resolve", l_resolve},
        {"local_ip", l_local_ip},
        {NULL, NULL},
    };
    luaL_newlib(L, fns);
    return 1;
}
