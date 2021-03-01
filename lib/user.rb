#
# Copyright (c) 2017 joshua stein <jcs@jcs.org>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#

require "rotp"

class User < DBModel
  self.table_name = "users"
  #set_primary_key "uuid"

  DEFAULT_KDF_TYPE = Bitwarden::KDF::PBKDF2

  before_create :generate_uuid_primary_key
  before_validation :generate_security_stamp

  has_many :ciphers,
    foreign_key: :user_uuid,
    inverse_of: :user,
    dependent: :destroy
  has_many :folders,
    foreign_key: :user_uuid,
    inverse_of: :user,
    dependent: :destroy
  has_many :devices,
    foreign_key: :user_uuid,
    inverse_of: :user,
    dependent: :destroy

  def decrypt_data_with_master_password_key(data, mk)
    # self.key is random data encrypted with the key of (password,email), so
    # create that key and decrypt the random data to get the original
    # encryption key, then use that key to decrypt the data
    encKey = Bitwarden.decrypt(self.key, mk)
    Bitwarden.decrypt(data, encKey)
  end

  def encrypt_data_with_master_password_key(data, mk)
    # self.key is random data encrypted with the key of (password,email), so
    # create that key and decrypt the random data to get the original
    # encryption key, then use that key to encrypt the data
    encKey = Bitwarden.decrypt(self.key, mk)
    Bitwarden.encrypt(data, encKey)
  end

  def has_password_hash?(hash)
    self.password_hash.timingsafe_equal_to(hash)
  end

  def to_hash
    {
      "Id" => self.uuid,
      "Name" => self.name,
      "Email" => self.email,
      "EmailVerified" => self.email_verified,
      "Premium" => self.premium,
      "MasterPasswordHint" => self.password_hint,
      "Culture" => self.culture,
      "TwoFactorEnabled" => self.two_factor_enabled?,
      "Key" => self.key,
      "PrivateKey" => nil,
      "SecurityStamp" => self.security_stamp,
      "Organizations" => [],
      "Object" => "profile"
    }
  end

  def two_factor_enabled?
    self.totp_secret.present?
  end

  def update_master_password(old_pwd, new_pwd,
  new_kdf_iterations = self.kdf_iterations)
    # original random encryption key must be preserved, just re-encrypted with
    # a new key derived from the new password

    orig_key = Bitwarden.decrypt(self.key,
      Bitwarden.makeKey(old_pwd, self.email,
      Bitwarden::KDF::TYPES[self.kdf_type], self.kdf_iterations))

    self.key = Bitwarden.encrypt(orig_key,
      Bitwarden.makeKey(new_pwd, self.email,
      Bitwarden::KDF::TYPES[self.kdf_type], new_kdf_iterations)).to_s

    self.password_hash = Bitwarden.hashPassword(new_pwd, self.email,
      self.kdf_type, new_kdf_iterations)
    self.kdf_iterations = new_kdf_iterations
    self.security_stamp = SecureRandom.uuid
  end

  def verifies_totp_code?(code)
    ROTP::TOTP.new(self.totp_secret).now == code.to_s
  end

protected
  def generate_security_stamp
    if self.security_stamp.blank?
      self.security_stamp = SecureRandom.uuid
    end
  end
end
