#ifndef MINTTORRENT_AWG_API_H
#define MINTTORRENT_AWG_API_H

#ifdef __cplusplus
extern "C" {
#endif

long long mt_stack_open(char *config, int enable_ipv4, int enable_ipv6,
	char *err_buf, int err_cap);
long long mt_stack_open_configured(char *config, int enable_ipv4, int enable_ipv6,
	int mtu, int packet_queue, int tcp_send_buffer, int tcp_receive_buffer,
	char *err_buf, int err_cap);
int mt_stack_set_default(long long id, char *err_buf, int err_cap);
long long mt_stack_get_default(char *err_buf, int err_cap);
int mt_stack_close(long long id, char *err_buf, int err_cap);
int mt_stack_addresses(long long id, char *output, int output_cap,
	char *err_buf, int err_cap);
int mt_stack_status(long long id, long long *last_handshake_ns,
	unsigned long long *tx_bytes, unsigned long long *rx_bytes,
	int *peers, char *err_buf, int err_cap);
int mt_stack_health_status(long long id, int *healthy, long long *checked_at_ns,
	char *message, int message_cap, char *err_buf, int err_cap);
int mt_stack_resolve(long long stack_id, char *hostname, int timeout_ms,
	char *output, int output_cap, char *err_buf, int err_cap);
int mt_stack_http_get(long long stack_id, char *url, int timeout_ms,
	char *output, int output_cap, char *err_buf, int err_cap);
int mt_stack_async_resolve(long long stack_id, unsigned long long operation_id,
	char *hostname, int timeout_ms, char *output, int output_cap,
	char *err_buf, int err_cap);

long long mt_tcp_dial(long long stack_id, char *address, int timeout_ms,
	char *err_buf, int err_cap);
long long mt_tcp_dial_bind(long long stack_id, char *address, char *local_host,
	int local_port, int timeout_ms, char *err_buf, int err_cap);
int mt_tcp_async_connect(long long stack_id, unsigned long long operation_id,
	char *address, char *local_host, int local_port, int timeout_ms,
	char *err_buf, int err_cap);
void mt_tcp_cancel_connect(unsigned long long operation_id);
int mt_tcp_async_accept(long long listener_id, unsigned long long operation_id,
	char *err_buf, int err_cap);
int mt_tcp_async_read(long long id, unsigned long long operation_id, char *dst,
	int length, char *err_buf, int err_cap);
int mt_tcp_async_write(long long id, unsigned long long operation_id, char *src,
	int length, char *err_buf, int err_cap);
long long mt_tcp_listen(long long stack_id, char *host, int port,
	char *err_buf, int err_cap);
long long mt_tcp_accept(long long listener_id, char *err_buf, int err_cap);
int mt_tcp_listener_endpoint(long long listener_id, char *host, int host_cap,
	int *port, char *err_buf, int err_cap);
int mt_tcp_endpoint(long long id, int remote, char *host, int host_cap,
	int *port, char *err_buf, int err_cap);
int mt_tcp_listener_endpoint(long long listener_id, char *host, int host_cap,
	int *port, char *err_buf, int err_cap);
long long mt_tcp_read(long long id, char *dst, int length,
	char *err_buf, int err_cap);
long long mt_tcp_write(long long id, char *src, int length,
	char *err_buf, int err_cap);
int mt_tcp_close(long long id, char *err_buf, int err_cap);

long long mt_udp_open(long long stack_id, char *host, int port,
	char *err_buf, int err_cap);
int mt_udp_local_endpoint(long long id, char *host, int host_cap, int *port,
	char *err_buf, int err_cap);
long long mt_udp_send(long long id, char *host, int port, char *src, int length,
	char *err_buf, int err_cap);
long long mt_udp_receive(long long id, char *dst, int length, char *host,
	int host_cap, int *port, char *err_buf, int err_cap);
int mt_udp_async_receive(long long id, unsigned long long operation_id,
	char *dst, int length, char *host, int host_cap, int *port,
	char *err_buf, int err_cap);
int mt_udp_close(long long id, char *err_buf, int err_cap);

void minttorrent_tcp_connect_complete(unsigned long long operation_id,
	long long socket_id, int error);
void minttorrent_tcp_accept_complete(unsigned long long operation_id,
	long long socket_id, int error);
void minttorrent_tcp_read_complete(unsigned long long operation_id,
	long long bytes, int error);
void minttorrent_tcp_write_complete(unsigned long long operation_id,
	long long bytes, int error);
void minttorrent_udp_read_complete(unsigned long long operation_id,
	long long bytes, int error);
void minttorrent_dns_complete(unsigned long long operation_id,
	long long address_count, int error);

#ifdef __cplusplus
}
#endif

#endif
