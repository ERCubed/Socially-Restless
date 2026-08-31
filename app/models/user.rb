class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy

  before_validation :normalize_email
  before_validation :normalize_username
  before_validation :normalize_name_fields

  EMAIL_FORMAT = URI::MailTo::EMAIL_REGEXP

  validates :username, presence: true, uniqueness: { case_sensitive: false },
                        length: { minimum: 3, maximum: 30 },
                        format: { with: /\A[a-zA-Z0-9_]+\z/, message: "can only contain letters, numbers, and underscores" }
  validates :email, presence: true, uniqueness: { case_sensitive: false },
                     format: { with: EMAIL_FORMAT, message: "must be a valid email address" }
  validates :password, length: { minimum: 8 }, allow_nil: true
  validates :first_name, length: { maximum: 50 }, allow_blank: true
  validates :last_name, length: { maximum: 50 }, allow_blank: true

  private

  def normalize_email
    self.email = email.strip.downcase if email.present?
  end

  def normalize_username
    self.username = username.strip if username.present?
  end

  def normalize_name_fields
    self.first_name = first_name.strip if first_name.present?
    self.last_name = last_name.strip if last_name.present?
  end
end
