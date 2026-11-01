#ifndef TORRENT_MINTTORRENT_ENGINE_API_H
#define TORRENT_MINTTORRENT_ENGINE_API_H

#include "libtorrent/aux_/export.hpp"

#ifdef __cplusplus
extern "C" {
#endif

TORRENT_EXPORT void* mt_engine_create(char const* download_path, char const* listen_interfaces, char* error, int error_capacity);
TORRENT_EXPORT void mt_engine_destroy(void* engine);
TORRENT_EXPORT int mt_engine_save_resume_data(void* engine, char* error, int error_capacity);
TORRENT_EXPORT int mt_engine_add_magnet(void* engine, char const* magnet, char* error, int error_capacity);
TORRENT_EXPORT int mt_engine_add_magnet_with_options(void* engine, char const* magnet, char const* save_path, int paused, char* error, int error_capacity);
TORRENT_EXPORT int mt_engine_add_torrent_buffer(void* engine, char const* buffer, int size, char* error, int error_capacity);
TORRENT_EXPORT int mt_engine_add_torrent_buffer_at(void* engine, char const* buffer, int size,
	char const* save_path, int paused, char* error, int error_capacity);
TORRENT_EXPORT int mt_parse_torrent_metadata(char const* buffer, int size, char* output, int capacity, char* error, int error_capacity);
TORRENT_EXPORT int mt_parse_magnet_hash(char const* magnet, char* output, int capacity, char* error, int error_capacity);
using mt_torrent_create_progress_callback = int (*)(void*, int);
TORRENT_EXPORT int mt_create_torrent_file(char const* source_path, char const* output_path,
	char const* format, int piece_size, int ignore_dotfiles, int is_private,
	char const* trackers, char const* url_seeds, char const* comment, char const* source,
	mt_torrent_create_progress_callback progress_callback, void* progress_context,
	char* error, int error_capacity);
TORRENT_EXPORT int mt_engine_export_torrent(void* engine, char const* hash, char* output, int capacity, char* error, int error_capacity);
TORRENT_EXPORT int mt_engine_list_json(void* engine, char* output, int capacity);
TORRENT_EXPORT int mt_engine_session_stats_json(void* engine, char* output, int capacity);
TORRENT_EXPORT int mt_engine_peer_log_json(void* engine, long long last_known_id, char* output, int capacity);
TORRENT_EXPORT int mt_engine_set_speed_limits(void* engine, int download_limit, int upload_limit, char* error, int error_capacity);
TORRENT_EXPORT int mt_engine_set_alt_speed_limits(void* engine, int download_limit, int upload_limit, char* error, int error_capacity);
TORRENT_EXPORT int mt_engine_toggle_alt_speed_limits(void* engine, char* error, int error_capacity);
TORRENT_EXPORT int mt_engine_speed_limits_json(void* engine, char* output, int capacity, char* error, int error_capacity);
TORRENT_EXPORT int mt_engine_set_session_paused(void* engine, int paused, char* error, int error_capacity);
TORRENT_EXPORT int mt_engine_update_trackers(void* engine, char const* hashes, int action, char const* urls, char const* new_url, int tier, char* error, int error_capacity);
TORRENT_EXPORT int mt_engine_files_json(void* engine, char const* hash, char* output, int capacity, char* error, int error_capacity);
TORRENT_EXPORT int mt_engine_properties_json(void* engine, char const* hash, char* output, int capacity, char* error, int error_capacity);
TORRENT_EXPORT int mt_engine_piece_states_json(void* engine, char const* hash, char* output, int capacity, char* error, int error_capacity);
TORRENT_EXPORT int mt_engine_piece_availability_json(void* engine, char const* hash, char* output, int capacity, char* error, int error_capacity);
TORRENT_EXPORT int mt_engine_trackers_json(void* engine, char const* hash, char* output, int capacity, char* error, int error_capacity);
TORRENT_EXPORT int mt_engine_peers_json(void* engine, char const* hash, char* output, int capacity, char* error, int error_capacity);
TORRENT_EXPORT int mt_engine_action(void* engine, char const* hash, int action, char* error, int error_capacity);
TORRENT_EXPORT int mt_engine_file_priority(void* engine, char const* hash, char const* ids, int priority, char* error, int error_capacity);
TORRENT_EXPORT int mt_engine_set_location(void* engine, char const* hashes, char const* location, char* error, int error_capacity);
TORRENT_EXPORT int mt_engine_rename_path(void* engine, char const* hash, char const* old_path, char const* new_path, int is_folder, char* error, int error_capacity);
TORRENT_EXPORT int mt_engine_set_torrent_option(void* engine, char const* hashes, int option, int value, char* error, int error_capacity);
TORRENT_EXPORT int mt_engine_update_webseeds(void* engine, char const* hash, int action, char const* urls, char const* new_url, char* error, int error_capacity);
TORRENT_EXPORT int mt_engine_webseeds_json(void* engine, char const* hash, char* output, int capacity, char* error, int error_capacity);
TORRENT_EXPORT int mt_engine_add_peers(void* engine, char const* hashes, char const* peers, char* error, int error_capacity);
TORRENT_EXPORT int mt_engine_ban_peers(void* engine, char const* hash, char const* addresses, char* error, int error_capacity);
TORRENT_EXPORT int mt_engine_is_ip_banned(void* engine, char const* address, char* error, int error_capacity);

#ifdef __cplusplus
}
#endif

#endif
