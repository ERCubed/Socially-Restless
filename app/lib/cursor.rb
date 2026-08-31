# Opaque pagination cursor encoding a (timestamp, id) position for keyset
# pagination. Callers should treat the encoded string as opaque; only this
# class needs to know its shape.
class Cursor
  DecodeError = Class.new(StandardError)

  def self.encode(timestamp, id)
    Base64.urlsafe_encode64("#{timestamp.utc.iso8601(6)}|#{id}")
  end

  # Returns nil for a blank/missing cursor (first page). Raises DecodeError
  # for a present-but-malformed cursor, since silently treating a corrupt
  # cursor as "start over" would make a client's broken pagination fail
  # silently rather than visibly.
  def self.decode(encoded)
    return nil if encoded.blank?

    timestamp_string, id_string = Base64.urlsafe_decode64(encoded).split("|", 2)
    timestamp = Time.zone.iso8601(timestamp_string)
    id = Integer(id_string)

    new(timestamp, id)
  rescue ArgumentError, TypeError
    raise DecodeError, "invalid pagination cursor"
  end

  attr_reader :timestamp, :id

  def initialize(timestamp, id)
    @timestamp = timestamp
    @id = id
  end
end
