[CCode (cheader_filename = "notes_crypto.h")]
namespace NotesCrypto {
    [CCode (cname = "NOTES_CRYPTO_KEY_LEN")]
    public const int KEY_LEN;
    [CCode (cname = "NOTES_CRYPTO_NONCE_LEN")]
    public const int NONCE_LEN;
    [CCode (cname = "notes_crypto_random")]
    public bool random ([CCode (array_length_type = "gint")] uint8[] out);
    [CCode (cname = "notes_crypto_derive")]
    public bool derive (string password, [CCode (array_length_type = "gint")] uint8[] salt, uint iterations, [CCode (array_length = false)] uint8[] key);
    [CCode (cname = "notes_crypto_seal")]
    public GLib.Bytes? seal ([CCode (array_length = false)] uint8[] key, [CCode (array_length = false)] uint8[] nonce, [CCode (array_length_type = "gint")] uint8[] plain);
    [CCode (cname = "notes_crypto_open")]
    public GLib.Bytes? open ([CCode (array_length = false)] uint8[] key, [CCode (array_length = false)] uint8[] nonce, [CCode (array_length_type = "gint")] uint8[] cipher);
}
