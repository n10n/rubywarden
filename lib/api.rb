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

#
# helper methods
#

def device_from_bearer
  if m = request.env["HTTP_AUTHORIZATION"].to_s.match(/^Bearer (.+)/)
    token = m[1]
    if (d = Device.find_by_access_token(token))
      if d.token_expires_at >= Time.now
        return d
      end
    end
  end

  nil
end

def need_params(*ps)
  ps.each do |p|
    if params[p].to_s.blank?
      yield(p)
    end
  end
end

def validation_error(msg)
  [ 400, {
    "ValidationErrors" => { "" => [
      msg,
    ]},
    "Object" => "error",
  }.to_json ]
end

#
# begin sinatra routing
#

# import JSON params for every request
before do
  if request.content_type.to_s.match(/\Aapplication\/json(;|\z)/)
    js = request.body.read.to_s
    if !js.strip.blank?
      params.merge!(JSON.parse(js))
    end
  end

  # we're always going to reply with json
  content_type :json
end

namespace IDENTITY_BASE_URL do
  # depending on grant_type:
  #  password: login with a username/password, register/update the device
  #  refresh_token: just generate a new access_token
  # respond with an access_token and refresh_token
  post "/connect/token" do
    d = nil

    case params[:grant_type]
    when "refresh_token"
      need_params(:refresh_token) do |p|
        return validation_error("#{p} cannot be blank")
      end

      d = Device.find_by_refresh_token(params[:refresh_token])
      if !d
        return validation_error("Invalid refresh token")
      end

    when "password"
      need_params(
        :client_id,
        :grant_type,
        :deviceIdentifier,
        :deviceName,
        :deviceType,
        :password,
        :scope,
        :username,
      ) do |p|
        return validation_error("#{p} cannot be blank")
      end

      if params[:scope] != "api offline_access"
        return validation_error("scope not supported")
      end

      u = User.find_by_email(params[:username])
      if !u
        return validation_error("Invalid username")
      end

      if !u.has_password_hash?(params[:password])
        return validation_error("Invalid password")
      end

      if u.two_factor_enabled? &&
      (params[:twoFactorToken].blank? ||
      !u.verifies_totp_code?(params[:twoFactorToken]))
        return [ 400, {
          "error" => "invalid_grant",
          "error_description" => "Two factor required.",
          "TwoFactorProviders" => [ 0 ], # authenticator
          "TwoFactorProviders2" => { "0" => nil }
        }.to_json ]
      end

      d = Device.find_by_uuid(params[:deviceIdentifier])
      if d && d.user_uuid != u.uuid
        # wat
        d.destroy
        d = nil
      end

      if !d
        d = Device.new
        d.user_uuid = u.uuid
        d.uuid = params[:deviceIdentifier]
      end

      d.type = params[:deviceType]
      d.name = params[:deviceName]
      if params[:devicePushToken].present?
        d.push_token = params[:devicePushToken]
      end
    else
      return validation_error("grant type not supported")
    end

    d.regenerate_tokens!

    User.transaction do
      if !d.save
        return validation_error("Unknown error")
      end

      {
        :access_token => d.access_token,
        :expires_in => (d.token_expires_at - Time.now).floor,
        :token_type => "Bearer",
        :refresh_token => d.refresh_token,
        :Key => d.user.key,
        # TODO: when to include :privateKey and :TwoFactorToken?
      }.to_json
    end
  end
end

namespace BASE_URL do
  # create a new user
  post "/accounts/register" do
    content_type :json

    if !ALLOW_SIGNUPS
      return validation_error("Signups are not permitted")
    end

    need_params(:masterPasswordHash) do |p|
      return validation_error("#{p} cannot be blank")
    end

    if !params[:email].to_s.match(/^.+@.+\..+$/)
      return validation_error("Invalid e-mail address")
    end

    if !params[:key].to_s.match(/^0\..+\|.+/)
      return validation_error("Invalid key")
    end

    begin
      if !Bitwarden::CipherString.parse(params[:key])
        raise
      end
    rescue
      return validation_error("Invalid key")
    end

    User.transaction do
      params[:email].downcase!

      if User.find_by_email(params[:email])
        return validation_error("E-mail is already in use")
      end

      u = User.new
      u.email = params[:email]
      u.password_hash = params[:masterPasswordHash]
      u.password_hint = params[:masterPasswordHint]
      u.key = params[:key]

      # is this supposed to come from somewhere?
      u.culture = "en-US"

      # i am a fair and just god
      u.premium = true

      if !u.save
        return validation_error("User save failed")
      end

      ""
    end
  end

  # fetch profile and ciphers
  get "/sync" do
    d = device_from_bearer
    if !d
      return validation_error("invalid bearer")
    end

    {
      "Profile" => d.user.to_hash,
      "Folders" => [],
      "Ciphers" => d.user.ciphers.map{|c|
        c.to_hash
      },
      "Domains" => {
        "Object" => "domains"
      },
      "Object" => "sync"
    }.to_json
  end

  # create a new cipher
	post "/ciphers" do
    d = device_from_bearer
    if !d
      return validation_error("invalid bearer")
    end

    need_params(:type, :name) do |p|
      return validation_error("#{p} cannot be blank")
    end

    c = Cipher.new
    c.user_uuid = d.user_uuid
    c.update_from_params(params)

    Cipher.transaction do
      if !c.save
        return validation_error("error saving")
      end

      c.to_hash.merge({
        "Edit" => true,
      }).to_json
    end
  end

  # update a cipher
	put "/ciphers/:uuid" do
    d = device_from_bearer
    if !d
      return validation_error("invalid bearer")
    end

    c = nil
    if params[:uuid].blank? || !(c = Cipher.find_by_uuid(params[:uuid]))
      return validation_error("invalid cipher")
    end

    if c.user_uuid != d.user_uuid
      return validation_error("invalid cipher")
    end

    need_params(:type, :name) do |p|
      return validation_error("#{p} cannot be blank")
    end

    c.update_from_params(params)

    Cipher.transaction do
      if !c.save
        return validation_error("error saving")
      end

      c.to_hash.merge({
        "Edit" => true,
      }).to_json
    end
  end

  # delete a cipher
	delete "/ciphers/:uuid" do
    d = device_from_bearer
    if !d
      return validation_error("invalid bearer")
    end

    c = nil
    if params[:uuid].blank? || !(c = Cipher.find_by_uuid(params[:uuid]))
      return validation_error("invalid cipher")
    end

    if c.user_uuid != d.user_uuid
      return validation_error("invalid cipher")
    end

    c.destroy

    ""
  end
end

namespace ICONS_URL do
  get "/:domain/icon.png" do
    # TODO: do this service ourselves

    redirect "http://#{params[:domain]}/favicon.ico"
  end
end
