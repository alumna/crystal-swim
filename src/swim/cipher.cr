require "openssl/cipher"

# Crystal's standard library currently lacks bindings for GCM Authentication Tags.
# We map the missing OpenSSL C functions and reopen the class to add them.
lib LibCrypto
  EVP_CTRL_GCM_GET_TAG = 0x10
  EVP_CTRL_GCM_SET_TAG = 0x11

  fun evp_cipher_ctx_ctrl = EVP_CIPHER_CTX_ctrl(ctx : EVP_CIPHER_CTX, type : LibC::Int, arg : LibC::Int, ptr : Void*) : LibC::Int
end

class OpenSSL::Cipher
  def gcm_tag : Bytes
    tag = Bytes.new(16)
    ret = LibCrypto.evp_cipher_ctx_ctrl(@ctx, LibCrypto::EVP_CTRL_GCM_GET_TAG, 16, tag.to_unsafe.as(Void*))
    raise Error.new("Failed to get GCM tag") if ret != 1
    tag
  end

  def gcm_tag=(tag : Bytes)
    ret = LibCrypto.evp_cipher_ctx_ctrl(@ctx, LibCrypto::EVP_CTRL_GCM_SET_TAG, tag.size, tag.to_unsafe.as(Void*))
    raise Error.new("Failed to set GCM tag") if ret != 1
    tag
  end
end

module Swim
  module Cipher
    # AES-256-GCM requires a 32-byte key.
    # We prefix the packet with the 12-byte IV and 16-byte Auth Tag.
    def self.encrypt(plaintext : String, key : Bytes) : Bytes
      cipher = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.encrypt
      cipher.key = key

      iv = Random::Secure.random_bytes(12)
      cipher.iv = iv

      ciphertext = cipher.update(plaintext)
      ciphertext += cipher.final

      io = IO::Memory.new(12 + 16 + ciphertext.bytesize)
      io.write(iv)
      io.write(cipher.gcm_tag)
      io.write(ciphertext)
      io.to_slice
    end

    def self.decrypt(payload : Bytes, key : Bytes) : String
      raise OpenSSL::Cipher::Error.new("Payload too small") if payload.size < 28

      iv = payload[0, 12]
      tag = payload[12, 16]
      ciphertext = payload[28, payload.size - 28]

      cipher = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.decrypt
      cipher.key = key
      cipher.iv = iv
      cipher.gcm_tag = tag

      plaintext = cipher.update(ciphertext)
      plaintext += cipher.final
      String.new(plaintext)
    end
  end
end
