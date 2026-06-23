require "spec"
require "../../src/swim/cipher"
require "digest/sha256"

describe Swim::Cipher do
  it "encrypts and decrypts perfectly" do
    key = Digest::SHA256.digest("my-cluster-secret").to_slice
    plaintext = %({"hello":"world"})

    ciphertext = Swim::Cipher.encrypt(plaintext, key)
    ciphertext.should_not eq(plaintext.to_slice)

    decrypted = Swim::Cipher.decrypt(ciphertext, key)
    decrypted.should eq(plaintext)
  end

  it "raises OpenSSL::Cipher::Error on tampered data" do
    key = Digest::SHA256.digest("my-cluster-secret").to_slice
    ciphertext = Swim::Cipher.encrypt("hello", key)

    # Tamper with the ciphertext
    ciphertext[-1] = ciphertext[-1] ^ 1_u8

    expect_raises(OpenSSL::Cipher::Error) do
      Swim::Cipher.decrypt(ciphertext, key)
    end
  end

  it "raises OpenSSL::Cipher::Error if payload is impossibly small" do
    key = Digest::SHA256.digest("my-cluster-secret").to_slice
    expect_raises(OpenSSL::Cipher::Error, "Payload too small") do
      Swim::Cipher.decrypt(Bytes.new(10), key)
    end
  end
end
