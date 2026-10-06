#ifndef NOTES_CRYPTO_H
#define NOTES_CRYPTO_H

#include <glib.h>

#define NOTES_CRYPTO_KEY_LEN 32
#define NOTES_CRYPTO_NONCE_LEN 12

gboolean notes_crypto_random (guint8 *out, gint len);
gboolean notes_crypto_derive (const gchar *password, const guint8 *salt, gint salt_len, guint iterations, guint8 *key);
GBytes *notes_crypto_seal (const guint8 *key, const guint8 *nonce, const guint8 *plain, gint plain_len);
GBytes *notes_crypto_open (const guint8 *key, const guint8 *nonce, const guint8 *sealed, gint sealed_len);

#endif
