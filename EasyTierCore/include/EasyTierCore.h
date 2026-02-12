#ifndef SwiftierCore_h
#define SwiftierCore_h

#include <stdint.h>

// Ensure C linkage
#ifdef __cplusplus
extern "C" {
#endif

// Initialize logger
// path: Log file path
// level: Log level (e.g. "info", "debug")
// err_msg: Output error message if failed (needs to be freed if not null?
// Usually err_msg in this pattern is static or allocated. Looking at rust code:
// CString::new(e).into_raw(). So YES, it needs to be freed by free_string if
// not null.)
int init_logger(const char *path, const char *level, const char *subsystem,
                const char **err_msg);

// Set TUN file descriptor
// Note: On macOS Helper (Root), Swiftier might create TUN directly.
int set_tun_fd(int fd, const char **err_msg);

// Free string returned by Rust (including err_msg output)
void free_string(const char *s);

// Start network instance with TOML config string
int run_network_instance(const char *cfg_str, const char **err_msg);

// Stop network instance
int stop_network_instance(void);

// Callbacks types
typedef void (*VoidCallback)(void);

// Register callbacks
int register_stop_callback(VoidCallback callback, const char **err_msg);
int register_running_info_callback(VoidCallback callback, const char **err_msg);

// Get running info JSON
// json: Output pointer to json string (needs free)
int get_running_info(const char **json, const char **err_msg);

// Get latest error message
// msg: Output pointer to msg string (needs free)
int get_latest_error_msg(const char **msg, const char **err_msg);

#ifdef __cplusplus
}
#endif

#endif /* SwiftierCore_h */
