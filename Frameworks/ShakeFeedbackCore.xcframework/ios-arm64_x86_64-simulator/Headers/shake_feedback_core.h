#pragma once

#ifdef __cplusplus
extern "C" {
#endif

char *sf_reduce_threads_json(const char *input_json);
char *sf_thread_messages_json(const char *input_json);
char *sf_generated_profile_json(const char *pubkey_hex, const char *app_name);
void sf_free_string(char *ptr);

#ifdef __cplusplus
}
#endif

