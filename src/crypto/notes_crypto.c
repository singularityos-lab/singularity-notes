#include <glib.h>
#include <string.h>
#include <gnutls/gnutls.h>
#include <gnutls/crypto.h>

#include "notes_crypto.h"

gboolean
notes_crypto_random (guint8 *out, gint len)
{
  return gnutls_rnd (GNUTLS_RND_KEY, out, (size_t) len) == 0;
}

gboolean
notes_crypto_derive (const gchar *password, const guint8 *salt, gint salt_len, guint iterations, guint8 *key)
{
  gnutls_datum_t pass = { (unsigned char *) password, (unsigned int) strlen (password) };
  gnutls_datum_t s = { (unsigned char *) salt, (unsigned int) salt_len };
  return gnutls_pbkdf2 (GNUTLS_MAC_SHA256, &pass, &s, iterations, key, NOTES_CRYPTO_KEY_LEN) == 0;
}

GBytes *
notes_crypto_seal (const guint8 *key, const guint8 *nonce, const guint8 *plain, gint plain_len)
{
  gnutls_aead_cipher_hd_t h;
  gnutls_datum_t k = { (unsigned char *) key, NOTES_CRYPTO_KEY_LEN };
  if (gnutls_aead_cipher_init (&h, GNUTLS_CIPHER_AES_256_GCM, &k) != 0)
    return NULL;
  size_t out_len = (size_t) plain_len + 16;
  guint8 *out = g_malloc (out_len);
  int rc = gnutls_aead_cipher_encrypt (h, nonce, NOTES_CRYPTO_NONCE_LEN, NULL, 0, 16, plain, (size_t) plain_len, out, &out_len);
  gnutls_aead_cipher_deinit (h);
  if (rc != 0) {
    g_free (out);
    return NULL;
  }
  return g_bytes_new_take (out, out_len);
}

GBytes *
notes_crypto_open (const guint8 *key, const guint8 *nonce, const guint8 *sealed, gint sealed_len)
{
  gnutls_aead_cipher_hd_t h;
  gnutls_datum_t k = { (unsigned char *) key, NOTES_CRYPTO_KEY_LEN };
  if (sealed_len < 16)
    return NULL;
  if (gnutls_aead_cipher_init (&h, GNUTLS_CIPHER_AES_256_GCM, &k) != 0)
    return NULL;
  size_t out_len = (size_t) sealed_len;
  guint8 *out = g_malloc (out_len + 1);
  int rc = gnutls_aead_cipher_decrypt (h, nonce, NOTES_CRYPTO_NONCE_LEN, NULL, 0, 16, sealed, (size_t) sealed_len, out, &out_len);
  gnutls_aead_cipher_deinit (h);
  if (rc != 0) {
    g_free (out);
    return NULL;
  }
  return g_bytes_new_take (out, out_len);
}
