/*
 * MintTorrent glue between Go netstack completion callbacks and libtorrent's
 * Boost.Asio executor. The callbacks are exported because the c-shared Go
 * library resolves them when the process loads both libraries.
 */

#include "libtorrent/config.hpp"
#include "libtorrent/aux_/minttorrent_netstack.hpp"
#include "libtorrent/version.hpp"

#include <unordered_map>

namespace libtorrent::aux {

namespace {
struct operation
{
	mt_executor executor;
	std::function<void(long long, int)> completion;
};

std::mutex operations_mutex;
std::unordered_map<std::uint64_t, operation> operations;
std::atomic<std::uint64_t> next_operation{1};
}

std::uint64_t register_mt_operation(mt_executor executor
	, std::function<void(long long, int)> completion)
{
	std::uint64_t const id = next_operation.fetch_add(1, std::memory_order_relaxed);
	std::lock_guard<std::mutex> lock(operations_mutex);
	operations.emplace(id, operation{std::move(executor), std::move(completion)});
	return id;
}

void complete_mt_operation(std::uint64_t const id, long long const value, int const error)
{
	operation op;
	{
		std::lock_guard<std::mutex> lock(operations_mutex);
		auto const i = operations.find(id);
		if (i == operations.end()) return;
		op = std::move(i->second);
		operations.erase(i);
	}
	boost::asio::post(op.executor, [completion = std::move(op.completion), value, error]() mutable
		{ completion(value, error); });
}

} // namespace libtorrent::aux

extern "C" TORRENT_EXPORT void minttorrent_tcp_connect_complete(
	unsigned long long const operation_id, long long const socket_id, int const error)
{
	libtorrent::aux::complete_mt_operation(operation_id, socket_id, error);
}

extern "C" TORRENT_EXPORT void minttorrent_tcp_accept_complete(
	unsigned long long const operation_id, long long const socket_id, int const error)
{
	libtorrent::aux::complete_mt_operation(operation_id, socket_id, error);
}

extern "C" TORRENT_EXPORT void minttorrent_tcp_read_complete(
	unsigned long long const operation_id, long long const bytes, int const error)
{
	libtorrent::aux::complete_mt_operation(operation_id, bytes, error);
}

extern "C" TORRENT_EXPORT void minttorrent_tcp_write_complete(
	unsigned long long const operation_id, long long const bytes, int const error)
{
	libtorrent::aux::complete_mt_operation(operation_id, bytes, error);
}

extern "C" TORRENT_EXPORT void minttorrent_udp_read_complete(
	unsigned long long const operation_id, long long const bytes, int const error)
{
	libtorrent::aux::complete_mt_operation(operation_id, bytes, error);
}

extern "C" TORRENT_EXPORT void minttorrent_dns_complete(
	unsigned long long const operation_id, long long const address_count, int const error)
{
	libtorrent::aux::complete_mt_operation(operation_id, address_count, error);
}

extern "C" TORRENT_EXPORT char const* minttorrent_libtorrent_version()
{
	return libtorrent::version();
}
