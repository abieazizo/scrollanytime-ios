# Opens signing.enc into a folder. usage: ruby open.rb signing.enc outdir
# The file is: 12 bytes nonce, 16 bytes tag, then AES-256-GCM of a JSON object {name: base64}.
# The key is SHA-256 of "seder-signing:" + the App Store Connect key (base64, as the workflow holds it).
require 'openssl'
require 'json'
require 'base64'
require 'digest'

src, out = ARGV
secret = ENV.fetch('ASC_KEY_P8_BASE64').gsub(/\s+/, '')
key = Digest::SHA256.digest("seder-signing:#{secret}")
raw = File.binread(src)
cipher = OpenSSL::Cipher.new('aes-256-gcm').decrypt
cipher.key = key
cipher.iv = raw[0, 12]
cipher.auth_tag = raw[12, 16]
plain = cipher.update(raw[28..]) + cipher.final
JSON.parse(plain).each do |name, b64|
  raise "bad name #{name}" unless name =~ /\A[\w.-]+\z/
  File.binwrite(File.join(out, name), Base64.decode64(b64))
end
puts "opened #{src}"
