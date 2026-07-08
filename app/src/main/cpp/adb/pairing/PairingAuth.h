#pragma once

#include <cstddef>
#include <cstdint>

struct PairingAuthCtx;

PairingAuthCtx* pairing_auth_client_new(const uint8_t* pswd, size_t len);
PairingAuthCtx* pairing_auth_server_new(const uint8_t* pswd, size_t len);
void pairing_auth_destroy(PairingAuthCtx* ctx);
size_t pairing_auth_msg_size(PairingAuthCtx* ctx);
void pairing_auth_get_spake2_msg(PairingAuthCtx* ctx, uint8_t* out_buf);
bool pairing_auth_init_cipher(PairingAuthCtx* ctx, const uint8_t* their_msg, size_t msg_len);
size_t pairing_auth_safe_encrypted_size(PairingAuthCtx* ctx, size_t len);
bool pairing_auth_encrypt(PairingAuthCtx* ctx, const uint8_t* inbuf, size_t inlen, uint8_t* outbuf,
                          size_t* outlen);
size_t pairing_auth_safe_decrypted_size(PairingAuthCtx* ctx, const uint8_t* buf, size_t len);
bool pairing_auth_decrypt(PairingAuthCtx* ctx, const uint8_t* inbuf, size_t inlen, uint8_t* outbuf,
                          size_t* outlen);
