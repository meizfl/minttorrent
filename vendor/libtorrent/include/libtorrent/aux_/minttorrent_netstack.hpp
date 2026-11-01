/*
 * MintTorrent's libtorrent 2.1 socket adapters.
 *
 * Libtorrent runs its networking state machine on Boost.Asio. The actual IP
 * sockets live in AmneziaWG-Go's in-process gVisor Netstack. C ABI operations
 * complete from Go goroutines and are posted back to the owning io_context.
 */

#ifndef TORRENT_MINTTORRENT_NETSTACK_HPP
#define TORRENT_MINTTORRENT_NETSTACK_HPP

#include "libtorrent/io_context.hpp"
#include "libtorrent/aux_/export.hpp"
#include "minttorrent_awg_api.h"

#include <boost/asio.hpp>
#include <boost/system/errc.hpp>

#include <atomic>
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

namespace libtorrent::aux {

using mt_error_code = boost::system::error_code;
using mt_tcp_ep = boost::asio::ip::tcp::endpoint;
using mt_udp_endpoint = boost::asio::ip::udp::endpoint;
using mt_executor = boost::asio::any_io_executor;

std::uint64_t register_mt_operation(mt_executor executor
	, std::function<void(long long, int)> completion);
void complete_mt_operation(std::uint64_t id, long long value, int error);

inline mt_error_code mt_error(int status, bool = false)
{
	switch (status)
	{
		case 0: return {};
		case 1: return boost::asio::error::eof;
		case 3: return boost::asio::error::operation_aborted;
		default:
			// The C ABI currently preserves only success/EOF/cancel/other. Do not
			// claim an unknown gVisor failure was a TCP reset/refusal: that turns
			// routing and timeout failures into misleading tracker diagnostics.
			return boost::system::errc::make_error_code(boost::system::errc::io_error);
	}
}

inline long long mt_default_stack(char* err)
{
	return mt_stack_get_default(err, 512);
}

inline std::string mt_ip_string(boost::asio::ip::address const& ip)
{
	return ip.to_string();
}

inline std::string mt_endpoint_string(mt_tcp_ep const& ep)
{
	std::string host = mt_ip_string(ep.address());
	if (ep.address().is_v6()) host = "[" + host + "]";
	return host + ":" + std::to_string(ep.port());
}

inline mt_error_code mt_read_endpoint(long long id, bool remote, mt_tcp_ep& out)
{
	char host[80]{};
	int port = 0;
	char error[512]{};
	if (mt_tcp_endpoint(id, remote ? 1 : 0, host, sizeof(host), &port, error, sizeof(error)) != 0)
		return boost::asio::error::operation_aborted;
	boost::system::error_code ec;
	auto const address = boost::asio::ip::make_address(host, ec);
	if (!ec) out = mt_tcp_ep(address, static_cast<unsigned short>(port));
	return ec;
}

inline mt_error_code mt_read_listener_endpoint(long long id, mt_tcp_ep& out)
{
	char host[80]{};
	int port = 0;
	char error[512]{};
	if (mt_tcp_listener_endpoint(id, host, sizeof(host), &port, error, sizeof(error)) != 0)
		return boost::asio::error::operation_aborted;
	boost::system::error_code ec;
	auto const address = boost::asio::ip::make_address(host, ec);
	if (!ec) out = mt_tcp_ep(address, static_cast<unsigned short>(port));
	return ec;
}

struct mt_tcp_state
{
	explicit mt_tcp_state(io_context& io)
		: executor(io.get_executor()), context(&io) {}

	mt_executor executor;
	io_context* context;
	std::mutex mutex;
	long long handle = -1;
	std::uint64_t pending_connect = 0;
	mt_tcp_ep local{boost::asio::ip::address_v4::any(), 0};
	mt_tcp_ep remote{boost::asio::ip::address_v4::any(), 0};
	int family = AF_INET;
	bool open = false;
	bool closed = false;
};

class minttorrent_tcp_socket
{
public:
	using executor_type = mt_executor;
	using endpoint_type = mt_tcp_ep;
	using protocol_type = boost::asio::ip::tcp;
	using lowest_layer_type = minttorrent_tcp_socket;
	using wait_type = boost::asio::socket_base::wait_type;
	using receive_buffer_size = boost::asio::socket_base::receive_buffer_size;
	using send_buffer_size = boost::asio::socket_base::send_buffer_size;
	static constexpr wait_type wait_read = boost::asio::socket_base::wait_read;
	static constexpr wait_type wait_write = boost::asio::socket_base::wait_write;
	static constexpr wait_type wait_error = boost::asio::socket_base::wait_error;

	explicit minttorrent_tcp_socket(io_context& io)
		: m_state(std::make_shared<mt_tcp_state>(io)) {}

	minttorrent_tcp_socket(io_context& io, long long handle)
		: minttorrent_tcp_socket(io)
	{
		m_state->handle = handle;
		m_state->open = true;
		(void)mt_read_endpoint(handle, false, m_state->local);
		(void)mt_read_endpoint(handle, true, m_state->remote);
	}

	minttorrent_tcp_socket(minttorrent_tcp_socket&&) noexcept = default;
	minttorrent_tcp_socket& operator=(minttorrent_tcp_socket&&) noexcept = default;
	minttorrent_tcp_socket(minttorrent_tcp_socket const&) = delete;
	minttorrent_tcp_socket& operator=(minttorrent_tcp_socket const&) = delete;
	~minttorrent_tcp_socket() { close(); }

	executor_type get_executor() { return m_state->executor; }

	void open(protocol_type const& protocol, mt_error_code& ec)
	{
		std::lock_guard<std::mutex> lock(m_state->mutex);
		m_state->family = protocol.family();
		m_state->local = protocol == protocol_type::v6()
			? mt_tcp_ep(boost::asio::ip::address_v6::any(), 0)
			: mt_tcp_ep(boost::asio::ip::address_v4::any(), 0);
		m_state->open = true;
		m_state->closed = false;
		ec.clear();
	}

	void bind(endpoint_type const& ep, mt_error_code& ec)
	{
		std::lock_guard<std::mutex> lock(m_state->mutex);
		if (!m_state->open || m_state->handle >= 0)
		{
			ec = boost::asio::error::bad_descriptor;
			return;
		}
		m_state->local = ep;
		ec.clear();
	}

	template <class Handler>
	void async_connect(endpoint_type const& ep, Handler&& handler)
	{
		using handler_type = std::decay_t<Handler>;
		auto h = std::make_shared<handler_type>(std::forward<Handler>(handler));
		auto state = m_state;
		endpoint_type local;
		{
			std::lock_guard<std::mutex> lock(state->mutex);
			// Boost.Asio's basic_stream_socket opens an unopened socket as part
			// of async_connect. It also allows a closed socket to be reused for
			// another connect. Tracker HTTP connections rely on both behaviours:
			// they do not explicitly open the socket, and retry another resolved
			// address after closing it when a connect fails.
			if (!state->open || state->closed)
			{
				if (state->handle >= 0)
				{
					boost::asio::post(state->executor, [h] { (*h)(boost::asio::error::already_connected); });
					return;
				}
				// Preserve a caller's explicit bind across endpoint retries. An
				// unbound socket can follow a different address family on retry.
				if (state->local.address().is_unspecified())
				{
					state->family = ep.address().is_v6() ? AF_INET6 : AF_INET;
					state->local = ep.address().is_v6()
						? mt_tcp_ep(boost::asio::ip::address_v6::any(), 0)
						: mt_tcp_ep(boost::asio::ip::address_v4::any(), 0);
				}
				state->open = true;
				state->closed = false;
			}
			local = state->local;
		}
		auto const operation = register_mt_operation(state->executor
			, [state, h, ep](long long handle, int status) mutable
		{
			mt_error_code ec = mt_error(status, true);
			{
				std::lock_guard<std::mutex> lock(state->mutex);
				state->pending_connect = 0;
				if (!ec && !state->closed)
				{
					state->handle = handle;
					state->remote = ep;
					(void)mt_read_endpoint(handle, false, state->local);
				}
				else if (handle >= 0)
				{
					char error[64]{};
					(void)mt_tcp_close(handle, error, sizeof(error));
					if (!ec) ec = boost::asio::error::operation_aborted;
				}
			}
			(*h)(ec);
		});
		{
			std::lock_guard<std::mutex> lock(state->mutex);
			state->pending_connect = operation;
		}
		char err[512]{};
		char local_host[80]{};
		std::string host;
		if (!local.address().is_unspecified()) host = mt_ip_string(local.address());
		std::copy(host.begin(), host.end(), local_host);
		char remote[160]{};
		std::string remote_text = mt_endpoint_string(ep);
		std::copy(remote_text.begin(), remote_text.end(), remote);
		long long stack = mt_default_stack(err);
		int const result = stack < 0 ? -1 : mt_tcp_async_connect(stack, operation
			, remote, local_host, local.port(), 30000, err, sizeof(err));
		if (result != 0) complete_mt_operation(operation, -1, 2);
	}

	template <class MutableBufferSequence, class Handler>
	void async_read_some(MutableBufferSequence const& buffers, Handler&& handler)
	{
		using handler_type = std::decay_t<Handler>;
		auto h = std::make_shared<handler_type>(std::forward<Handler>(handler));
		auto state = m_state;
		auto data = std::make_shared<std::vector<char>>(boost::asio::buffer_size(buffers));
		long long handle = 0;
		{
			std::lock_guard<std::mutex> lock(state->mutex);
			handle = state->handle;
		}
		if (handle < 0)
		{
			boost::asio::post(state->executor, [h] { (*h)(boost::asio::error::not_connected, 0); });
			return;
		}
		auto buffers_copy = buffers;
		auto const operation = register_mt_operation(state->executor
			, [h, data, buffers_copy](long long bytes, int status) mutable
		{
			std::size_t const n = bytes > 0 ? static_cast<std::size_t>(bytes) : 0;
			if (n > 0) boost::asio::buffer_copy(buffers_copy, boost::asio::buffer(*data), n);
			(*h)(mt_error(n > 0 ? 0 : status), n);
		});
		char err[512]{};
		int const result = mt_tcp_async_read(handle, operation, data->data()
			, static_cast<int>(data->size()), err, sizeof(err));
		if (result != 0) complete_mt_operation(operation, -1, 2);
	}

	template <class ConstBufferSequence, class Handler>
	void async_write_some(ConstBufferSequence const& buffers, Handler&& handler)
	{
		using handler_type = std::decay_t<Handler>;
		auto h = std::make_shared<handler_type>(std::forward<Handler>(handler));
		auto state = m_state;
		auto data = std::make_shared<std::vector<char>>(boost::asio::buffer_size(buffers));
		boost::asio::buffer_copy(boost::asio::buffer(*data), buffers);
		long long handle = 0;
		{
			std::lock_guard<std::mutex> lock(state->mutex);
			handle = state->handle;
		}
		if (handle < 0)
		{
			boost::asio::post(state->executor, [h] { (*h)(boost::asio::error::not_connected, 0); });
			return;
		}
		auto const operation = register_mt_operation(state->executor
			, [h](long long bytes, int status)
		{ (*h)(mt_error(status), bytes > 0 ? static_cast<std::size_t>(bytes) : 0); });
		char err[512]{};
		int const result = mt_tcp_async_write(handle, operation, data->data()
			, static_cast<int>(data->size()), err, sizeof(err));
		if (result != 0) complete_mt_operation(operation, -1, 2);
	}

	template <class MutableBufferSequence>
	std::size_t read_some(MutableBufferSequence const& buffers, mt_error_code& ec)
	{
		long long handle = current_handle();
		if (handle < 0) { ec = boost::asio::error::not_connected; return 0; }
		std::vector<char> data(boost::asio::buffer_size(buffers));
		char error[512]{};
		long long const bytes = mt_tcp_read(handle, data.data(), static_cast<int>(data.size()), error, sizeof(error));
		if (bytes < 0) { ec = boost::system::errc::make_error_code(boost::system::errc::io_error); return 0; }
		ec.clear();
		return boost::asio::buffer_copy(buffers, boost::asio::buffer(data), static_cast<std::size_t>(bytes));
	}

	template <class ConstBufferSequence>
	std::size_t write_some(ConstBufferSequence const& buffers, mt_error_code& ec)
	{
		long long handle = current_handle();
		if (handle < 0) { ec = boost::asio::error::not_connected; return 0; }
		std::vector<char> data(boost::asio::buffer_size(buffers));
		boost::asio::buffer_copy(boost::asio::buffer(data), buffers);
		char error[512]{};
		long long const bytes = mt_tcp_write(handle, data.data(), static_cast<int>(data.size()), error, sizeof(error));
		if (bytes < 0) { ec = boost::system::errc::make_error_code(boost::system::errc::io_error); return 0; }
		ec.clear();
		return static_cast<std::size_t>(bytes);
	}

	template <class MutableBufferSequence>
	std::size_t read_some(MutableBufferSequence const& buffers)
	{
		mt_error_code ec; auto const n = read_some(buffers, ec); if (ec) throw boost::system::system_error(ec); return n;
	}
	template <class ConstBufferSequence>
	std::size_t write_some(ConstBufferSequence const& buffers)
	{
		mt_error_code ec; auto const n = write_some(buffers, ec); if (ec) throw boost::system::system_error(ec); return n;
	}

	endpoint_type local_endpoint(mt_error_code& ec) const
	{
		std::lock_guard<std::mutex> lock(m_state->mutex);
		if (!m_state->open || m_state->closed) { ec = boost::asio::error::bad_descriptor; return {}; }
		ec.clear(); return m_state->local;
	}
	endpoint_type local_endpoint() const { mt_error_code ec; auto ep = local_endpoint(ec); if (ec) throw boost::system::system_error(ec); return ep; }
	endpoint_type remote_endpoint(mt_error_code& ec) const
	{
		std::lock_guard<std::mutex> lock(m_state->mutex);
		if (m_state->handle < 0 || m_state->closed) { ec = boost::asio::error::not_connected; return {}; }
		ec.clear(); return m_state->remote;
	}
	endpoint_type remote_endpoint() const { mt_error_code ec; auto ep = remote_endpoint(ec); if (ec) throw boost::system::system_error(ec); return ep; }
	protocol_type protocol() const { return m_state->family == AF_INET6 ? protocol_type::v6() : protocol_type::v4(); }
	bool is_open() const { std::lock_guard<std::mutex> lock(m_state->mutex); return m_state->open && !m_state->closed; }
	int native_handle() const { return -1; }
	std::size_t available(mt_error_code& ec) const { ec.clear(); return 0; }
	std::size_t available() const { return 0; }
	void non_blocking(bool, mt_error_code& ec) { ec.clear(); }
	void non_blocking(bool) {}
	void shutdown(boost::asio::socket_base::shutdown_type, mt_error_code& ec) { ec.clear(); }
	void shutdown(boost::asio::socket_base::shutdown_type) {}
	minttorrent_tcp_socket& lowest_layer() { return *this; }
	minttorrent_tcp_socket const& lowest_layer() const { return *this; }

	template <class Option> void set_option(Option const&, mt_error_code& ec) { ec.clear(); }
	template <class Option> void get_option(Option&, mt_error_code& ec) const { ec.clear(); }
	template <class Command> void io_control(Command&, mt_error_code& ec) { ec.clear(); }
	template <class Command> void io_control(Command&) {}
	template <class Handler> void async_wait(wait_type, Handler&& handler)
	{
		boost::asio::post(get_executor(), [h = std::forward<Handler>(handler)]() mutable { h({}); });
	}

	void cancel(mt_error_code& ec) { close(ec); }
	void cancel() { close(); }
	void close(mt_error_code& ec)
	{
		if (!m_state) { ec.clear(); return; }
		long long handle = -1;
		std::uint64_t operation = 0;
		{
			std::lock_guard<std::mutex> lock(m_state->mutex);
			if (m_state->closed) { ec.clear(); return; }
			m_state->closed = true;
			m_state->open = false;
			handle = std::exchange(m_state->handle, -1);
			operation = std::exchange(m_state->pending_connect, 0);
		}
		if (operation != 0) mt_tcp_cancel_connect(operation);
		if (handle >= 0) { char error[64]{}; (void)mt_tcp_close(handle, error, sizeof(error)); }
		ec.clear();
	}
	void close() { mt_error_code ec; close(ec); }

private:
	long long current_handle() const { std::lock_guard<std::mutex> lock(m_state->mutex); return m_state->handle; }
	std::shared_ptr<mt_tcp_state> m_state;
};

struct mt_tcp_acceptor_state
{
	explicit mt_tcp_acceptor_state(io_context& io)
		: executor(io.get_executor()), context(&io) {}
	mt_executor executor;
	io_context* context;
	std::mutex mutex;
	long long handle = -1;
	mt_tcp_ep local{boost::asio::ip::address_v4::any(), 0};
	int family = AF_INET;
	bool open = false;
	bool closed = false;
};

class minttorrent_tcp_acceptor
{
public:
	using executor_type = mt_executor;
	using endpoint_type = mt_tcp_ep;
	using protocol_type = boost::asio::ip::tcp;
	using reuse_address = boost::asio::socket_base::reuse_address;
	using send_buffer_size = boost::asio::socket_base::send_buffer_size;
	using receive_buffer_size = boost::asio::socket_base::receive_buffer_size;
	explicit minttorrent_tcp_acceptor(io_context& io) : m_state(std::make_shared<mt_tcp_acceptor_state>(io)) {}
	minttorrent_tcp_acceptor(minttorrent_tcp_acceptor&&) noexcept = default;
	minttorrent_tcp_acceptor& operator=(minttorrent_tcp_acceptor&&) noexcept = default;
	minttorrent_tcp_acceptor(minttorrent_tcp_acceptor const&) = delete;
	~minttorrent_tcp_acceptor() { close(); }
	executor_type get_executor() { return m_state->executor; }
	void open(protocol_type const& p, mt_error_code& ec) { std::lock_guard<std::mutex> l(m_state->mutex); m_state->family=p.family(); m_state->open=true; m_state->closed=false; m_state->local = p==protocol_type::v6()?endpoint_type(boost::asio::ip::address_v6::any(),0):endpoint_type(boost::asio::ip::address_v4::any(),0); ec.clear(); }
	void bind(endpoint_type const& ep, mt_error_code& ec) { std::lock_guard<std::mutex> l(m_state->mutex); if(!m_state->open||m_state->closed){ec=boost::asio::error::bad_descriptor;return;} m_state->local=ep; ec.clear(); }
	void listen(int, mt_error_code& ec)
	{
		std::lock_guard<std::mutex> l(m_state->mutex);
		if (!m_state->open || m_state->closed) { ec=boost::asio::error::bad_descriptor; return; }
		char error[512]{}; long long stack=mt_default_stack(error); char host[80]{};
		std::string address=mt_ip_string(m_state->local.address()); std::copy(address.begin(),address.end(),host);
		m_state->handle=stack<0?-1:mt_tcp_listen(stack,host,m_state->local.port(),error,sizeof(error));
		if(m_state->handle<0){ec=boost::system::errc::make_error_code(boost::system::errc::address_not_available);return;}
		ec = mt_read_listener_endpoint(m_state->handle, m_state->local);
		if (ec)
		{
			char error[64]{};
			(void)mt_tcp_close(m_state->handle, error, sizeof(error));
			m_state->handle = -1;
			return;
		}
		ec.clear();
	}
	void listen(mt_error_code& ec) { listen(boost::asio::socket_base::max_listen_connections, ec); }
	endpoint_type local_endpoint(mt_error_code& ec) const { std::lock_guard<std::mutex> l(m_state->mutex); if(!m_state->open||m_state->closed){ec=boost::asio::error::bad_descriptor;return{};} ec.clear();return m_state->local; }
	endpoint_type local_endpoint() const { mt_error_code ec; auto ep=local_endpoint(ec); if(ec)throw boost::system::system_error(ec);return ep; }
	bool is_open() const { std::lock_guard<std::mutex> l(m_state->mutex); return m_state->open&&!m_state->closed; }
	template<class Option> void set_option(Option const&,mt_error_code& ec){ec.clear();}
	template<class Option> void get_option(Option&,mt_error_code& ec) const {ec.clear();}
	template<class Handler> void async_accept(Handler&& handler)
	{
		using handler_type=std::decay_t<Handler>; auto h=std::make_shared<handler_type>(std::forward<Handler>(handler)); auto state=m_state; long long listener;
		{std::lock_guard<std::mutex> l(state->mutex);listener=state->handle;}
		if(listener<0){boost::asio::post(state->executor,[h,io=state->context]{(*h)(boost::asio::error::bad_descriptor,minttorrent_tcp_socket(*io));});return;}
		auto const operation=register_mt_operation(state->executor,[h,io=state->context](long long socket,int status) mutable {mt_error_code ec=mt_error(status,true);minttorrent_tcp_socket accepted(*io);if(!ec)accepted=minttorrent_tcp_socket(*io,socket);(*h)(ec,std::move(accepted));});
		char error[512]{}; if(mt_tcp_async_accept(listener,operation,error,sizeof(error))!=0)complete_mt_operation(operation,-1,2);
	}
	void close(mt_error_code& ec)
	{
		if (!m_state) { ec.clear(); return; }
		long long h=-1; {std::lock_guard<std::mutex> l(m_state->mutex);if(m_state->closed){ec.clear();return;}m_state->closed=true;m_state->open=false;h=std::exchange(m_state->handle,-1);}
		if(h>=0){char error[64]{};(void)mt_tcp_close(h,error,sizeof(error));}ec.clear();
	}
	void close(){mt_error_code ec;close(ec);}

private:
	std::shared_ptr<mt_tcp_acceptor_state> m_state;
};

struct mt_udp_packet
{
	std::vector<char> data;
	mt_udp_endpoint from;
	mt_error_code error;
};

struct mt_udp_state
{
	explicit mt_udp_state(io_context& io):executor(io.get_executor()){}
	mt_executor executor;
	std::mutex mutex;
	long long handle=-1;
	int family=AF_INET;
	mt_udp_endpoint local{boost::asio::ip::address_v4::any(),0};
	std::deque<mt_udp_packet> packets;
	bool open=false,closed=false,read_pending=false;
};

class minttorrent_udp_socket
{
public:
	using executor_type=mt_executor; using endpoint_type=mt_udp_endpoint; using protocol_type=boost::asio::ip::udp;
	using wait_type=boost::asio::socket_base::wait_type; using reuse_address=boost::asio::socket_base::reuse_address;
	using receive_buffer_size=boost::asio::socket_base::receive_buffer_size; using send_buffer_size=boost::asio::socket_base::send_buffer_size;
	static constexpr wait_type wait_read=boost::asio::socket_base::wait_read; static constexpr wait_type wait_write=boost::asio::socket_base::wait_write; static constexpr wait_type wait_error=boost::asio::socket_base::wait_error;
	explicit minttorrent_udp_socket(io_context& io):m_state(std::make_shared<mt_udp_state>(io)){}
	minttorrent_udp_socket(minttorrent_udp_socket&&) noexcept=default; minttorrent_udp_socket& operator=(minttorrent_udp_socket&&) noexcept=default; minttorrent_udp_socket(minttorrent_udp_socket const&)=delete; ~minttorrent_udp_socket(){close();}
	executor_type get_executor(){return m_state->executor;}
	void open(protocol_type const& p,mt_error_code& ec){std::lock_guard<std::mutex> l(m_state->mutex);m_state->family=p.family();m_state->open=true;m_state->closed=false;m_state->local=p==protocol_type::v6()?endpoint_type(boost::asio::ip::address_v6::any(),0):endpoint_type(boost::asio::ip::address_v4::any(),0);ec.clear();}
	void bind(endpoint_type const& ep,mt_error_code& ec)
	{
		std::lock_guard<std::mutex> l(m_state->mutex);if(!m_state->open||m_state->closed){ec=boost::asio::error::bad_descriptor;return;}
		char error[512]{},host[80]{};std::string address=mt_ip_string(ep.address());std::copy(address.begin(),address.end(),host);long long stack=mt_default_stack(error);
		m_state->handle=stack<0?-1:mt_udp_open(stack,host,ep.port(),error,sizeof(error));if(m_state->handle<0){ec=boost::system::errc::make_error_code(boost::system::errc::address_not_available);return;}
		m_state->local=ep;char bound[80]{};int port=0;if(mt_udp_local_endpoint(m_state->handle,bound,sizeof(bound),&port,error,sizeof(error))==0){boost::system::error_code x;auto a=boost::asio::ip::make_address(bound,x);if(!x)m_state->local={a,static_cast<unsigned short>(port)};}ec.clear();
	}
	endpoint_type local_endpoint(mt_error_code& ec)const{std::lock_guard<std::mutex> l(m_state->mutex);if(m_state->handle<0){ec=boost::asio::error::bad_descriptor;return{};}ec.clear();return m_state->local;}
	endpoint_type local_endpoint()const{mt_error_code ec;auto ep=local_endpoint(ec);if(ec)throw boost::system::system_error(ec);return ep;}
	protocol_type protocol()const{return m_state->family==AF_INET6?protocol_type::v6():protocol_type::v4();}
	bool is_open()const{std::lock_guard<std::mutex> l(m_state->mutex);return m_state->open&&!m_state->closed;}
	void non_blocking(bool,mt_error_code& ec){ec.clear();} void non_blocking(bool){}
	template<class Option>void set_option(Option const&,mt_error_code& ec){ec.clear();} template<class Option>void get_option(Option&,mt_error_code& ec)const{ec.clear();}
	template<class ConstBufferSequence>std::size_t send_to(ConstBufferSequence const& buffers,endpoint_type const& ep,int,mt_error_code& ec)
	{
		long long h;{std::lock_guard<std::mutex> l(m_state->mutex);h=m_state->handle;}if(h<0){ec=boost::asio::error::bad_descriptor;return 0;}
		std::vector<char> data(boost::asio::buffer_size(buffers));boost::asio::buffer_copy(boost::asio::buffer(data),buffers);std::string host=mt_ip_string(ep.address());char error[512]{};
		long long n=mt_udp_send(h,const_cast<char*>(host.c_str()),ep.port(),data.data(),static_cast<int>(data.size()),error,sizeof(error));if(n<0){ec=boost::system::errc::make_error_code(boost::system::errc::io_error);return 0;}ec.clear();return static_cast<std::size_t>(n);
	}
	template<class ConstBufferSequence>std::size_t send_to(ConstBufferSequence const& b,endpoint_type const& ep,mt_error_code& ec){return send_to(b,ep,0,ec);}
	template<class ConstBufferSequence>std::size_t send_to(ConstBufferSequence const& b,endpoint_type const& ep,int flags=0){mt_error_code ec;auto n=send_to(b,ep,flags,ec);if(ec)throw boost::system::system_error(ec);return n;}
	template<class MutableBufferSequence>std::size_t receive_from(MutableBufferSequence const& buffers,endpoint_type& from,int,mt_error_code& ec)
	{
		mt_udp_packet packet;{std::lock_guard<std::mutex> l(m_state->mutex);if(m_state->packets.empty()){ec=boost::asio::error::would_block;return 0;}packet=std::move(m_state->packets.front());m_state->packets.pop_front();}
		if(packet.error){ec=packet.error;return 0;}from=packet.from;std::size_t n=boost::asio::buffer_copy(buffers,boost::asio::buffer(packet.data));if(n<packet.data.size()){ec=boost::asio::error::message_size;}else ec.clear();return n;
	}
	template<class MutableBufferSequence>std::size_t receive_from(MutableBufferSequence const& b,endpoint_type& ep,mt_error_code& ec){return receive_from(b,ep,0,ec);}
	template<class MutableBufferSequence>std::size_t receive_from(MutableBufferSequence const& b,endpoint_type& ep,int flags=0){mt_error_code ec;auto n=receive_from(b,ep,flags,ec);if(ec)throw boost::system::system_error(ec);return n;}
	template<class MutableBufferSequence,class Handler>void async_receive_from(MutableBufferSequence const& buffers,endpoint_type& from,int,Handler&& handler)
	{
		using handler_type=std::decay_t<Handler>;auto h=std::make_shared<handler_type>(std::forward<Handler>(handler));auto state=m_state;
		async_wait(wait_read,[this,state,buffers,&from,h](mt_error_code wait_ec) mutable {
			mt_error_code ec=wait_ec;std::size_t bytes=0;if(!ec)bytes=receive_from(buffers,from,0,ec);
			boost::asio::post(state->executor,[h,ec,bytes]{(*h)(ec,bytes);});
		});
	}
	template<class MutableBufferSequence,class Handler>void async_receive_from(MutableBufferSequence const& b,endpoint_type& ep,Handler&& h){async_receive_from(b,ep,0,std::forward<Handler>(h));}
	template<class Handler>void async_wait(wait_type type,Handler&& handler)
	{
		using handler_type=std::decay_t<Handler>;auto h=std::make_shared<handler_type>(std::forward<Handler>(handler));auto state=m_state;
		if(type!=wait_read){boost::asio::post(state->executor,[h]{(*h)(mt_error_code{});});return;}
		long long socket;{std::lock_guard<std::mutex> l(state->mutex);if(state->closed||state->handle<0){boost::asio::post(state->executor,[h]{(*h)(mt_error_code(boost::asio::error::bad_descriptor));});return;}if(!state->packets.empty()){boost::asio::post(state->executor,[h]{(*h)(mt_error_code{});});return;}if(state->read_pending){boost::asio::post(state->executor,[h]{(*h)(boost::system::errc::make_error_code(boost::system::errc::operation_in_progress));});return;}state->read_pending=true;socket=state->handle;}
		auto data=std::make_shared<std::vector<char>>(65536);auto host=std::make_shared<std::array<char,80>>();auto port=std::make_shared<int>(0);
		auto operation=register_mt_operation(state->executor,[state,h,data,host,port](long long bytes,int status){mt_udp_packet p;p.error=mt_error(status);if(!p.error){boost::system::error_code ec;auto address=boost::asio::ip::make_address(host->data(),ec);if(ec)p.error=ec;else{p.data.assign(data->begin(),data->begin()+std::max<long long>(0,bytes));p.from={address,static_cast<unsigned short>(*port)};}}{std::lock_guard<std::mutex> l(state->mutex);state->read_pending=false;if(!state->closed)state->packets.push_back(std::move(p));}(*h)(status==0?mt_error_code{}:mt_error(status));});
		char error[512]{};if(mt_udp_async_receive(socket,operation,data->data(),static_cast<int>(data->size()),host->data(),host->size(),port.get(),error,sizeof(error))!=0){std::fprintf(stderr,"MintTorrent UDP async receive setup failed: %s\n",error);complete_mt_operation(operation,-1,2);}
	}
	void close(mt_error_code& ec){if(!m_state){ec.clear();return;}long long h=-1;{std::lock_guard<std::mutex> l(m_state->mutex);if(m_state->closed){ec.clear();return;}m_state->closed=true;m_state->open=false;h=std::exchange(m_state->handle,-1);}if(h>=0){char e[64]{};(void)mt_udp_close(h,e,sizeof(e));}ec.clear();}
	void close(){mt_error_code ec;close(ec);}

private:std::shared_ptr<mt_udp_state> m_state;
};

} // namespace libtorrent::aux

#endif
