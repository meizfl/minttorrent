/*
 * MintTorrent C ABI for its libtorrent session and torrent manager.
 * This file is part of the GPL-3.0-or-later MintTorrent integration.
 */

#include "libtorrent/alert_types.hpp"
#include "libtorrent/session_stats.hpp"
#include "libtorrent/announce_entry.hpp"
#include "libtorrent/bencode.hpp"
#include "libtorrent/create_torrent.hpp"
#include "libtorrent/aux_/minttorrent_engine_api.h"
#include "libtorrent/aux_/socket_io.hpp"
#include "libtorrent/ip_filter.hpp"
#include "libtorrent/hex.hpp"
#include "libtorrent/fingerprint.hpp"
#include "libtorrent/load_torrent.hpp"
#include "libtorrent/magnet_uri.hpp"
#include "libtorrent/read_resume_data.hpp"
#include "libtorrent/session.hpp"
#include "libtorrent/torrent_status.hpp"
#include "libtorrent/version.hpp"
#include "libtorrent/write_resume_data.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <deque>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <string_view>
#include <stdexcept>
#include <sstream>
#include <utility>
#include <vector>
#include <thread>

namespace lt = libtorrent;

namespace {

struct engine
{
	std::unique_ptr<lt::session> session;
	std::string download_path;
	std::filesystem::path state_path;
	std::mutex mutex;
	struct peer_log_entry
	{
		std::int64_t id;
		std::int64_t timestamp;
		std::string ip;
		bool blocked;
		std::string reason;
	};
	std::mutex peer_log_mutex;
	std::deque<peer_log_entry> peer_log;
	int download_limit = 0;
	int upload_limit = 0;
	int alt_download_limit = 102400;
	int alt_upload_limit = 102400;
	bool alt_speed_limits = false;
	std::set<std::string> banned_peers;
};

std::atomic<std::int64_t> next_peer_log_id{0};

void append_peer_log(engine& state, lt::peer_alert const& alert, bool blocked, std::string reason)
{
	std::string ip;
	if (auto const* endpoint = std::get_if<lt::aux::noexcept_movable<lt::tcp::endpoint>>(&alert.ep))
		ip = endpoint->address().to_string();
	else
		ip = "I2P";
	std::lock_guard<std::mutex> lock(state.peer_log_mutex);
	state.peer_log.push_back({++next_peer_log_id,
		std::chrono::duration_cast<std::chrono::milliseconds>(
			std::chrono::system_clock::now().time_since_epoch()).count(),
		std::move(ip), blocked, std::move(reason)});
	while (state.peer_log.size() > 1000) state.peer_log.pop_front();
}

void set_error(char* output, int capacity, std::string const& message)
{
	if (output == nullptr || capacity <= 0) return;
	std::snprintf(output, static_cast<std::size_t>(capacity), "%s", message.c_str());
}

std::filesystem::path state_file(engine const& state, std::string const& hash, char const* extension)
{
	return state.state_path / (hash + extension);
}

std::string hash_string(lt::info_hash_t const& hashes)
{
	auto const raw = hashes.get_best().to_string();
	return lt::aux::to_hex({raw.data(), std::ptrdiff_t(raw.size())});
}

std::string path_utf8(std::filesystem::path const& path)
{
	auto const text = path.generic_u8string();
	return {reinterpret_cast<char const*>(text.data()), text.size()};
}

void write_state_file(std::filesystem::path const& path, char const* data, std::size_t size)
{
	auto temporary = path;
	temporary += ".tmp";
	{
		std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
		if (!output) throw std::runtime_error("cannot create torrent state file");
		output.write(data, static_cast<std::streamsize>(size));
		output.flush();
		if (!output) throw std::runtime_error("cannot write torrent state file");
	}
	std::error_code ec;
	std::filesystem::rename(temporary, path, ec);
	if (ec)
	{
		std::filesystem::remove(temporary);
		throw std::runtime_error("cannot atomically replace torrent state file: " + ec.message());
	}
	std::filesystem::permissions(path, std::filesystem::perms::owner_read | std::filesystem::perms::owner_write
		, std::filesystem::perm_options::replace, ec);
	if (ec) throw std::runtime_error("cannot restrict torrent state file permissions: " + ec.message());
}

void remove_state_file(std::filesystem::path const& path)
{
	std::error_code ec;
	std::filesystem::remove(path, ec);
	if (ec) throw std::runtime_error("cannot remove torrent state file: " + ec.message());
}

int load_torrent_options(engine const& state, std::string const& hash)
{
	std::ifstream input(state_file(state, hash, ".options"), std::ios::binary);
	if (!input) return 8; // auto-management is enabled by default
	int options = -1;
	if (!(input >> options) || options < 0 || options > 15)
		throw std::runtime_error("invalid saved torrent options");
	return options;
}

void persist_torrent_options(engine const& state, std::string const& hash, int options)
{
	auto const contents = std::to_string(options) + "\n";
	write_state_file(state_file(state, hash, ".options"), contents.data(), contents.size());
}

void persist_session_settings(engine const& state)
{
	std::string const contents = std::to_string(state.download_limit) + " "
		+ std::to_string(state.upload_limit) + " "
		+ std::to_string(state.alt_download_limit) + " "
		+ std::to_string(state.alt_upload_limit) + " "
		+ (state.alt_speed_limits ? "1\n" : "0\n");
	write_state_file(state.state_path / "session-settings", contents.data(), contents.size());
}

void load_session_settings(engine& state)
{
	std::ifstream input(state.state_path / "session-settings", std::ios::binary);
	if (!input) return;
	int mode = 0;
	if (!(input >> state.download_limit >> state.upload_limit >> state.alt_download_limit
		>> state.alt_upload_limit >> mode)
		|| state.download_limit < 0 || state.upload_limit < 0
		|| state.alt_download_limit < 0 || state.alt_upload_limit < 0
		|| (mode != 0 && mode != 1))
		throw std::runtime_error("invalid saved session speed limits");
	state.alt_speed_limits = mode != 0;
}

void load_banned_peers(engine& state)
{
	std::ifstream input(state.state_path / "banned-peers", std::ios::binary);
	if (!input) return;
	lt::ip_filter filter;
	std::string line;
	while (std::getline(input, line))
	{
		if (line.empty()) continue;
		lt::error_code ec;
		auto const address = lt::make_address(line, ec);
		if (ec || address.to_string() != line) throw std::runtime_error("invalid saved banned peer address");
		state.banned_peers.insert(line);
		filter.add_rule(address, address, lt::ip_filter::blocked);
	}
	if (!input.eof()) throw std::runtime_error("cannot read saved banned peer addresses");
	if (!state.banned_peers.empty()) state.session->set_ip_filter(std::move(filter));
}

void persist_banned_peers(engine const& state, std::set<std::string> const& addresses)
{
	std::string contents;
	for (auto const& address : addresses) contents += address + "\n";
	write_state_file(state.state_path / "banned-peers", contents.data(), contents.size());
}

void apply_session_rate_limits(engine& state)
{
	lt::settings_pack settings;
	settings.set_int(lt::settings_pack::download_rate_limit
		, state.alt_speed_limits ? state.alt_download_limit : state.download_limit);
	settings.set_int(lt::settings_pack::upload_rate_limit
		, state.alt_speed_limits ? state.alt_upload_limit : state.upload_limit);
	state.session->apply_settings(std::move(settings));
}

void configure_add_params(engine const& state, lt::add_torrent_params& params, std::string const& hash)
{
	params.save_path = state.download_path;
	std::ifstream saved_path(state_file(state, hash, ".savepath"), std::ios::binary);
	if (saved_path) {
		std::string path((std::istreambuf_iterator<char>(saved_path)), std::istreambuf_iterator<char>());
		if (!path.empty() && path.back() == '\n') path.pop_back();
		if (!path.empty()) params.save_path = std::move(path);
	}
	params.storage_mode = lt::storage_mode_sparse;
	std::ifstream saved_priorities(state_file(state, hash, ".priorities"), std::ios::binary);
	if (saved_priorities)
	{
		std::string line;
		std::getline(saved_priorities, line);
		std::istringstream values(line);
		std::string value;
		while (std::getline(values, value, ','))
		{
			size_t consumed = 0;
			int const priority = std::stoi(value, &consumed);
			if (consumed != value.size() || priority < 0 || priority > 7)
				throw std::runtime_error("invalid saved file priority");
			params.file_priorities.emplace_back(lt::download_priority_t{static_cast<unsigned char>(priority)});
		}
	}
	auto const options = load_torrent_options(state, hash);
	params.flags &= ~(lt::torrent_flags::paused | lt::torrent_flags::sequential_download
		| lt::torrent_flags::super_seeding | lt::torrent_flags::auto_managed);
	if ((options & 1) != 0) params.flags |= lt::torrent_flags::sequential_download;
	if ((options & 4) != 0) params.flags |= lt::torrent_flags::super_seeding;
	if ((options & 8) != 0) params.flags |= lt::torrent_flags::auto_managed;
	if ((options & 2) != 0 && params.ti)
	{
		params.piece_priorities.assign(std::size_t(params.ti->num_pieces()), lt::default_priority);
		if (!params.piece_priorities.empty())
		{
			params.piece_priorities.front() = lt::top_priority;
			params.piece_priorities.back() = lt::top_priority;
		}
	}
	if (std::filesystem::exists(state_file(state, hash, ".paused")))
	{
		params.flags &= ~lt::torrent_flags::auto_managed;
		params.flags |= lt::torrent_flags::paused;
	}
	auto const saved_trackers = state_file(state, hash, ".trackers");
	if (std::filesystem::exists(saved_trackers))
	{
		params.trackers.clear();
		params.tracker_tiers.clear();
		std::ifstream input(saved_trackers, std::ios::binary);
		std::string line;
		while (std::getline(input, line))	{
			auto const separator = line.find('\t');
			if (separator == std::string::npos) throw std::runtime_error("invalid saved tracker list");
			std::size_t consumed = 0;
			int const tier = std::stoi(line.substr(0, separator), &consumed);
			std::string const url = line.substr(separator + 1);
			if (consumed != separator || tier < 0 || tier > 255 || url.empty())
				throw std::runtime_error("invalid saved tracker entry");
			params.trackers.push_back(url);
			params.tracker_tiers.push_back(tier);
		}
		if (!input.eof()) throw std::runtime_error("cannot read saved tracker list");
		params.flags |= lt::torrent_flags::deprecated_override_trackers;
	}
	auto const saved_webseeds = state_file(state, hash, ".webseeds");
	if (std::filesystem::exists(saved_webseeds))
	{
		params.url_seeds.clear();
		std::ifstream input(saved_webseeds, std::ios::binary);
		std::string line;
		while (std::getline(input, line))
		{
			if (line.empty() || line.find_first_of("\r\n") != std::string::npos || line.find('\0') != std::string::npos)
				throw std::runtime_error("invalid saved web seed list");
			params.url_seeds.push_back(line);
		}
		if (!input.eof()) throw std::runtime_error("cannot read saved web seed list");
		params.flags |= lt::torrent_flags::deprecated_override_web_seeds;
	}
}

void persist_trackers(engine const& state, std::string const& hash, std::vector<lt::announce_entry> const& trackers)
{
	std::string contents;
	for (auto const& tracker : trackers)
		contents += std::to_string(tracker.tier) + "\t" + tracker.url + "\n";
	write_state_file(state_file(state, hash, ".trackers"), contents.data(), contents.size());
}

std::vector<std::string> split_values(std::string const& values)
{
	std::vector<std::string> result;
	std::size_t start = 0;
	while (start <= values.size())
	{
		auto const end = values.find('|', start);
		auto const item = values.substr(start, end == std::string::npos ? std::string::npos : end - start);
		if (!item.empty()) result.push_back(item);
		if (end == std::string::npos) break;
		start = end + 1;
	}
	return result;
}

void restore_torrents(engine& state)
{
	std::filesystem::create_directories(state.state_path);
	for (auto const& entry : std::filesystem::directory_iterator(state.state_path))
	{
		if (!entry.is_regular_file()) continue;
		auto const extension = entry.path().extension().string();
		lt::error_code ec;
		if (extension == ".magnet")
		{
			std::ifstream input(entry.path(), std::ios::binary);
			std::string magnet((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
			auto params = lt::parse_magnet_uri(magnet, ec);
			if (ec) throw std::runtime_error("invalid saved magnet " + entry.path().filename().string() + ": " + ec.message());
			auto const hash = hash_string(params.info_hashes);
			auto const resume_file = state_file(state, hash, ".resume");
			if (std::filesystem::exists(resume_file))
			{
				std::ifstream resume_input(resume_file, std::ios::binary);
				std::vector<char> resume_buffer((std::istreambuf_iterator<char>(resume_input)), std::istreambuf_iterator<char>());
				lt::error_code resume_error;
				auto resumed = lt::read_resume_data(lt::span<char const>{resume_buffer.data(), std::ptrdiff_t(resume_buffer.size())}, resume_error, lt::load_torrent_limits{});
				if (!resume_error && hash_string(resumed.info_hashes) == hash) params = std::move(resumed);
				else std::fprintf(stderr, "MintTorrent resume data ignored for %s: %s\n", hash.c_str(), resume_error ? resume_error.message().c_str() : "info-hash mismatch");
			}
			configure_add_params(state, params, hash);
			state.session->async_add_torrent(std::move(params));
		}
		else if (extension == ".torrent")
		{
			std::ifstream input(entry.path(), std::ios::binary);
			std::vector<char> buffer((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
			auto params = lt::load_torrent_buffer(lt::span<char const>{buffer.data(), std::ptrdiff_t(buffer.size())}, ec, lt::load_torrent_limits{});
			if (ec) throw std::runtime_error("invalid saved torrent " + entry.path().filename().string() + ": " + ec.message());
			auto const hash = hash_string(params.ti->info_hashes());
			auto const resume_file = state_file(state, hash, ".resume");
			if (std::filesystem::exists(resume_file))
			{
				std::ifstream resume_input(resume_file, std::ios::binary);
				std::vector<char> resume_buffer((std::istreambuf_iterator<char>(resume_input)), std::istreambuf_iterator<char>());
				lt::error_code resume_error;
				auto resumed = lt::read_resume_data(lt::span<char const>{resume_buffer.data(), std::ptrdiff_t(resume_buffer.size())}, resume_error, lt::load_torrent_limits{});
				if (!resume_error && hash_string(resumed.info_hashes) == hash) params = std::move(resumed);
				else std::fprintf(stderr, "MintTorrent resume data ignored for %s: %s\n", hash.c_str(), resume_error ? resume_error.message().c_str() : "info-hash mismatch");
			}
			configure_add_params(state, params, hash);
			state.session->async_add_torrent(std::move(params));
		}
	}
}

void save_resume_data(engine& state)
{
	std::lock_guard<std::mutex> lock(state.mutex);
	for (auto const& handle : state.session->get_torrents())
	{
		if (!handle.is_valid() || !handle.torrent_file()) continue;
		auto const hash = hash_string(handle.info_hashes());
		try
		{
			auto params = handle.get_resume_data(lt::torrent_handle::save_info_dict | lt::torrent_handle::if_download_progress);
			auto const buffer = lt::write_resume_data_buf(params);
			write_state_file(state_file(state, hash, ".resume"), buffer.data(), buffer.size());
		}
		catch (std::exception const& error)
		{
			throw std::runtime_error("cannot save resume data for " + hash + ": " + error.what());
		}
	}
}

void remove_persisted_torrent(engine const& state, std::string const& hash)
{
	remove_state_file(state_file(state, hash, ".magnet"));
	remove_state_file(state_file(state, hash, ".torrent"));
	remove_state_file(state_file(state, hash, ".paused"));
	remove_state_file(state_file(state, hash, ".savepath"));
	remove_state_file(state_file(state, hash, ".priorities"));
	remove_state_file(state_file(state, hash, ".trackers"));
	remove_state_file(state_file(state, hash, ".options"));
	remove_state_file(state_file(state, hash, ".force-start"));
	remove_state_file(state_file(state, hash, ".webseeds"));
	remove_state_file(state_file(state, hash, ".resume"));
}

std::string json_escape(std::string_view input)
{
	std::string output;
	output.reserve(input.size() + 8);
	for (std::size_t i = 0; i < input.size();)
	{
		unsigned char const c = static_cast<unsigned char>(input[i]);
		switch (c)
		{
			case '"': output += "\\\""; ++i; continue;
			case '\\': output += "\\\\"; ++i; continue;
			case '\b': output += "\\b"; ++i; continue;
			case '\f': output += "\\f"; ++i; continue;
			case '\n': output += "\\n"; ++i; continue;
			case '\r': output += "\\r"; ++i; continue;
			case '\t': output += "\\t"; ++i; continue;
			default:
				if (c < 0x20)
				{
					char escaped[7]{};
					std::snprintf(escaped, sizeof(escaped), "\\u%04x", c);
					output += escaped;
					++i;
					continue;
				}
				if (c < 0x80)
				{
					output += static_cast<char>(c);
					++i;
					continue;
				}
		}
		std::size_t length = 0;
		unsigned char const second_min = 0x80;
		unsigned char second_max = 0xbf;
		if (c >= 0xc2 && c <= 0xdf) length = 2;
		else if (c >= 0xe0 && c <= 0xef) length = 3;
		else if (c >= 0xf0 && c <= 0xf4) length = 4;
		if (length > 0 && i + length <= input.size())
		{
			unsigned char const second = static_cast<unsigned char>(input[i + 1]);
			if (c == 0xe0) { if (second < 0xa0) length = 0; }
			else if (c == 0xed) { if (second > 0x9f) length = 0; }
			else if (c == 0xf0) { if (second < 0x90) length = 0; }
			else if (c == 0xf4) { if (second > 0x8f) length = 0; }
			else if (second < second_min || second > second_max) length = 0;
			for (std::size_t j = 2; length != 0 && j < (c < 0xe0 ? 2 : length); ++j)
			{
				auto const continuation = static_cast<unsigned char>(input[i + j]);
				if (continuation < 0x80 || continuation > 0xbf) length = 0;
			}
		}
		else length = 0;
		if (length == 0)
		{
			output += "\\ufffd";
			++i;
		}
		else
		{
			output.append(input.data() + i, length);
			i += length;
		}
	}
	return output;
}

char const* state_name(lt::torrent_status const& status)
{
	if (status.flags & lt::torrent_flags::paused)
		return status.is_seeding ? "stoppedUP" : "stoppedDL";
	switch (status.state)
	{
		case lt::torrent_status::checking_files:
		case lt::torrent_status::checking_resume_data: return "checkingDL";
		case lt::torrent_status::downloading_metadata: return "metaDL";
		case lt::torrent_status::downloading: return status.download_rate > 0 ? "downloading" : "stalledDL";
		case lt::torrent_status::finished: return "stalledUP";
		case lt::torrent_status::seeding: return status.upload_rate > 0 ? "uploading" : "stalledUP";
	}
	return "stalledDL";
}

} // anonymous namespace

extern "C" {

void* mt_engine_create(char const* download_path, char const* listen_interfaces, char* error, int error_capacity)
{
	try
	{
		if (download_path == nullptr || download_path[0] == '\0' || listen_interfaces == nullptr || listen_interfaces[0] == '\0')
			throw std::runtime_error("download directory and VPN listen interfaces are required");
		auto result = std::make_unique<engine>();
		result->download_path = download_path;
		result->state_path = std::filesystem::u8path(download_path) / ".minttorrent-state";
		std::filesystem::create_directories(result->state_path);
		std::filesystem::permissions(result->state_path, std::filesystem::perms::owner_all, std::filesystem::perm_options::replace);
		load_session_settings(*result);
		lt::settings_pack settings;
		settings.set_str(lt::settings_pack::user_agent, "MintTorrent/0.1.0 libtorrent/2.1.2");
		// Match qBittorrent's BitTorrent peer ID prefix as well as its HTTP and
		// extension-handshake identity. This is the session used for real peers.
		auto const peer_fingerprint = lt::generate_fingerprint("qB", 5, 3, 0);
		settings.set_str(lt::settings_pack::peer_fingerprint, peer_fingerprint);
		settings.set_str(lt::settings_pack::listen_interfaces, listen_interfaces);
		settings.set_bool(lt::settings_pack::enable_dht, true);
		settings.set_bool(lt::settings_pack::enable_lsd, false);
		settings.set_bool(lt::settings_pack::enable_upnp, false);
		settings.set_bool(lt::settings_pack::enable_natpmp, false);
		settings.set_int(lt::settings_pack::proxy_type, lt::settings_pack::none);
		// Peer lifecycle alerts are needed to diagnose short-lived swarm
		// connections. libtorrent's default mask only enables error alerts.
		settings.set_int(lt::settings_pack::alert_mask,
			lt::alert_category::error | lt::alert_category::connect | lt::alert_category::ip_block);
		settings.set_bool(lt::settings_pack::enable_incoming_tcp, true);
		result->session = std::make_unique<lt::session>(std::move(settings));
		if (result->session->get_peer_id().to_string().compare(0, peer_fingerprint.size(), peer_fingerprint) != 0)
			throw std::runtime_error("libtorrent session did not apply the configured qBittorrent peer ID fingerprint");
		apply_session_rate_limits(*result);
		load_banned_peers(*result);
		restore_torrents(*result);
		return result.release();
	}
	catch (std::exception const& e)
	{
		set_error(error, error_capacity, e.what());
		return nullptr;
	}
}

int mt_engine_set_speed_limits(void* value, int download_limit, int upload_limit, char* error, int error_capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr || download_limit < 0 || upload_limit < 0)
			throw std::runtime_error("speed limits must be non-negative");
		std::lock_guard<std::mutex> lock(state->mutex);
		auto const old_download = state->download_limit;
		auto const old_upload = state->upload_limit;
		state->download_limit = download_limit;
		state->upload_limit = upload_limit;
		try { persist_session_settings(*state); }
		catch (...) { state->download_limit = old_download; state->upload_limit = old_upload; throw; }
		if (!state->alt_speed_limits) apply_session_rate_limits(*state);
		return 0;
	}
	catch (std::exception const& e) { set_error(error, error_capacity, e.what()); return -1; }
}

int mt_engine_set_alt_speed_limits(void* value, int download_limit, int upload_limit, char* error, int error_capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr || download_limit < 0 || upload_limit < 0)
			throw std::runtime_error("alternative speed limits must be non-negative");
		std::lock_guard<std::mutex> lock(state->mutex);
		auto const old_download = state->alt_download_limit;
		auto const old_upload = state->alt_upload_limit;
		state->alt_download_limit = download_limit;
		state->alt_upload_limit = upload_limit;
		try { persist_session_settings(*state); }
		catch (...) { state->alt_download_limit = old_download; state->alt_upload_limit = old_upload; throw; }
		if (state->alt_speed_limits) apply_session_rate_limits(*state);
		return 0;
	}
	catch (std::exception const& e) { set_error(error, error_capacity, e.what()); return -1; }
}

int mt_engine_toggle_alt_speed_limits(void* value, char* error, int error_capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr) throw std::runtime_error("invalid engine");
		std::lock_guard<std::mutex> lock(state->mutex);
		state->alt_speed_limits = !state->alt_speed_limits;
		try { persist_session_settings(*state); }
		catch (...) { state->alt_speed_limits = !state->alt_speed_limits; throw; }
		apply_session_rate_limits(*state);
		return 0;
	}
	catch (std::exception const& e) { set_error(error, error_capacity, e.what()); return -1; }
}

int mt_engine_speed_limits_json(void* value, char* output, int capacity, char* error, int error_capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr) throw std::runtime_error("invalid engine");
		std::lock_guard<std::mutex> lock(state->mutex);
		int const download = state->alt_speed_limits ? state->alt_download_limit : state->download_limit;
		int const upload = state->alt_speed_limits ? state->alt_upload_limit : state->upload_limit;
		std::string const json = "{\"dl_speed_limit\":" + std::to_string(download)
			+ ",\"up_speed_limit\":" + std::to_string(upload)
			+ ",\"use_alt_speed_limits\":" + std::string(state->alt_speed_limits ? "true" : "false") + "}";
		if (output == nullptr || capacity <= 0) return static_cast<int>(json.size());
		if (json.size() + 1 > static_cast<std::size_t>(capacity)) return -static_cast<int>(json.size()) - 1;
		std::memcpy(output, json.c_str(), json.size() + 1);
		return static_cast<int>(json.size());
	}
	catch (std::exception const& e) { set_error(error, error_capacity, e.what()); return -1; }
}

int mt_engine_set_session_paused(void* value, int paused, char* error, int error_capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr) throw std::runtime_error("invalid engine");
		std::lock_guard<std::mutex> lock(state->mutex);
		if (paused != 0) state->session->pause();
		else state->session->resume();
		return 0;
	}
	catch (std::exception const& e) { set_error(error, error_capacity, e.what()); return -1; }
}

int mt_engine_update_trackers(void* value, char const* hashes, int action, char const* urls
	, char const* new_url, int tier, char* error, int error_capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr || hashes == nullptr || urls == nullptr)
			throw std::runtime_error("invalid engine or tracker parameters");
		if (action < 0 || action > 2) throw std::runtime_error("unknown tracker operation");
		if (action == 2 && (new_url == nullptr || new_url[0] == '\0' || tier < 0 || tier > 255))
			throw std::runtime_error("invalid replacement tracker or tier");
		auto const url_values = split_values(urls);
		if (url_values.empty()) throw std::runtime_error("tracker URL list is empty");
		std::lock_guard<std::mutex> lock(state->mutex);
		auto const torrents = state->session->get_torrents();
		std::vector<std::pair<std::string, lt::torrent_handle>> selected;
		std::string const hash_list(hashes);
		if (hash_list == "*")
		{
			for (auto const& handle : torrents) selected.emplace_back(hash_string(handle.info_hashes()), handle);
		}
		else
		{
			for (auto const& hash : split_values(hash_list))
			{
				auto const found = std::find_if(torrents.begin(), torrents.end(), [&](lt::torrent_handle const& handle)
					{ return hash_string(handle.info_hashes()) == hash; });
				if (found == torrents.end()) throw std::runtime_error("torrent hash was not found: " + hash);
				if (std::none_of(selected.begin(), selected.end(), [&](auto const& entry) { return entry.first == hash; }))
					selected.emplace_back(hash, *found);
			}
		}
		if (selected.empty()) throw std::runtime_error("no torrents selected");
		for (auto const& [hash, handle] : selected)
		{
			auto trackers = handle.trackers();
			if (action == 0)
			{
				for (auto const& url : url_values)
				{
					if (std::any_of(trackers.begin(), trackers.end(), [&](lt::announce_entry const& item) { return item.url == url; })) continue;
					lt::announce_entry item(url);
					item.tier = 0;
					trackers.push_back(std::move(item));
				}
			}
			else if (action == 1)
			{
				trackers.erase(std::remove_if(trackers.begin(), trackers.end(), [&](lt::announce_entry const& item)
					{ return std::find(url_values.begin(), url_values.end(), item.url) != url_values.end(); }), trackers.end());
			}
			else
			{
				bool edited = false;
				for (auto& item : trackers)
				{
					if (item.url != url_values.front()) continue;
					item.url = new_url;
					item.tier = static_cast<std::uint8_t>(tier);
					edited = true;
					break;
				}
				if (!edited) throw std::runtime_error("tracker URL was not found");
			}
			handle.replace_trackers(trackers);
			persist_trackers(*state, hash, trackers);
			handle.force_reannounce();
		}
		return 0;
	}
	catch (std::exception const& e) { set_error(error, error_capacity, e.what()); return -1; }
}

void mt_engine_destroy(void* value)
{
	auto* state = static_cast<engine*>(value);
	if (state == nullptr) return;
	try { save_resume_data(*state); }
	catch (std::exception const& error) { std::fprintf(stderr, "MintTorrent shutdown resume save failed: %s\n", error.what()); }
	delete state;
}

int mt_engine_save_resume_data(void* value, char* error, int error_capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr) throw std::runtime_error("invalid engine");
		save_resume_data(*state);
		return 0;
	}
	catch (std::exception const& e) { set_error(error, error_capacity, e.what()); return -1; }
}

int mt_engine_add_magnet(void* value, char const* magnet, char* error, int error_capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr || magnet == nullptr) throw std::runtime_error("invalid engine or magnet");
		lt::error_code ec;
		auto params = lt::parse_magnet_uri(magnet, ec);
		if (ec) throw std::runtime_error(ec.message());
		auto const hash = hash_string(params.info_hashes);
		configure_add_params(*state, params, hash);
		std::lock_guard<std::mutex> lock(state->mutex);
		write_state_file(state_file(*state, hash, ".magnet"), magnet, std::strlen(magnet));
		state->session->async_add_torrent(std::move(params));
		return 0;
	}
	catch (std::exception const& e)
	{
		set_error(error, error_capacity, e.what());
		return -1;
	}
}

int mt_engine_add_magnet_with_options(void* value, char const* magnet, char const* save_path, int paused, char* error, int error_capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr || magnet == nullptr) throw std::runtime_error("invalid engine or magnet");
		lt::error_code ec;
		auto params = lt::parse_magnet_uri(magnet, ec);
		if (ec) throw std::runtime_error(ec.message());
		auto const hash = hash_string(params.info_hashes);
		configure_add_params(*state, params, hash);
		if (save_path != nullptr && save_path[0] != '\0') {
			params.save_path = save_path;
			std::filesystem::create_directories(std::filesystem::u8path(params.save_path));
		}
		else params.save_path = state->download_path;
		if (paused != 0) {
			params.flags &= ~lt::torrent_flags::auto_managed;
			params.flags |= lt::torrent_flags::paused;
		}
		std::lock_guard<std::mutex> lock(state->mutex);
		write_state_file(state_file(*state, hash, ".magnet"), magnet, std::strlen(magnet));
		if (save_path != nullptr && save_path[0] != '\0') {
			write_state_file(state_file(*state, hash, ".savepath"), save_path, std::strlen(save_path));
		}
		else remove_state_file(state_file(*state, hash, ".savepath"));
		if (paused != 0) write_state_file(state_file(*state, hash, ".paused"), "1", 1);
		else remove_state_file(state_file(*state, hash, ".paused"));
		state->session->async_add_torrent(std::move(params));
		return 0;
	}
	catch (std::exception const& e)
	{
		set_error(error, error_capacity, e.what());
		return -1;
	}
}

int mt_engine_add_torrent_buffer(void* value, char const* buffer, int size, char* error, int error_capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr || buffer == nullptr || size <= 0 || size > 16 * 1024 * 1024)
			throw std::runtime_error("invalid torrent file or file exceeds 16 MiB limit");
		lt::error_code ec;
		auto params = lt::load_torrent_buffer(lt::span<char const>{buffer, std::ptrdiff_t(size)}
			, ec, lt::load_torrent_limits{});
		if (ec) throw std::runtime_error(ec.message());
		auto const hash = hash_string(params.ti->info_hashes());
		configure_add_params(*state, params, hash);
		std::lock_guard<std::mutex> lock(state->mutex);
		write_state_file(state_file(*state, hash, ".torrent"), buffer, static_cast<std::size_t>(size));
		state->session->async_add_torrent(std::move(params));
		return 0;
	}
	catch (std::exception const& e)
	{
		set_error(error, error_capacity, e.what());
		return -1;
	}
}

int mt_engine_add_torrent_buffer_at(void* value, char const* buffer, int size,
	char const* save_path, int paused, char* error, int error_capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr || buffer == nullptr || size <= 0 || size > 16 * 1024 * 1024 || save_path == nullptr)
			throw std::runtime_error("invalid torrent data or save path");
		lt::error_code ec;
		auto params = lt::load_torrent_buffer(lt::span<char const>{buffer, std::ptrdiff_t(size)}
			, ec, lt::load_torrent_limits{});
		if (ec) throw std::runtime_error(ec.message());
		auto const hash = hash_string(params.ti->info_hashes());
		configure_add_params(*state, params, hash);
		params.save_path = save_path;
		if (paused != 0)
		{
			params.flags &= ~lt::torrent_flags::auto_managed;
			params.flags |= lt::torrent_flags::paused;
		}
		else
		{
			params.flags &= ~lt::torrent_flags::paused;
			params.flags |= lt::torrent_flags::auto_managed;
		}
		std::lock_guard<std::mutex> lock(state->mutex);
		write_state_file(state_file(*state, hash, ".torrent"), buffer, static_cast<std::size_t>(size));
		write_state_file(state_file(*state, hash, ".savepath"), save_path, std::strlen(save_path));
		if (paused != 0) write_state_file(state_file(*state, hash, ".paused"), "1", 1);
		else remove_state_file(state_file(*state, hash, ".paused"));
		state->session->async_add_torrent(std::move(params));
		return 0;
	}
	catch (std::exception const& e)
	{
		set_error(error, error_capacity, e.what());
		return -1;
	}
}

int mt_parse_torrent_metadata(char const* buffer, int size, char* output, int capacity, char* error, int error_capacity)
{
	try
	{
		if (buffer == nullptr || size <= 0 || size > 16 * 1024 * 1024)
			throw std::runtime_error("invalid torrent file or file exceeds 16 MiB limit");
		lt::error_code ec;
		auto params = lt::load_torrent_buffer(lt::span<char const>{buffer, std::ptrdiff_t(size)}, ec, lt::load_torrent_limits{});
		if (ec) throw std::runtime_error(ec.message());
		if (!params.ti) throw std::runtime_error("torrent metadata is missing");
		auto const& info = *params.ti;
		auto const hashes = info.info_hashes();
		auto const raw_v1 = hashes.has_v1() ? hashes.v1.to_string() : std::string{};
		auto const raw_v2 = hashes.has_v2() ? hashes.v2.to_string() : std::string{};
		std::string const v1 = lt::aux::to_hex({raw_v1.data(), std::ptrdiff_t(raw_v1.size())});
		std::string const v2 = lt::aux::to_hex({raw_v2.data(), std::ptrdiff_t(raw_v2.size())});
		auto const& storage = info.layout();
		std::string json = "{\"infohash_v1\":\"" + v1 + "\",\"infohash_v2\":\"" + v2
			+ "\",\"creation_date\":" + std::to_string(params.creation_date)
			+ ",\"comment\":\"" + json_escape(params.comment) + "\",\"info\":{\"name\":\""
			+ json_escape(info.name()) + "\",\"piece_length\":" + std::to_string(info.piece_length())
			+ ",\"length\":" + std::to_string(info.total_size());
		if (storage.num_files() > 1)
		{
			json += ",\"files\":[";
			for (int i = 0; i < storage.num_files(); ++i)
			{
				if (i != 0) json += ',';
				json += "{\"path\":\"" + json_escape(storage.file_path(lt::file_index_t{i}))
					+ "\",\"length\":" + std::to_string(storage.file_size(lt::file_index_t{i})) + "}";
			}
			json += ']';
		}
		json += "}}";
		if (output == nullptr || capacity <= 0) return static_cast<int>(json.size());
		if (json.size() + 1 > static_cast<std::size_t>(capacity)) return -static_cast<int>(json.size()) - 1;
		std::memcpy(output, json.c_str(), json.size() + 1);
		return static_cast<int>(json.size());
	}
	catch (std::exception const& e)
	{
		set_error(error, error_capacity, e.what());
		return -1;
	}
}

int mt_parse_magnet_hash(char const* magnet, char* output, int capacity, char* error, int error_capacity)
{
	try
	{
		if (magnet == nullptr) throw std::runtime_error("magnet link is missing");
		lt::error_code ec;
		auto const params = lt::parse_magnet_uri(magnet, ec);
		if (ec) throw std::runtime_error(ec.message());
		auto const hash = hash_string(params.info_hashes);
		if (output == nullptr || capacity <= 0) return static_cast<int>(hash.size());
		if (hash.size() + 1 > static_cast<std::size_t>(capacity)) return -static_cast<int>(hash.size()) - 1;
		std::memcpy(output, hash.c_str(), hash.size() + 1);
		return static_cast<int>(hash.size());
	}
	catch (std::exception const& e)
	{
		set_error(error, error_capacity, e.what());
		return -1;
	}
}

int mt_create_torrent_file(char const* source_path, char const* output_path,
	char const* format, int piece_size, int ignore_dotfiles, int is_private,
	char const* trackers, char const* url_seeds, char const* comment, char const* source,
	mt_torrent_create_progress_callback progress_callback, void* progress_context,
	char* error, int error_capacity)
{
	try
	{
		if (source_path == nullptr || output_path == nullptr || format == nullptr
			|| trackers == nullptr || url_seeds == nullptr || comment == nullptr || source == nullptr)
			throw std::runtime_error("torrent creation parameters are incomplete");
		if (piece_size != 0 && (piece_size < 16 * 1024 || piece_size > 128 * 1024 * 1024
			|| (piece_size & (piece_size - 1)) != 0))
			throw std::runtime_error("piece size must be Auto or a power of two from 16 KiB to 128 MiB");
		lt::create_flags_t flags;
		if (std::strcmp(format, "v1") == 0) flags |= lt::create_torrent::v1_only;
		else if (std::strcmp(format, "v2") == 0) flags |= lt::create_torrent::v2_only;
		else if (std::strcmp(format, "hybrid") != 0) throw std::runtime_error("torrent format must be v1, v2, or hybrid");

		auto const input = std::filesystem::canonical(std::filesystem::u8path(source_path));
		if (!std::filesystem::is_regular_file(input) && !std::filesystem::is_directory(input))
			throw std::runtime_error("source path must be a file or directory");
		auto files = lt::list_files(path_utf8(input), [ignore_dotfiles](std::string path) {
			if (!ignore_dotfiles) return true;
			for (auto const& component : std::filesystem::u8path(path))
			{
				auto const name = path_utf8(component);
				if (!name.empty() && name.front() == '.') return false;
			}
			return true;
		}, flags);
		if (files.empty()) throw std::runtime_error("source contains no files after filtering");
		lt::create_torrent torrent(std::move(files), piece_size, flags);
		torrent.set_priv(is_private != 0);
		torrent.set_comment(comment);
		torrent.set_creator("MintTorrent/0.1.0");
		auto add_urls = [](lt::create_torrent& target, char const* urls, bool tracker) {
			std::string_view const all(urls);
			std::size_t offset = 0;
			while (offset <= all.size())
			{
				auto const end = all.find('|', offset);
				auto const length = (end == std::string_view::npos ? all.size() : end) - offset;
				auto const value = all.substr(offset, length);
				if (!value.empty())
				{
					if (tracker) target.add_tracker(value, 0);
					else target.add_url_seed(value);
				}
				if (end == std::string_view::npos) break;
				offset = end + 1;
			}
		};
		add_urls(torrent, trackers, true);
		add_urls(torrent, url_seeds, false);
		auto const pieces = std::max(1, torrent.num_pieces());
		lt::set_piece_hashes(torrent, path_utf8(input.parent_path()), [=](lt::piece_index_t piece) {
			int const done = std::min(99, (int(piece) + 1) * 100 / pieces);
			if (progress_callback != nullptr && progress_callback(progress_context, done) == 0)
				throw std::runtime_error("torrent creation cancelled");
		});
		if (progress_callback != nullptr && progress_callback(progress_context, 100) == 0)
			throw std::runtime_error("torrent creation cancelled");
		auto metadata = torrent.generate();
		if (source[0] != '\0') metadata["info"]["source"] = source;
		auto const bytes = lt::bencode(metadata);
		auto const target = std::filesystem::u8path(output_path);
		std::filesystem::create_directories(target.parent_path());
		std::ofstream output(target, std::ios::binary | std::ios::trunc);
		if (!output) throw std::runtime_error("cannot create generated torrent file");
		output.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
		output.flush();
		if (!output) throw std::runtime_error("cannot write generated torrent file");
		return 0;
	}
	catch (std::exception const& e)
	{
		set_error(error, error_capacity, e.what());
		return -1;
	}
}

int mt_engine_export_torrent(void* value, char const* hash, char* output, int capacity, char* error, int error_capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr || hash == nullptr) throw std::runtime_error("invalid engine or torrent hash");
		std::vector<lt::torrent_handle> torrents;
		{
			std::lock_guard<std::mutex> lock(state->mutex);
			torrents = state->session->get_torrents();
		}
		auto const found = std::find_if(torrents.begin(), torrents.end(), [&](lt::torrent_handle const& handle)
			{ return hash_string(handle.info_hashes()) == hash; });
		if (found == torrents.end()) throw std::runtime_error("torrent hash was not found");
		auto const info = found->torrent_file();
		if (!info) throw std::runtime_error("torrent metadata is not available yet");
		lt::add_torrent_params params;
		params.ti = info;
		auto const status = found->status(lt::torrent_handle::query_renamed_files);
		params.renamed_files = status.renamed_files.export_filenames(info->layout());
		for (auto const& tracker : found->trackers())
		{
			params.trackers.push_back(tracker.url);
			params.tracker_tiers.push_back(tracker.tier);
		}
		auto const buffer = lt::write_torrent_file_buf(params, {});
		if (buffer.empty()) throw std::runtime_error("libtorrent produced an empty torrent file");
		if (output == nullptr || capacity <= 0) return static_cast<int>(buffer.size());
		if (buffer.size() + 1 > static_cast<std::size_t>(capacity)) return -static_cast<int>(buffer.size()) - 1;
		std::memcpy(output, buffer.data(), buffer.size());
		output[buffer.size()] = '\0';
		return static_cast<int>(buffer.size());
	}
	catch (std::exception const& e)
	{
		set_error(error, error_capacity, e.what());
		return -1;
	}
}

int mt_engine_list_json(void* value, char* output, int capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr) return -1;
		std::vector<lt::torrent_status> statuses;
		{
			std::lock_guard<std::mutex> lock(state->mutex);
			statuses = state->session->get_torrent_status(
				[](lt::torrent_status const&) { return true; }
				, lt::torrent_handle::query_name | lt::torrent_handle::query_save_path);
		}
		std::string json = "[";
		bool first = true;
		for (auto const& s : statuses)
		{
			if (!first) json += ',';
			first = false;
			std::string const hash = hash_string(s.info_hashes);
			auto const saved_options = load_torrent_options(*state, hash);
			bool const force_start = std::filesystem::exists(state_file(*state, hash, ".force-start"));
			auto const amount_left = std::max<std::int64_t>(0, s.total_wanted - s.total_wanted_done);
			auto const ratio = s.all_time_download > 0
				? double(s.all_time_upload) / double(s.all_time_download) : -1.0;
			auto const eta = s.download_rate > 0
				? amount_left / s.download_rate : -1;
			json += "{\"hash\":\"" + json_escape(hash) + "\",\"name\":\""
				+ json_escape(s.name) + "\",\"state\":\"" + state_name(s)
				+ "\",\"progress\":" + std::to_string(s.progress)
				+ ",\"dlspeed\":" + std::to_string(s.download_rate)
				+ ",\"upspeed\":" + std::to_string(s.upload_rate)
				+ ",\"size\":" + std::to_string(s.total_wanted)
				+ ",\"total_size\":" + std::to_string(s.total)
				+ ",\"completed\":" + std::to_string(s.total_wanted_done)
				+ ",\"amount_left\":" + std::to_string(amount_left)
				+ ",\"downloaded\":" + std::to_string(s.all_time_download)
				+ ",\"uploaded\":" + std::to_string(s.all_time_upload)
				+ ",\"downloaded_session\":" + std::to_string(s.total_payload_download)
				+ ",\"uploaded_session\":" + std::to_string(s.total_payload_upload)
				+ ",\"priority\":0,\"category\":\"\",\"tags\":\"\",\"eta\":" + std::to_string(eta)
				+ ",\"ratio\":" + std::to_string(ratio)
				+ ",\"save_path\":\"" + json_escape(s.save_path) + "\",\"tracker\":\"" + json_escape(s.current_tracker) + "\""
				+ ",\"added_on\":" + std::to_string(s.added_time)
				+ ",\"completion_on\":" + std::to_string(s.completed_time)
				+ ",\"num_complete\":" + std::to_string(s.num_complete)
				+ ",\"num_incomplete\":" + std::to_string(s.num_incomplete)
				+ ",\"num_seeds\":" + std::to_string(s.num_seeds)
				+ ",\"num_leechs\":" + std::to_string(s.num_peers)
				+ ",\"seq_dl\":" + std::string((saved_options & 1) ? "true" : "false")
				+ ",\"f_l_piece_prio\":" + std::string((saved_options & 2) ? "true" : "false")
				+ ",\"super_seeding\":" + std::string((saved_options & 4) ? "true" : "false")
				+ ",\"auto_tmm\":" + std::string((saved_options & 8) ? "true" : "false")
				+ ",\"force_start\":" + std::string(force_start ? "true" : "false") + "}";
		}
		json += ']';
		if (output == nullptr || capacity <= 0) return static_cast<int>(json.size());
		if (json.size() + 1 > static_cast<std::size_t>(capacity)) return -static_cast<int>(json.size()) - 1;
		std::memcpy(output, json.c_str(), json.size() + 1);
		return static_cast<int>(json.size());
	}
	catch (...) { return -1; }
}

int mt_engine_session_stats_json(void* value, char* output, int capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr) return -1;
		state->session->post_session_stats();
		std::vector<lt::alert*> alerts;
		lt::session_stats_alert const* snapshot = nullptr;
		for (int attempt = 0; attempt < 500 && snapshot == nullptr; ++attempt)
		{
			state->session->pop_alerts(&alerts);
			for (lt::alert* alert : alerts)
			{
				if (auto const* stats = lt::alert_cast<lt::session_stats_alert>(alert)) snapshot = stats;
				if (auto const* connected = lt::alert_cast<lt::peer_connect_alert>(alert))
				{
					append_peer_log(*state, *connected, false,
						std::string(connected->direction == lt::peer_connect_alert::direction_t::in ? "Connected incoming " : "Connected outgoing ")
						+ lt::socket_type_name(connected->socket_type));
					std::fprintf(stderr, "MintTorrent peer connected: direction=%s transport=%s\n",
						connected->direction == lt::peer_connect_alert::direction_t::in ? "incoming" : "outgoing",
						lt::socket_type_name(connected->socket_type));
				}
				if (auto const* disconnected = lt::alert_cast<lt::peer_disconnected_alert>(alert))
				{
					append_peer_log(*state, *disconnected, false,
						std::string("Disconnected ") + lt::socket_type_name(disconnected->socket_type)
						+ "; reason=" + std::to_string(static_cast<unsigned>(disconnected->reason))
						+ "; error=" + disconnected->error.message());
					std::fprintf(stderr, "MintTorrent peer disconnected: transport=%s reason=%u operation=%d error=%s\n",
						lt::socket_type_name(disconnected->socket_type),
						static_cast<unsigned>(disconnected->reason),
						static_cast<int>(disconnected->op), disconnected->error.message().c_str());
				}
				if (auto const* blocked = lt::alert_cast<lt::peer_blocked_alert>(alert))
					append_peer_log(*state, *blocked, true,
						"Blocked by libtorrent; reason=" + std::to_string(blocked->reason));
				if (lt::alert_cast<lt::udp_error_alert>(alert)
					|| lt::alert_cast<lt::listen_failed_alert>(alert)
					|| lt::alert_cast<lt::dht_error_alert>(alert)
					|| lt::alert_cast<lt::session_error_alert>(alert))
					std::fprintf(stderr, "MintTorrent libtorrent error: %s\n", alert->message().c_str());
			}
			if (snapshot == nullptr) std::this_thread::sleep_for(std::chrono::milliseconds(1));
		}
		if (snapshot == nullptr) throw std::runtime_error("timed out waiting for libtorrent session statistics");
		auto const counters = snapshot->counters();
		auto metric = [&counters](char const* name) -> std::int64_t {
			int const index = lt::find_metric_idx(name);
			return index >= 0 && static_cast<std::size_t>(index) < counters.size() ? counters[static_cast<std::size_t>(index)] : 0;
		};
		std::string const json = "{\"dht_nodes\":" + std::to_string(metric("dht.dht_nodes"))
			+ ",\"dht_node_cache\":" + std::to_string(metric("dht.dht_node_cache"))
			+ ",\"total_peer_connections\":" + std::to_string(metric("peer.num_peers_connected"))
			+ ",\"dht_messages_in\":" + std::to_string(metric("dht.dht_messages_in"))
			+ ",\"dht_messages_out\":" + std::to_string(metric("dht.dht_messages_out"))
			+ ",\"dht_bytes_in\":" + std::to_string(metric("dht.dht_bytes_in"))
			+ ",\"dht_bytes_out\":" + std::to_string(metric("dht.dht_bytes_out")) + "}";
		if (output == nullptr || capacity <= 0) return static_cast<int>(json.size());
		if (json.size() + 1 > static_cast<std::size_t>(capacity)) return -static_cast<int>(json.size()) - 1;
		std::memcpy(output, json.c_str(), json.size() + 1);
		return static_cast<int>(json.size());
	}
	catch (...) { return -1; }
}

int mt_engine_peer_log_json(void* value, long long last_known_id, char* output, int capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr) return -1;
		std::vector<engine::peer_log_entry> entries;
		{
			std::lock_guard<std::mutex> lock(state->peer_log_mutex);
			for (auto const& entry : state->peer_log)
				if (entry.id > last_known_id) entries.push_back(entry);
		}
		std::string json = "[";
		bool first = true;
		for (auto const& entry : entries)
		{
			if (!first) json += ',';
			first = false;
			json += "{\"id\":" + std::to_string(entry.id)
				+ ",\"ip\":\"" + json_escape(entry.ip)
				+ "\",\"timestamp\":" + std::to_string(entry.timestamp)
				+ ",\"blocked\":" + (entry.blocked ? "true" : "false")
				+ ",\"reason\":\"" + json_escape(entry.reason) + "\"}";
		}
		json += ']';
		if (output == nullptr || capacity <= 0) return static_cast<int>(json.size());
		if (json.size() + 1 > static_cast<std::size_t>(capacity)) return -static_cast<int>(json.size()) - 1;
		std::memcpy(output, json.c_str(), json.size() + 1);
		return static_cast<int>(json.size());
	}
	catch (...) { return -1; }
}

int mt_engine_files_json(void* value, char const* hash, char* output, int capacity, char* error, int error_capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr || hash == nullptr) throw std::runtime_error("invalid engine or torrent hash");
		std::vector<lt::torrent_handle> torrents;
		{
			std::lock_guard<std::mutex> lock(state->mutex);
			torrents = state->session->get_torrents();
		}
		lt::torrent_handle selected;
		for (auto const& handle : torrents)
		{
			if (hash_string(handle.info_hashes()) == hash) { selected = handle; break; }
		}
		if (!selected.is_valid()) throw std::runtime_error("torrent not found");
		auto const metadata = selected.torrent_file();
		std::string json = "[";
		if (metadata)
		{
			auto const& storage = metadata->layout();
			auto const renamed = selected.status(lt::torrent_handle::query_renamed_files).renamed_files;
			auto const progress = selected.file_progress();
			bool first = true;
			for (int i = 0; i < storage.num_files(); ++i)
			{
				auto const index = lt::file_index_t{i};
				auto const size = storage.file_size(index);
				auto const done = i < int(progress.size()) ? progress[std::size_t(i)] : 0;
				auto const priority = static_cast<int>(static_cast<unsigned char>(selected.file_priority(index)));
				if (!first) json += ',';
				first = false;
				json += "{\"index\":" + std::to_string(i) + ",\"name\":\"" + json_escape(renamed.file_path(storage, index))
					+ "\",\"size\":" + std::to_string(size) + ",\"progress\":"
					+ std::to_string(size > 0 ? double(done) / double(size) : 1.0)
					+ ",\"priority\":" + std::to_string(priority) + "}";
			}
		}
		json += ']';
		if (output == nullptr || capacity <= 0) return static_cast<int>(json.size());
		if (json.size() + 1 > static_cast<std::size_t>(capacity)) return -static_cast<int>(json.size()) - 1;
		std::memcpy(output, json.c_str(), json.size() + 1);
		return static_cast<int>(json.size());
	}
	catch (std::exception const& e)
	{
		set_error(error, error_capacity, e.what());
		return -1;
	}
}

int mt_engine_properties_json(void* value, char const* hash, char* output, int capacity, char* error, int error_capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr || hash == nullptr) throw std::runtime_error("invalid engine or torrent hash");
		std::vector<lt::torrent_handle> torrents;
		{
			std::lock_guard<std::mutex> lock(state->mutex);
			torrents = state->session->get_torrents();
		}
		lt::torrent_handle selected;
		for (auto const& handle : torrents)
		{
			if (hash_string(handle.info_hashes()) == hash) { selected = handle; break; }
		}
		if (!selected.is_valid()) throw std::runtime_error("torrent not found");
		auto const status = selected.status();
		auto const metadata = status.torrent_file.lock();
		auto const elapsed = std::max<std::int64_t>(0, std::time(nullptr) - status.added_time);
		auto const left = std::max<std::int64_t>(0, status.total_wanted - status.total_wanted_done);
		auto const eta = status.download_rate > 0 ? left / status.download_rate : -1;
		auto const ratio = status.all_time_download > 0
			? double(status.all_time_upload) / double(status.all_time_download) : -1.0;
		auto const average_download = elapsed > 0 ? status.all_time_download / elapsed : 0;
		auto const average_upload = elapsed > 0 ? status.all_time_upload / elapsed : 0;
		auto const pieces_num = metadata ? metadata->num_pieces() : -1;
		auto const piece_size = metadata ? metadata->piece_length() : -1;
		auto const total_size = metadata ? status.total : -1;
		auto const last_seen = status.last_seen_complete > 0 ? status.last_seen_complete : std::time_t(-1);
		auto const creation_date = std::time_t(-1);
		auto const popularity = status.num_complete >= 0 && status.num_incomplete > 0
			? double(status.num_complete) / double(status.num_incomplete) : 0.0;
		auto const seeds_total = status.list_seeds;
		auto const peers_total = status.list_peers;
		std::string v1;
		std::string v2;
		if (metadata)
		{
			auto const& hashes = metadata->info_hashes();
			if (hashes.has_v1()) v1 = lt::aux::to_hex({hashes.v1.data(), std::ptrdiff_t(hashes.v1.size())});
			if (hashes.has_v2()) v2 = lt::aux::to_hex({hashes.v2.data(), std::ptrdiff_t(hashes.v2.size())});
		}
		std::string const json = "{\"progress\":" + std::to_string(status.progress)
			+ ",\"availability\":" + std::to_string(metadata ? status.distributed_copies : -1.0f)
			+ ",\"time_elapsed\":" + std::to_string(elapsed)
			+ ",\"seeding_time\":" + std::to_string(lt::total_seconds(status.seeding_duration))
			+ ",\"eta\":" + std::to_string(eta)
			+ ",\"nb_connections\":" + std::to_string(status.num_connections)
			+ ",\"nb_connections_limit\":" + std::to_string(selected.max_connections())
			+ ",\"total_downloaded\":" + std::to_string(status.all_time_download)
			+ ",\"total_downloaded_session\":" + std::to_string(status.total_payload_download)
			+ ",\"total_uploaded\":" + std::to_string(status.all_time_upload)
			+ ",\"total_uploaded_session\":" + std::to_string(status.total_payload_upload)
			+ ",\"dl_speed\":" + std::to_string(status.download_rate)
			+ ",\"dl_speed_avg\":" + std::to_string(average_download)
			+ ",\"up_speed\":" + std::to_string(status.upload_rate)
			+ ",\"up_speed_avg\":" + std::to_string(average_upload)
			+ ",\"dl_limit\":" + std::to_string(selected.download_limit())
			+ ",\"up_limit\":" + std::to_string(selected.upload_limit())
			+ ",\"total_wasted\":" + std::to_string(status.total_failed_bytes + status.total_redundant_bytes)
			+ ",\"seeds\":" + std::to_string(status.num_seeds)
			+ ",\"seeds_total\":" + std::to_string(seeds_total)
			+ ",\"peers\":" + std::to_string(status.num_peers)
			+ ",\"peers_total\":" + std::to_string(peers_total)
			+ ",\"share_ratio\":" + std::to_string(ratio)
			+ ",\"popularity\":" + std::to_string(popularity)
			+ ",\"reannounce\":" + std::to_string(lt::total_seconds(status.next_announce))
			+ ",\"last_seen\":" + std::to_string(last_seen)
			+ ",\"total_size\":" + std::to_string(total_size)
			+ ",\"pieces_num\":" + std::to_string(pieces_num)
			+ ",\"piece_size\":" + std::to_string(piece_size)
			+ ",\"pieces_have\":" + std::to_string(status.pieces.count())
			+ ",\"created_by\":\"\""
			+ ",\"addition_date\":" + std::to_string(status.added_time)
			+ ",\"completion_date\":" + std::to_string(status.completed_time > 0 ? status.completed_time : std::time_t(-1))
			+ ",\"creation_date\":" + std::to_string(creation_date)
			+ ",\"infohash_v1\":\"" + v1 + "\",\"infohash_v2\":\"" + v2 + "\""
			+ ",\"save_path\":\"" + json_escape(status.save_path) + "\""
			+ ",\"comment\":\"\""
			+ ",\"has_metadata\":" + std::string(metadata ? "true" : "false")
			+ ",\"private\":" + std::string(metadata && metadata->priv() ? "true" : "false") + "}";
		if (output == nullptr || capacity <= 0) return static_cast<int>(json.size());
		if (json.size() + 1 > static_cast<std::size_t>(capacity)) return -static_cast<int>(json.size()) - 1;
		std::memcpy(output, json.c_str(), json.size() + 1);
		return static_cast<int>(json.size());
	}
	catch (std::exception const& e)
	{
		set_error(error, error_capacity, e.what());
		return -1;
	}
}

int mt_engine_piece_states_json(void* value, char const* hash, char* output, int capacity, char* error, int error_capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr || hash == nullptr) throw std::runtime_error("invalid engine or torrent hash");
		std::vector<lt::torrent_handle> torrents;
		{
			std::lock_guard<std::mutex> lock(state->mutex);
			torrents = state->session->get_torrents();
		}
		lt::torrent_handle selected;
		for (auto const& handle : torrents)
		{
			if (hash_string(handle.info_hashes()) == hash) { selected = handle; break; }
		}
		if (!selected.is_valid()) throw std::runtime_error("torrent not found");
		auto const status = selected.status();
		auto const metadata = status.torrent_file.lock();
		std::vector<int> states(metadata ? std::size_t(metadata->num_pieces()) : 0, 0);
		for (int i = 0; i < int(states.size()); ++i)
			if (i < status.pieces.size() && status.pieces.get_bit(lt::piece_index_t{i})) states[std::size_t(i)] = 2;
		for (auto const& partial : selected.get_download_queue())
		{
			auto const index = static_cast<int>(partial.piece_index);
			if (index < 0 || index >= int(states.size()) || states[std::size_t(index)] == 2) continue;
			for (int block = 0; block < partial.blocks_in_piece; ++block)
			{
				auto const block_state = partial.blocks[block].state;
				if (block_state == lt::block_info::requested || block_state == lt::block_info::writing)
				{
					states[std::size_t(index)] = 1;
					break;
				}
			}
		}
		std::string json = "[";
		for (std::size_t i = 0; i < states.size(); ++i) { if (i != 0) json += ','; json += std::to_string(states[i]); }
		json += ']';
		if (output == nullptr || capacity <= 0) return static_cast<int>(json.size());
		if (json.size() + 1 > static_cast<std::size_t>(capacity)) return -static_cast<int>(json.size()) - 1;
		std::memcpy(output, json.c_str(), json.size() + 1);
		return static_cast<int>(json.size());
	}
	catch (std::exception const& e)
	{
		set_error(error, error_capacity, e.what());
		return -1;
	}
}

int mt_engine_piece_availability_json(void* value, char const* hash, char* output, int capacity, char* error, int error_capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr || hash == nullptr) throw std::runtime_error("invalid engine or torrent hash");
		std::vector<lt::torrent_handle> torrents;
		{
			std::lock_guard<std::mutex> lock(state->mutex);
			torrents = state->session->get_torrents();
		}
		lt::torrent_handle selected;
		for (auto const& handle : torrents)
		{
			if (hash_string(handle.info_hashes()) == hash) { selected = handle; break; }
		}
		if (!selected.is_valid()) throw std::runtime_error("torrent not found");
		std::vector<int> availability;
		selected.piece_availability(availability);
		std::string json = "[";
		for (std::size_t i = 0; i < availability.size(); ++i) { if (i != 0) json += ','; json += std::to_string(availability[i]); }
		json += ']';
		if (output == nullptr || capacity <= 0) return static_cast<int>(json.size());
		if (json.size() + 1 > static_cast<std::size_t>(capacity)) return -static_cast<int>(json.size()) - 1;
		std::memcpy(output, json.c_str(), json.size() + 1);
		return static_cast<int>(json.size());
	}
	catch (std::exception const& e)
	{
		set_error(error, error_capacity, e.what());
		return -1;
	}
}

int mt_engine_trackers_json(void* value, char const* hash, char* output, int capacity, char* error, int error_capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr || hash == nullptr) throw std::runtime_error("invalid engine or torrent hash");
		std::vector<lt::torrent_handle> torrents;
		{
			std::lock_guard<std::mutex> lock(state->mutex);
			torrents = state->session->get_torrents();
		}
		lt::torrent_handle selected;
		for (auto const& handle : torrents)
		{
			if (hash_string(handle.info_hashes()) == hash) { selected = handle; break; }
		}
		if (!selected.is_valid()) throw std::runtime_error("torrent not found");
		auto const hashes = selected.info_hashes();
		auto const protocol = hashes.has_v1() ? lt::protocol_version::V1 : lt::protocol_version::V2;
		auto const entries = selected.trackers();
		std::string json = "[";
		bool first = true;
		for (auto const& tracker : entries)
		{
			lt::announce_infohash const* info = nullptr;
			if (!tracker.endpoints.empty()) info = &tracker.endpoints.front().info_hashes[protocol];
			int seeds = info ? info->scrape_complete : -1;
			int leeches = info ? info->scrape_incomplete : -1;
			int downloaded = info ? info->scrape_downloaded : -1;
			int peers = seeds >= 0 && leeches >= 0 ? seeds + leeches : -1;
			int status = 1;
			bool enabled = tracker.endpoints.empty() || std::any_of(tracker.endpoints.begin(), tracker.endpoints.end(), [](lt::announce_endpoint const& endpoint) { return endpoint.enabled; });
			if (!enabled) status = 0;
			else if (info && info->updating) status = 3;
			else if (info && info->last_error) status = 4;
			else if (tracker.verified) status = 2;
			std::string message = info ? info->message : std::string{};
			std::int64_t next_announce = 0;
			std::int64_t min_announce = 0;
			if (info)
			{
				auto const now = lt::clock_type::now();
				if (info->next_announce != (lt::time_point32::min)())
					next_announce = std::max<std::int64_t>(0, std::chrono::duration_cast<lt::seconds32>(info->next_announce - now).count());
				if (info->min_announce != (lt::time_point32::min)())
					min_announce = std::max<std::int64_t>(0, std::chrono::duration_cast<lt::seconds32>(info->min_announce - now).count());
			}
			if (!first) json += ',';
			first = false;
			json += "{\"url\":\"" + json_escape(tracker.url) + "\",\"tier\":" + std::to_string(tracker.tier)
				+ ",\"num_peers\":" + std::to_string(peers)
				+ ",\"num_seeds\":" + std::to_string(seeds)
				+ ",\"num_leeches\":" + std::to_string(leeches)
				+ ",\"num_downloaded\":" + std::to_string(downloaded)
				+ ",\"msg\":\"" + json_escape(message) + "\",\"next_announce\":" + std::to_string(next_announce)
				+ ",\"min_announce\":" + std::to_string(min_announce)
				+ ",\"status\":" + std::to_string(status)
				+ ",\"updating\":" + std::string(info && info->updating ? "true" : "false")
				+ ",\"endpoints\":[]}";
		}
		json += ']';
		if (output == nullptr || capacity <= 0) return static_cast<int>(json.size());
		if (json.size() + 1 > static_cast<std::size_t>(capacity)) return -static_cast<int>(json.size()) - 1;
		std::memcpy(output, json.c_str(), json.size() + 1);
		return static_cast<int>(json.size());
	}
	catch (std::exception const& e)
	{
		set_error(error, error_capacity, e.what());
		return -1;
	}
}

int mt_engine_webseeds_json(void* value, char const* hash, char* output, int capacity, char* error, int error_capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr || hash == nullptr) throw std::runtime_error("invalid engine or torrent hash");
		std::vector<lt::torrent_handle> torrents;
		{
			std::lock_guard<std::mutex> lock(state->mutex);
			torrents = state->session->get_torrents();
		}
		lt::torrent_handle selected;
		for (auto const& handle : torrents)
			if (hash_string(handle.info_hashes()) == hash) { selected = handle; break; }
		if (!selected.is_valid()) throw std::runtime_error("torrent not found");
		std::string json = "[";
		bool first = true;
		for (auto const& url : selected.url_seeds())
		{
			if (!first) json += ',';
			first = false;
			json += "{\"url\":\"" + json_escape(url) + "\"}";
		}
		json += ']';
		if (output == nullptr || capacity <= 0) return static_cast<int>(json.size());
		if (json.size() + 1 > static_cast<std::size_t>(capacity)) return -static_cast<int>(json.size()) - 1;
		std::memcpy(output, json.c_str(), json.size() + 1);
		return static_cast<int>(json.size());
	}
	catch (std::exception const& e)
	{
		set_error(error, error_capacity, e.what());
		return -1;
	}
}

int mt_engine_update_webseeds(void* value, char const* hash, int action, char const* urls, char const* new_url, char* error, int error_capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr || hash == nullptr || urls == nullptr || new_url == nullptr)
			throw std::runtime_error("invalid engine, torrent hash, or web seed URLs");
		if (action < 0 || action > 2) throw std::runtime_error("unknown web seed operation");
		std::lock_guard<std::mutex> lock(state->mutex);
		auto const torrents = state->session->get_torrents();
		lt::torrent_handle selected;
		for (auto const& handle : torrents)
			if (hash_string(handle.info_hashes()) == hash) { selected = handle; break; }
		if (!selected.is_valid()) throw std::runtime_error("torrent not found");
		auto const entries = split_values(urls);
		if (entries.empty()) throw std::runtime_error("no web seed URLs supplied");
		if (action == 0)
		{
			for (auto const& url : entries) selected.add_url_seed(url);
		}
		else if (action == 1)
		{
			for (auto const& url : entries) selected.remove_url_seed(url);
		}
		else
		{
			if (entries.size() != 1 || *new_url == '\0') throw std::runtime_error("web seed edit requires one URL and a replacement");
			auto const current = selected.url_seeds();
			if (current.find(entries.front()) == current.end()) throw std::runtime_error("web seed URL was not found");
			selected.remove_url_seed(entries.front());
			selected.add_url_seed(new_url);
		}
		std::string contents;
		for (auto const& url : selected.url_seeds()) contents += url + "\n";
		write_state_file(state_file(*state, hash, ".webseeds"), contents.data(), contents.size());
		return 0;
	}
	catch (std::exception const& e)
	{
		set_error(error, error_capacity, e.what());
		return -1;
	}
}

int mt_engine_peers_json(void* value, char const* hash, char* output, int capacity, char* error, int error_capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr || hash == nullptr) throw std::runtime_error("invalid engine or torrent hash");
		std::vector<lt::torrent_handle> torrents;
		{
			std::lock_guard<std::mutex> lock(state->mutex);
			torrents = state->session->get_torrents();
		}
		lt::torrent_handle selected;
		for (auto const& handle : torrents)
		{
			if (hash_string(handle.info_hashes()) == hash) { selected = handle; break; }
		}
		if (!selected.is_valid()) throw std::runtime_error("torrent not found");
		std::vector<lt::peer_info> peers;
		selected.get_peer_info(peers);
		std::string json = "{";
		bool first = true;
		for (auto const& peer : peers)
		{
			auto const endpoint = peer.remote_endpoint();
			auto const ip = endpoint.address().to_string();
			auto const key = ip + ":" + std::to_string(endpoint.port());
			std::string flags;
			if (bool(peer.flags & lt::peer_info::interesting)) flags += 'D';
			if (bool(peer.flags & lt::peer_info::remote_interested)) flags += 'd';
			if (!bool(peer.flags & lt::peer_info::choked)) flags += 'U';
			if (!bool(peer.flags & lt::peer_info::remote_choked)) flags += 'u';
			if (!bool(peer.flags & lt::peer_info::outgoing_connection)) flags += 'I';
			if (bool(peer.flags & lt::peer_info::outgoing_connection)) flags += 'O';
			if (bool(peer.flags & lt::peer_info::ssl_socket) || bool(peer.flags & lt::peer_info::rc4_encrypted)) flags += 'E';
			if (bool(peer.flags & lt::peer_info::seed)) flags += 'S';
			auto const client = peer.client.empty() ? std::string("Unknown") : peer.client;
			auto const connection = bool(peer.flags & lt::peer_info::utp_socket) ? "uTP" : "TCP";
			if (!first) json += ',';
			first = false;
			json += "\"" + json_escape(key) + "\":{";
			json += "\"ip\":\"" + json_escape(ip) + "\",\"port\":" + std::to_string(endpoint.port());
			json += ",\"host_name\":\"\",\"country\":\"\",\"country_code\":\"\"";
			json += ",\"connection\":\"" + std::string(connection) + "\",\"flags\":\"" + json_escape(flags) + "\",\"flags_desc\":\"" + json_escape(flags) + "\"";
			json += ",\"client\":\"" + json_escape(client) + "\",\"peer_id_client\":\"" + json_escape(client) + "\"";
			json += ",\"progress\":" + std::to_string(peer.progress);
			json += ",\"dl_speed\":" + std::to_string(peer.payload_down_speed) + ",\"up_speed\":" + std::to_string(peer.payload_up_speed);
			json += ",\"downloaded\":" + std::to_string(peer.total_download) + ",\"uploaded\":" + std::to_string(peer.total_upload);
			json += ",\"relevance\":0,\"contribution\":0,\"files\":\"\"}";
		}
		json += '}';
		if (output == nullptr || capacity <= 0) return static_cast<int>(json.size());
		if (json.size() + 1 > static_cast<std::size_t>(capacity)) return -static_cast<int>(json.size()) - 1;
		std::memcpy(output, json.c_str(), json.size() + 1);
		return static_cast<int>(json.size());
	}
	catch (std::exception const& e)
	{
		set_error(error, error_capacity, e.what());
		return -1;
	}
}

int mt_engine_action(void* value, char const* hash, int action, char* error, int error_capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr || hash == nullptr) throw std::runtime_error("invalid engine or hash");
		std::lock_guard<std::mutex> lock(state->mutex);
		auto const torrents = state->session->get_torrents();
		if (std::strcmp(hash, "all") == 0)
		{
			for (auto const& handle : torrents)
			{
				auto const item_hash = hash_string(handle.info_hashes());
				if (action == 0)
				{
					handle.unset_flags(lt::torrent_flags::auto_managed);
					handle.pause();
					write_state_file(state_file(*state, item_hash, ".paused"), "1", 1);
				}
				else if (action == 1)
				{
					if ((load_torrent_options(*state, item_hash) & 8) != 0
						&& !std::filesystem::exists(state_file(*state, item_hash, ".force-start")))
						handle.set_flags(lt::torrent_flags::auto_managed);
					else handle.unset_flags(lt::torrent_flags::auto_managed);
					handle.resume();
					remove_state_file(state_file(*state, item_hash, ".paused"));
				}
				else if (action == 2 || action == 3)
				{
					state->session->remove_torrent(handle, action == 3 ? lt::session::delete_files : lt::remove_flags_t{});
					remove_persisted_torrent(*state, item_hash);
				}
				else if (action == 4) handle.force_recheck();
				else if (action == 5) handle.force_reannounce();
				else throw std::runtime_error("unknown torrent action");
			}
			return 0;
		}
		for (auto const& handle : torrents)
		{
			auto const item_hash = hash_string(handle.info_hashes());
			if (item_hash != hash) continue;
			if (action == 0)
			{
				handle.unset_flags(lt::torrent_flags::auto_managed);
				handle.pause();
				write_state_file(state_file(*state, item_hash, ".paused"), "1", 1);
			}
			else if (action == 1)
			{
				if ((load_torrent_options(*state, item_hash) & 8) != 0
					&& !std::filesystem::exists(state_file(*state, item_hash, ".force-start")))
					handle.set_flags(lt::torrent_flags::auto_managed);
				else handle.unset_flags(lt::torrent_flags::auto_managed);
				handle.resume();
				remove_state_file(state_file(*state, item_hash, ".paused"));
			}
			else if (action == 2 || action == 3)
			{
				state->session->remove_torrent(handle, action == 3 ? lt::session::delete_files : lt::remove_flags_t{});
				remove_persisted_torrent(*state, item_hash);
			}
			else if (action == 4) handle.force_recheck();
			else if (action == 5) handle.force_reannounce();
			else throw std::runtime_error("unknown torrent action");
			return 0;
		}
		throw std::runtime_error("torrent hash was not found");
	}
	catch (std::exception const& e)
	{
		set_error(error, error_capacity, e.what());
		return -1;
	}
}

int mt_engine_file_priority(void* value, char const* hash, char const* ids, int priority, char* error, int error_capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr || hash == nullptr || ids == nullptr)
			throw std::runtime_error("invalid engine, hash, or file IDs");
		if (priority < 0 || priority > 7) throw std::runtime_error("file priority must be between 0 and 7");
		std::string const id_list(ids);
		if (id_list.empty() || id_list.size() > 65536) throw std::runtime_error("invalid file ID list");
		std::lock_guard<std::mutex> lock(state->mutex);
		auto const torrents = state->session->get_torrents();
		lt::torrent_handle selected;
		for (auto const& handle : torrents)
			if (hash_string(handle.info_hashes()) == hash) { selected = handle; break; }
		if (!selected.is_valid()) throw std::runtime_error("torrent was not found");
		auto const metadata = selected.torrent_file();
		if (!metadata) throw std::runtime_error("torrent metadata is not available");
		int const file_count = metadata->layout().num_files();
		std::vector<int> indices;
		std::istringstream input(id_list);
		std::string token;
		while (std::getline(input, token, '|'))
		{
			size_t consumed = 0;
			int const index = std::stoi(token, &consumed);
			if (consumed != token.size() || index < 0 || index >= file_count)
				throw std::runtime_error("file ID is outside the torrent file list");
			if (std::find(indices.begin(), indices.end(), index) == indices.end()) indices.push_back(index);
		}
		if (indices.empty()) throw std::runtime_error("file ID list is empty");
		auto priorities = selected.get_file_priorities();
		priorities.resize(std::size_t(file_count), lt::default_priority);
		auto const new_priority = lt::download_priority_t{static_cast<unsigned char>(priority)};
		for (auto const index : indices) priorities[std::size_t(index)] = new_priority;
		std::string serialized;
		for (std::size_t i = 0; i < priorities.size(); ++i)
		{
			if (i != 0) serialized += ',';
			serialized += std::to_string(static_cast<unsigned char>(priorities[i]));
		}
		auto const item_hash = hash_string(selected.info_hashes());
		write_state_file(state_file(*state, item_hash, ".priorities"), serialized.data(), serialized.size());
		for (auto const index : indices) selected.file_priority(lt::file_index_t{index}, new_priority);
		return 0;
	}
	catch (std::exception const& e)
	{
		set_error(error, error_capacity, e.what());
		return -1;
	}
}

int mt_engine_set_location(void* value, char const* hashes, char const* location, char* error, int error_capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr || hashes == nullptr || location == nullptr)
			throw std::runtime_error("invalid engine, hashes, or destination path");
		std::string const hash_list(hashes);
		if (hash_list.empty() || hash_list.size() > 65536) throw std::runtime_error("invalid torrent hash list");
		if (std::string_view(location).empty()) throw std::runtime_error("destination path is empty");
		std::filesystem::path const destination = std::filesystem::absolute(std::filesystem::u8path(location)).lexically_normal();
		if (destination.empty()) throw std::runtime_error("destination path is empty");
		std::lock_guard<std::mutex> lock(state->mutex);
		auto const torrents = state->session->get_torrents();
		std::vector<std::pair<std::string, lt::torrent_handle>> selected;
		if (hash_list == "all")
		{
			for (auto const& handle : torrents) selected.emplace_back(hash_string(handle.info_hashes()), handle);
		}
		else
		{
			std::istringstream input(hash_list);
			std::string token;
			while (std::getline(input, token, '|'))
			{
				if (token.empty()) throw std::runtime_error("torrent hash list contains an empty hash");
				auto const found = std::find_if(torrents.begin(), torrents.end(), [&](lt::torrent_handle const& handle)
					{ return hash_string(handle.info_hashes()) == token; });
				if (found == torrents.end()) throw std::runtime_error("torrent hash was not found: " + token);
				if (std::none_of(selected.begin(), selected.end(), [&](auto const& entry) { return entry.first == token; }))
					selected.emplace_back(token, *found);
			}
		}
		if (selected.empty()) throw std::runtime_error("no torrents selected");
		std::error_code fs_error;
		std::filesystem::create_directories(destination, fs_error);
		if (fs_error) throw std::runtime_error("cannot create destination path: " + fs_error.message());
		auto const destination_string = path_utf8(destination);
		for (auto const& [hash, handle] : selected)
		{
			write_state_file(state_file(*state, hash, ".savepath"), destination_string.data(), destination_string.size());
			handle.move_storage(destination_string);
		}
		return 0;
	}
	catch (std::exception const& e)
	{
		set_error(error, error_capacity, e.what());
		return -1;
	}
}

int mt_engine_rename_path(void* value, char const* hash, char const* old_path, char const* new_path,
	int is_folder, char* error, int error_capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr || hash == nullptr || old_path == nullptr || new_path == nullptr)
			throw std::runtime_error("invalid engine or rename path");
		if (is_folder != 0 && is_folder != 1) throw std::runtime_error("invalid rename type");
		auto safe_relative = [](std::string const& raw) {
			if (raw.empty()) throw std::runtime_error("rename path is empty");
			std::filesystem::path path = std::filesystem::u8path(raw);
			if (path.is_absolute() || path.has_root_name()) throw std::runtime_error("rename path must be relative");
			for (auto const& part : path)
				if (part == "." || part == ".." || part.empty()) throw std::runtime_error("rename path contains an unsafe component");
			auto normalized = path_utf8(path.lexically_normal());
			if (normalized.empty() || normalized == ".") throw std::runtime_error("rename path is invalid");
			return normalized;
		};
		auto const old_name = safe_relative(old_path);
		auto const new_name = safe_relative(new_path);
		if (old_name == new_name) return 0;
		std::lock_guard<std::mutex> lock(state->mutex);
		auto const torrents = state->session->get_torrents();
		auto const found = std::find_if(torrents.begin(), torrents.end(), [&](lt::torrent_handle const& handle)
			{ return hash_string(handle.info_hashes()) == hash; });
		if (found == torrents.end()) throw std::runtime_error("torrent hash was not found");
		auto const info = found->torrent_file();
		if (!info) throw std::runtime_error("torrent metadata is not available");
		auto const storage = info->layout();
		auto const renamed = found->status(lt::torrent_handle::query_renamed_files).renamed_files;
		std::vector<std::pair<lt::file_index_t, std::string>> renames;
		auto const prefix = old_name + "/";
		for (int i = 0; i < storage.num_files(); ++i)
		{
			auto const index = lt::file_index_t{i};
			auto const current = path_utf8(std::filesystem::u8path(renamed.file_path(storage, index)).lexically_normal());
			if (!is_folder && current == old_name)
				renames.emplace_back(index, new_name);
			else if (is_folder && current.compare(0, prefix.size(), prefix) == 0)
				renames.emplace_back(index, new_name + current.substr(old_name.size()));
		}
		if (renames.empty()) throw std::runtime_error("torrent path was not found");
		for (auto const& [index, target] : renames) found->rename_file(index, target);
		return 0;
	}
	catch (std::exception const& e)
	{
		set_error(error, error_capacity, e.what());
		return -1;
	}
}

int mt_engine_set_torrent_option(void* value, char const* hashes, int option, int value_flag, char* error, int error_capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr || hashes == nullptr) throw std::runtime_error("invalid engine or torrent hashes");
		if (option < 0 || option > 4 || (value_flag != 0 && value_flag != 1))
			throw std::runtime_error("invalid torrent option or value");
		std::lock_guard<std::mutex> lock(state->mutex);
		auto const torrents = state->session->get_torrents();
		std::vector<std::pair<std::string, lt::torrent_handle>> selected;
		if (std::strcmp(hashes, "all") == 0)
		{
			for (auto const& handle : torrents) selected.emplace_back(hash_string(handle.info_hashes()), handle);
		}
		else
		{
			for (auto const& token : split_values(hashes))
			{
				auto const found = std::find_if(torrents.begin(), torrents.end(), [&](lt::torrent_handle const& handle)
					{ return hash_string(handle.info_hashes()) == token; });
				if (found == torrents.end()) throw std::runtime_error("torrent hash was not found: " + token);
				if (std::none_of(selected.begin(), selected.end(), [&](auto const& item) { return item.first == token; }))
					selected.emplace_back(token, *found);
			}
		}
		if (selected.empty()) throw std::runtime_error("no torrents selected");
		for (auto const& [hash, handle] : selected)
		{
			int options = load_torrent_options(*state, hash);
			if (option == 0 || option == 1) options ^= (1 << option);
			else if (option == 2)
			{
				if (value_flag) options |= 4; else options &= ~4;
			}
			else if (option == 3)
			{
				if (value_flag)
				{
					options &= ~8;
					remove_state_file(state_file(*state, hash, ".paused"));
					write_state_file(state_file(*state, hash, ".force-start"), "1", 1);
					handle.unset_flags(lt::torrent_flags::auto_managed | lt::torrent_flags::paused);
					handle.resume();
				}
				else
				{
					remove_state_file(state_file(*state, hash, ".force-start"));
					options |= 8;
					handle.set_flags(lt::torrent_flags::auto_managed);
					handle.resume();
				}
			}
			else
			{
				remove_state_file(state_file(*state, hash, ".force-start"));
				if (value_flag)
				{
					options |= 8;
					remove_state_file(state_file(*state, hash, ".paused"));
					handle.set_flags(lt::torrent_flags::auto_managed);
					handle.resume();
				}
				else
				{
					options &= ~8;
					handle.unset_flags(lt::torrent_flags::auto_managed);
				}
			}
			if (option == 0) { if (options & 1) handle.set_flags(lt::torrent_flags::sequential_download); else handle.unset_flags(lt::torrent_flags::sequential_download); }
			if (option == 1)
			{
				auto const metadata = handle.torrent_file();
				if (!metadata) throw std::runtime_error("torrent metadata is not available for first/last piece priority");
				int const count = metadata->num_pieces();
				if (count > 0)
				{
					auto const priority = (options & 2) ? lt::top_priority : lt::default_priority;
					handle.piece_priority(lt::piece_index_t{0}, priority);
					handle.piece_priority(lt::piece_index_t{count - 1}, priority);
				}
			}
			if (option == 2) { if (options & 4) handle.set_flags(lt::torrent_flags::super_seeding); else handle.unset_flags(lt::torrent_flags::super_seeding); }
			persist_torrent_options(*state, hash, options);
		}
		return 0;
	}
	catch (std::exception const& e)
	{
		set_error(error, error_capacity, e.what());
		return -1;
	}
}

int mt_engine_add_peers(void* value, char const* hashes, char const* peers, char* error, int error_capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr || hashes == nullptr || peers == nullptr)
			throw std::runtime_error("invalid engine, torrent hashes, or peer endpoints");
		auto const peer_tokens = split_values(peers);
		if (peer_tokens.empty()) throw std::runtime_error("no peer endpoints supplied");
		std::vector<lt::tcp::endpoint> endpoints;
		for (auto const& peer : peer_tokens)
		{
			lt::error_code ec;
			auto const endpoint = lt::aux::parse_endpoint(peer, ec);
			if (ec || endpoint.port() == 0) throw std::runtime_error("invalid peer endpoint: " + peer);
			endpoints.push_back(endpoint);
		}
		std::lock_guard<std::mutex> lock(state->mutex);
		auto const torrents = state->session->get_torrents();
		std::vector<lt::torrent_handle> selected;
		if (std::strcmp(hashes, "all") == 0)
		{
			selected = torrents;
		}
		else
		{
			for (auto const& token : split_values(hashes))
			{
				auto const found = std::find_if(torrents.begin(), torrents.end(), [&](lt::torrent_handle const& handle)
					{ return hash_string(handle.info_hashes()) == token; });
				if (found == torrents.end()) throw std::runtime_error("torrent hash was not found: " + token);
				if (std::none_of(selected.begin(), selected.end(), [&](lt::torrent_handle const& handle)
					{ return hash_string(handle.info_hashes()) == token; })) selected.push_back(*found);
			}
		}
		if (selected.empty()) throw std::runtime_error("no torrents selected");
		for (auto const& handle : selected)
			for (auto const& endpoint : endpoints) handle.connect_peer(endpoint);
		return 0;
	}
	catch (std::exception const& e)
	{
		set_error(error, error_capacity, e.what());
		return -1;
	}
}

int mt_engine_ban_peers(void* value, char const* hash, char const* addresses, char* error, int error_capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr || hash == nullptr || addresses == nullptr)
			throw std::runtime_error("invalid engine, torrent hash, or peer addresses");
		auto const tokens = split_values(addresses);
		if (tokens.empty()) throw std::runtime_error("no peer addresses supplied");
		std::lock_guard<std::mutex> lock(state->mutex);
		auto const torrents = state->session->get_torrents();
		if (std::none_of(torrents.begin(), torrents.end(), [&](lt::torrent_handle const& handle)
			{ return hash_string(handle.info_hashes()) == hash; }))
			throw std::runtime_error("torrent hash was not found");
		auto banned = state->banned_peers;
		auto filter = state->session->get_ip_filter();
		for (auto const& token : tokens)
		{
			lt::error_code ec;
			auto const address = lt::make_address(token, ec);
			if (ec || address.to_string() != token) throw std::runtime_error("invalid peer IP address: " + token);
			banned.insert(token);
			filter.add_rule(address, address, lt::ip_filter::blocked);
		}
		persist_banned_peers(*state, banned);
		state->session->set_ip_filter(std::move(filter));
		state->banned_peers = std::move(banned);
		return 0;
	}
	catch (std::exception const& e)
	{
		set_error(error, error_capacity, e.what());
		return -1;
	}
}

int mt_engine_is_ip_banned(void* value, char const* address, char* error, int error_capacity)
{
	try
	{
		auto* state = static_cast<engine*>(value);
		if (state == nullptr || address == nullptr) throw std::runtime_error("invalid engine or IP address");
		lt::error_code ec;
		auto const parsed = lt::make_address(address, ec);
		if (ec) throw std::runtime_error("invalid IP address: " + std::string(address));
		std::lock_guard<std::mutex> lock(state->mutex);
		return (state->session->get_ip_filter().access(parsed) & lt::ip_filter::blocked) != 0 ? 1 : 0;
	}
	catch (std::exception const& e)
	{
		set_error(error, error_capacity, e.what());
		return -1;
	}
}

} // extern "C"
