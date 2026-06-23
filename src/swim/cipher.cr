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
    def self.encrypt(plaintext : String, key : Bytes) : Bytes
      cipher = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.encrypt
      cipher.key = key

      iv = Random::Secure.random_bytes(12)
      cipher.iv = iv

      ciphertext_update = cipher.update(plaintext)
      ciphertext_final = cipher.final
      tag = cipher.gcm_tag

      # Direct byte copying to avoid IO::Memory and intermediate Bytes allocations
      out_size = 28 + ciphertext_update.bytesize + ciphertext_final.bytesize
      out = Bytes.new(out_size)

      out[0, 12].copy_from(iv)
      out[12, 16].copy_from(tag)
      out[28, ciphertext_update.bytesize].copy_from(ciphertext_update)

      if ciphertext_final.bytesize > 0
        out[28 + ciphertext_update.bytesize, ciphertext_final.bytesize].copy_from(ciphertext_final)
      end

      out
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

      # Using String.build prevents intermediate Bytes#+ allocation
      String.build do |str|
        str.write(cipher.update(ciphertext))
        str.write(cipher.final)
      end
    end
  end
end
