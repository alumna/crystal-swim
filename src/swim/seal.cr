require "digest/sha256"
require "openssl"
require "random/secure"

# GCM tag control is missing from the Crystal OpenSSL bindings.
lib LibCrypto
  EVP_CTRL_GCM_GET_TAG = 0x10
  EVP_CTRL_GCM_SET_TAG = 0x11

  fun evp_cipher_ctx_ctrl = EVP_CIPHER_CTX_ctrl(ctx : EVP_CIPHER_CTX, type : LibC::Int, arg : LibC::Int, ptr : Void*) : LibC::Int
end

module Swim
  # AES-256-GCM for one cluster key. The cipher context and the key live for
  # the life of the node. Encrypt and decrypt write into the caller buffer.
  class Seal
    TAG = 16
    IV  = 12
    # IV, tag, then ciphertext.
    PREFIX = IV + TAG

    def initialize(secret : String)
      raw = Digest::SHA256.digest(secret)
      @key = StaticArray(UInt8, 32).new(0_u8)
      32.times { |index| @key[index] = raw[index] }
      @cipher = LibCrypto.evp_get_cipherbyname("aes-256-gcm")
      raise SealError.new("aes-256-gcm is not available") unless @cipher
      @encrypt = LibCrypto.evp_cipher_ctx_new
      @decrypt = LibCrypto.evp_cipher_ctx_new
      raise SealError.new("aes-256-gcm is not available") unless @encrypt && @decrypt
    end

    # Writes IV, tag, and ciphertext into `dest`. Returns the byte count, or -1.
    def encrypt(plain : Bytes, dest : Bytes) : Int32
      return -1 if dest.size < plain.size &+ PREFIX
      Random::Secure.random_bytes(dest[0, IV])
      return -1 if LibCrypto.evp_cipherinit_ex(@encrypt, @cipher, nil, @key.to_unsafe, dest.to_unsafe, 1) != 1
      LibCrypto.evp_cipher_ctx_set_padding(@encrypt, 0)
      written = 0
      cipher_out = dest.to_unsafe + PREFIX
      return -1 if LibCrypto.evp_cipherupdate(@encrypt, cipher_out, pointerof(written), plain.to_unsafe, plain.size) != 1
      extra = 0
      return -1 if LibCrypto.evp_cipherfinal_ex(@encrypt, cipher_out + written, pointerof(extra)) != 1
      tag = (dest.to_unsafe + IV).as(Void*)
      return -1 if LibCrypto.evp_cipher_ctx_ctrl(@encrypt, LibCrypto::EVP_CTRL_GCM_GET_TAG, TAG, tag) != 1
      PREFIX &+ written &+ extra
    end

    # Writes plaintext into `dest`. Returns the byte count, or -1 when the tag fails.
    def decrypt(packet : Bytes, dest : Bytes) : Int32
      return -1 if packet.size < PREFIX
      body = packet.size &- PREFIX
      return -1 if dest.size < body
      iv = packet.to_unsafe
      return -1 if LibCrypto.evp_cipherinit_ex(@decrypt, @cipher, nil, @key.to_unsafe, iv, 0) != 1
      LibCrypto.evp_cipher_ctx_set_padding(@decrypt, 0)
      tag = (packet.to_unsafe + IV).as(Void*)
      return -1 if LibCrypto.evp_cipher_ctx_ctrl(@decrypt, LibCrypto::EVP_CTRL_GCM_SET_TAG, TAG, tag) != 1
      written = 0
      cipher_in = packet.to_unsafe + PREFIX
      return -1 if LibCrypto.evp_cipherupdate(@decrypt, dest.to_unsafe, pointerof(written), cipher_in, body) != 1
      extra = 0
      return -1 if LibCrypto.evp_cipherfinal_ex(@decrypt, dest.to_unsafe + written, pointerof(extra)) != 1
      written &+ extra
    end
  end

  class SealError < Exception
  end
end
