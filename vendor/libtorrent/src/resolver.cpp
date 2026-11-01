/*

Copyright (c) 2014-2017, 2019-2021, Arvid Norberg
Copyright (c) 2016-2018, 2020-2021, Alden Torres
All rights reserved.

You may use, distribute and modify this code under the terms of the BSD license,
see LICENSE file.
*/

#include "libtorrent/aux_/resolver.hpp"
#include "libtorrent/aux_/debug.hpp"
#include "libtorrent/aux_/time.hpp"

#if defined TORRENT_USE_MINTTORRENT_NETSTACK
#include "libtorrent/aux_/minttorrent_netstack.hpp"
#endif

namespace libtorrent::aux {

	resolver::resolver(io_context& ios)
		: m_ios(ios)
		, m_resolver(ios)
		, m_critical_resolver(ios)
		, m_max_size(700)
		, m_timeout(seconds(1200))
	{}

namespace {
	void callback(resolver_interface::callback_t h
		, error_code const& ec, std::vector<address> const& ips)
	{
		try {
			h(ec, ips);
		} catch (std::exception&) {
			TORRENT_ASSERT_FAIL();
		}
	}
}

	void resolver::on_lookup(error_code const& ec, std::vector<address> ips
		, std::string const& hostname)
	{
		COMPLETE_ASYNC("resolver::on_lookup");
		if (ec)
		{
			failed_dns_cache_entry& ce = m_failed_cache[hostname];
			ce.last_seen = time_now();
			ce.error = ec;

			// if the cache grows too big, weed out the
			// oldest entries
			if (int(m_failed_cache.size()) > m_max_size)
			{
				auto oldest = m_failed_cache.begin();
				for (auto k = m_failed_cache.begin(); k != m_failed_cache.end(); ++k)
				{
					if (k->second.last_seen < oldest->second.last_seen)
						oldest = k;
				}

				// remove the oldest entry
				m_failed_cache.erase(oldest);
			}

			auto const range = m_callbacks.equal_range(hostname);
			for (auto c = range.first; c != range.second; ++c)
				callback(std::move(c->second), ec, {});
			m_callbacks.erase(range.first, range.second);
			return;
		}

		{
			auto const k = m_failed_cache.find(hostname);
			if (k != m_failed_cache.end())
				m_failed_cache.erase(k);
		}

		dns_cache_entry& ce = m_cache[hostname];
		ce.last_seen = time_now();
		ce.addresses.clear();
		ce.addresses = std::move(ips);

		auto const range = m_callbacks.equal_range(hostname);
		for (auto c = range.first; c != range.second; ++c)
			callback(std::move(c->second), ec, ce.addresses);
		m_callbacks.erase(range.first, range.second);

		// if m_cache grows too big, weed out the
		// oldest entries
		if (int(m_cache.size()) > m_max_size)
		{
			auto oldest = m_cache.begin();
			for (auto k = m_cache.begin(); k != m_cache.end(); ++k)
			{
				if (k->second.last_seen < oldest->second.last_seen)
					oldest = k;
			}

			// remove the oldest entry
			m_cache.erase(oldest);
		}
	}

	void resolver::async_resolve(std::string const& host, resolver_flags const flags
		, resolver_interface::callback_t h)
	{
		// special handling for raw IP addresses. There's no need to get in line
		// behind actual lookups if we can just resolve it immediately.
		error_code ec;
		address const ip = make_address(host, ec);
		if (!ec)
		{
			post(m_ios, [h, ec, ip]{ callback(h, ec, std::vector<address>{ip}); });
			return;
		}
		ec.clear();

		auto const i = m_cache.find(host);
		if (i != m_cache.end())
		{
			// keep cache entries valid for m_timeout seconds
			if ((flags & resolver_interface::cache_only)
				|| i->second.last_seen + m_timeout >= time_now())
			{
				std::vector<address> ips = i->second.addresses;
				post(m_ios, [h, ec, ips] { callback(h, ec, ips); });
				return;
			}
		}

		auto const k = m_failed_cache.find(host);
		if (k != m_failed_cache.end())
		{
			// keep cache entries valid for m_timeout seconds
			// failures are cached for a shorter time to optimistically retry
			if ((flags & resolver_interface::cache_only)
				|| k->second.last_seen + m_timeout / 8 >= time_now())
			{
				error_code error_code = k->second.error;
				post(m_ios, [h, error_code] { callback(h, error_code, {}); });
				return;
			}
		}

		if (flags & resolver_interface::cache_only)
		{
			// we did not find a cache entry, fail the lookup
			post(m_ios, [h] {
				callback(h, boost::asio::error::host_not_found, std::vector<address>{});
			});
			return;
		}

		auto iter = m_callbacks.find(host);
		bool const done = (iter != m_callbacks.end());

		m_callbacks.insert(iter, {host, std::move(h)});

		// if there is an existing outtanding lookup, our callback will be
		// called once it completes. We're done here.
		if (done) return;

		// the port is ignored
		ADD_OUTSTANDING_ASYNC("resolver::on_lookup");
		#if defined TORRENT_USE_MINTTORRENT_NETSTACK
		char error[512]{};
		long long const stack = mt_default_stack(error);
		auto output = std::make_shared<std::array<char, 4096>>();
		auto const operation = register_mt_operation(m_ios.get_executor()
			, [this, output, host](long long, int const status)
		{
			std::vector<address> addresses;
			error_code ec;
			if (status == 0)
			{
				std::string_view list(output->data());
				while (!list.empty())
				{
					auto const comma = list.find(',');
					auto const item = list.substr(0, comma);
					auto const resolved_ip = make_address(std::string(item), ec);
					if (ec) break;
					addresses.push_back(resolved_ip);
					if (comma == std::string_view::npos) break;
					list.remove_prefix(comma + 1);
				}
				if (addresses.empty() && !ec) ec = boost::asio::error::host_not_found;
			}
			else
			{
				if (status == 3) ec = boost::asio::error::operation_aborted;
				else ec = boost::asio::error::host_not_found;
			}
			on_lookup(ec, std::move(addresses), host);
		});
		if (stack < 0)
		{
			complete_mt_operation(operation, 0, 2);
			return;
		}
		std::string hostname = host;
		if (mt_stack_async_resolve(stack, operation, hostname.data(), 10000
			, output->data(), output->size(), error, sizeof(error)) != 0)
			complete_mt_operation(operation, 0, 2);
		#else
		using namespace std::placeholders;
		if (flags & resolver_interface::abort_on_shutdown)
		{
			m_resolver.async_resolve(host, "80", [this, host](error_code const& ec, tcp::resolver::results_type ips) {
				std::vector<address> addresses;
				for (auto const& ip : ips) addresses.push_back(ip.endpoint().address());
				on_lookup(ec, std::move(addresses), host);
			});
		}
		else
		{
			m_critical_resolver.async_resolve(host, "80", [this, host](error_code const& ec, tcp::resolver::results_type ips) {
				std::vector<address> addresses;
				for (auto const& ip : ips) addresses.push_back(ip.endpoint().address());
				on_lookup(ec, std::move(addresses), host);
			});
		}
		#endif
	}

	void resolver::abort()
	{
		m_resolver.cancel();
	}

	void resolver::set_cache_timeout(seconds const timeout)
	{
		if (timeout >= seconds(0))
			m_timeout = timeout;
		else
			m_timeout = seconds(0);
	}
}
