//go:build awgnet_test

#include <stdint.h>

// The production callbacks are supplied by minttorrent_netstack.cpp when
// libminttorrent_awg.so is loaded by the application. Parser-only Go tests do
// not start a userspace stack, so provide no-op link targets under awgnet_test.
void minttorrent_tcp_connect_complete(unsigned long long id, long long result, int error) { (void)id; (void)result; (void)error; }
void minttorrent_tcp_accept_complete(unsigned long long id, long long result, int error) { (void)id; (void)result; (void)error; }
void minttorrent_tcp_read_complete(unsigned long long id, long long result, int error) { (void)id; (void)result; (void)error; }
void minttorrent_tcp_write_complete(unsigned long long id, long long result, int error) { (void)id; (void)result; (void)error; }
void minttorrent_udp_read_complete(unsigned long long id, long long result, int error) { (void)id; (void)result; (void)error; }
void minttorrent_dns_complete(unsigned long long id, long long result, int error) { (void)id; (void)result; (void)error; }
