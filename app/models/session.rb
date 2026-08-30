class Session < ApplicationRecord
  belongs_to :user

  EXPIRATION_TIME = 24.hours

  validates :token_digest, presence: true, uniqueness: true
  validates :expires_at, presence: true

  # Raw bearer token, only ever available on the instance that just created it
  # (in memory, right after `start!`). We store only its digest, so a leaked
  # database dump can't be replayed as a valid session token, mirroring how
  # has_secure_password never persists a plaintext password.
  attr_reader :token

  def self.start!(user:, user_agent: nil, ip_address: nil)
    raw_token = SecureRandom.hex(32)

    session = create!(
      user: user,
      token_digest: digest(raw_token),
      user_agent: user_agent,
      ip_address: ip_address,
      expires_at: EXPIRATION_TIME.from_now
    )
    session.instance_variable_set(:@token, raw_token)
    session
  end

  def self.authenticate(raw_token)
    return nil if raw_token.blank?

    session = find_by(token_digest: digest(raw_token))
    return nil unless session
    return nil if session.expired?

    session
  end

  def expired?
    expires_at <= Time.current
  end

  def self.digest(raw_token)
    Digest::SHA256.hexdigest(raw_token)
  end
  private_class_method :digest
end
