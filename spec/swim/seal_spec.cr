require "../spec_helper"

describe Swim::Seal do
  it "encrypts and decrypts with a reused context" do
    seal = Swim::Seal.new("cluster-secret")
    plain = "ping-body".to_slice
    cipher = Bytes.new(plain.size + Swim::Seal::PREFIX)
    size = seal.encrypt(plain, cipher)
    size.should eq(plain.size + Swim::Seal::PREFIX)
    first = cipher[0, size].dup

    again = seal.encrypt(plain, cipher)
    again.should eq(size)
    cipher[0, 12].should_not eq(first[0, 12])

    dest = Bytes.new(plain.size)
    seal.decrypt(cipher[0, size], dest).should eq(plain.size)
    dest.should eq(plain)
  end

  it "rejects a short buffer, a short packet, and a bad tag" do
    seal = Swim::Seal.new("cluster-secret")
    plain = Bytes.new(32)
    cipher = Bytes.new(plain.size + Swim::Seal::PREFIX)
    size = seal.encrypt(plain, cipher)

    seal.encrypt(plain, Bytes.new(8)).should eq(-1)
    seal.decrypt(Bytes.new(10), Bytes.new(32)).should eq(-1)
    seal.decrypt(cipher[0, size], Bytes.new(4)).should eq(-1)

    cipher[size - 1] = cipher[size - 1] ^ 1_u8
    seal.decrypt(cipher[0, size], Bytes.new(plain.size)).should eq(-1)
  end
end
