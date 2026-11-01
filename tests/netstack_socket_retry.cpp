#include "libtorrent/aux_/minttorrent_netstack.hpp"
#include "libtorrent/aux_/resolver.hpp"
#include "minttorrent_awg_api.h"

#include <algorithm>
#include <cassert>
#include <cstring>
#include <string>
#include <vector>

namespace {
bool default_stack_available = true;
int connect_calls = 0;
int tcp_listen_calls = 0;
int dns_calls = 0;
std::vector<std::string> destinations;
std::vector<std::string> local_bindings;
std::vector<int> local_ports;
int udp_open_calls = 0;
int udp_close_calls = 0;
std::string udp_bind_host;
int udp_bind_port = -1;
std::string udp_send_endpoint;
std::vector<char> udp_sent_data;
unsigned long long udp_read_operation = 0;
char* udp_read_data = nullptr;
char* udp_read_host = nullptr;
int udp_read_host_cap = 0;
int* udp_read_port = nullptr;
}

extern "C" long long mt_stack_get_default(char*, int)
{
	return default_stack_available ? 1 : -1;
}

extern "C" int mt_stack_async_resolve(long long, unsigned long long, char*, int,
	char*, int, char*, int)
{
	++dns_calls;
	return 0;
}

extern "C" long long mt_tcp_listen(long long stack_id, char*, int, char*, int)
{
	assert(stack_id == 1);
	++tcp_listen_calls;
	return 88;
}

extern "C" int mt_tcp_async_connect(long long, unsigned long long operation_id,
	char* address, char* local_host, int local_port, int, char*, int)
{
	++connect_calls;
	destinations.emplace_back(address);
	local_bindings.emplace_back(local_host);
	local_ports.push_back(local_port);
	// Simulate an unclassified userspace-stack failure. Asio still lets
	// libtorrent close the socket and retry the next resolved tracker IP, while
	// the adapter must not misreport it as a connection refusal.
	minttorrent_tcp_connect_complete(operation_id, -1, 2);
	return 0;
}

extern "C" long long mt_udp_open(long long stack_id, char* host, int port, char*, int)
{
	assert(stack_id == 1);
	++udp_open_calls;
	udp_bind_host = host;
	udp_bind_port = port;
	return 77;
}

extern "C" int mt_udp_local_endpoint(long long id, char* host, int host_cap,
	int* port, char*, int)
{
	assert(id == 77 && host_cap > 0 && port != nullptr);
	std::strncpy(host, "10.0.0.2", static_cast<std::size_t>(host_cap - 1));
	*port = 42424;
	return 0;
}

extern "C" long long mt_udp_send(long long id, char* host, int port,
	char* src, int length, char*, int)
{
	assert(id == 77 && length >= 0);
	udp_send_endpoint = std::string(host) + ":" + std::to_string(port);
	udp_sent_data.assign(src, src + length);
	return length;
}

extern "C" int mt_udp_async_receive(long long id, unsigned long long operation_id,
	char* dst, int, char* host, int host_cap, int* port, char*, int)
{
	assert(id == 77 && operation_id != 0 && dst != nullptr && host_cap > 0 && port != nullptr);
	udp_read_operation = operation_id;
	udp_read_data = dst;
	udp_read_host = host;
	udp_read_host_cap = host_cap;
	udp_read_port = port;
	return 0;
}

extern "C" int mt_udp_close(long long id, char*, int)
{
	assert(id == 77);
	++udp_close_calls;
	return 0;
}

int main()
{
	libtorrent::io_context io;
	default_stack_available = false;
	libtorrent::aux::resolver resolver(io);
	bool dns_done = false;
	boost::system::error_code dns_error;
	resolver.async_resolve("tracker.example", {}, [&](boost::system::error_code const& ec,
		std::vector<libtorrent::address> const&) { dns_error = ec; dns_done = true; });
	io.run();
	assert(dns_done && dns_error == boost::asio::error::host_not_found);
	assert(dns_calls == 0);

	io.restart();
	libtorrent::aux::minttorrent_tcp_socket closed_tcp(io);
	bool closed_tcp_done = false;
	boost::system::error_code closed_tcp_error;
	closed_tcp.async_connect({boost::asio::ip::make_address("198.51.100.5"), 80},
		[&](boost::system::error_code const& ec) { closed_tcp_error = ec; closed_tcp_done = true; });
	io.run();
	assert(closed_tcp_done && closed_tcp_error == boost::system::errc::make_error_code(boost::system::errc::io_error));
	assert(connect_calls == 0);

	boost::system::error_code ec;
	libtorrent::aux::minttorrent_tcp_acceptor closed_acceptor(io);
	closed_acceptor.open(boost::asio::ip::tcp::v4(), ec);
	assert(!ec);
	closed_acceptor.bind({boost::asio::ip::make_address("0.0.0.0"), 0}, ec);
	assert(!ec);
	closed_acceptor.listen(ec);
	assert(ec == boost::system::errc::make_error_code(boost::system::errc::address_not_available));
	assert(tcp_listen_calls == 0);

	libtorrent::aux::minttorrent_udp_socket closed_udp(io);
	closed_udp.open(boost::asio::ip::udp::v4(), ec);
	assert(!ec);
	closed_udp.bind({boost::asio::ip::make_address("10.0.0.2"), 0}, ec);
	assert(ec == boost::system::errc::make_error_code(boost::system::errc::address_not_available));
	assert(udp_open_calls == 0);
	std::string const blocked_udp_payload = "blocked-dht";
	assert(closed_udp.send_to(boost::asio::buffer(blocked_udp_payload),
		{boost::asio::ip::make_address("198.51.100.42"), 6969}, ec) == 0);
	assert(ec == boost::asio::error::bad_descriptor && udp_send_endpoint.empty());
	closed_udp.close();

	default_stack_available = true;
	io.restart();
	libtorrent::aux::minttorrent_tcp_socket socket(io);
	boost::system::error_code first_error;
	bool first_done = false;
	socket.async_connect({boost::asio::ip::make_address("192.0.2.10"), 8080},
		[&](boost::system::error_code const& ec) { first_error = ec; first_done = true; });
	io.run();
	assert(first_done);
	assert(first_error == boost::system::errc::make_error_code(boost::system::errc::io_error));
	assert(socket.is_open());

	socket.close();
	io.restart();
	boost::system::error_code retry_error;
	bool retry_done = false;
	socket.async_connect({boost::asio::ip::make_address("192.0.2.11"), 8080},
		[&](boost::system::error_code const& ec) { retry_error = ec; retry_done = true; });
	io.run();
	assert(retry_done);
	assert(retry_error == boost::system::errc::make_error_code(boost::system::errc::io_error));
	assert(connect_calls == 2);
	assert(destinations.size() == 2);
	assert(destinations[0] == "192.0.2.10:8080");
	assert(destinations[1] == "192.0.2.11:8080");
	libtorrent::aux::minttorrent_tcp_socket bound_socket(io);
	bound_socket.open(boost::asio::ip::tcp::v4(), ec);
	assert(!ec);
	bound_socket.bind({boost::asio::ip::make_address("192.0.2.99"), 4242}, ec);
	assert(!ec);
	io.restart();
	bool bound_first_done = false;
	bound_socket.async_connect({boost::asio::ip::make_address("192.0.2.12"), 8080},
		[&](boost::system::error_code const& result) {
			assert(result == boost::system::errc::make_error_code(boost::system::errc::io_error));
			bound_first_done = true;
		});
	io.run();
	assert(bound_first_done);
	bound_socket.close();
	io.restart();
	bool bound_retry_done = false;
	bound_socket.async_connect({boost::asio::ip::make_address("192.0.2.13"), 8080},
		[&](boost::system::error_code const& result) {
			assert(result == boost::system::errc::make_error_code(boost::system::errc::io_error));
			bound_retry_done = true;
		});
	io.run();
	assert(bound_retry_done);
	assert(connect_calls == 4);
	assert(local_bindings[2] == "192.0.2.99" && local_ports[2] == 4242);
	assert(local_bindings[3] == "192.0.2.99" && local_ports[3] == 4242);

	libtorrent::aux::minttorrent_udp_socket udp(io);
	udp.open(boost::asio::ip::udp::v4(), ec);
	assert(!ec);
	udp.bind({boost::asio::ip::make_address("10.0.0.2"), 0}, ec);
	assert(!ec && udp_open_calls == 1);
	assert(udp_bind_host == "10.0.0.2" && udp_bind_port == 0);
	assert(udp.local_endpoint() == boost::asio::ip::udp::endpoint(
		boost::asio::ip::make_address("10.0.0.2"), 42424));

	std::string const outbound = "dht-ping";
	auto const destination = boost::asio::ip::udp::endpoint(
		boost::asio::ip::make_address("198.51.100.42"), 6969);
	assert(udp.send_to(boost::asio::buffer(outbound), destination, ec) == outbound.size());
	assert(!ec && udp_send_endpoint == "198.51.100.42:6969");
	assert(std::string(udp_sent_data.begin(), udp_sent_data.end()) == outbound);

	std::array<char, 64> receive_buffer{};
	boost::asio::ip::udp::endpoint source;
	bool udp_receive_done = false;
	std::size_t udp_received = 0;
	boost::system::error_code udp_receive_error;
	io.restart();
	udp.async_receive_from(boost::asio::buffer(receive_buffer), source,
		[&](boost::system::error_code const& result, std::size_t bytes) {
			udp_receive_error = result;
			udp_received = bytes;
			udp_receive_done = true;
		});
	assert(udp_read_operation != 0 && udp_read_data != nullptr);
	std::string const inbound = "dht-pong";
	std::copy(inbound.begin(), inbound.end(), udp_read_data);
	std::strncpy(udp_read_host, "203.0.113.17", static_cast<std::size_t>(udp_read_host_cap - 1));
	*udp_read_port = 51413;
	minttorrent_udp_read_complete(udp_read_operation, inbound.size(), 0);
	io.run();
	assert(udp_receive_done && !udp_receive_error && udp_received == inbound.size());
	assert(std::string(receive_buffer.data(), udp_received) == inbound);
	assert(source == boost::asio::ip::udp::endpoint(
		boost::asio::ip::make_address("203.0.113.17"), 51413));
	udp.close();
	assert(udp_close_calls == 1 && !udp.is_open());
	return 0;
}
