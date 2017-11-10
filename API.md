## Bitwarden API Overview

Despite being open source, the
[.NET Bitwarden API code](https://github.com/bitwarden/core)
is somewhat difficult to navigate and comprehend from a high level,
and there is no formal documentation on API endpoints or how the
encryption and decryption is implemented.

The following notes were made by analyzing traffic between the Firefox
extension and the Bitwarden servers by running
[mitm.rb](mitm.rb)
and having the Firefox extension use `http://127.0.0.1:4567/` as its
base URL.

The details for key derivation and encryption/decryption were done by
reading the
[web extension](https://github.com/bitwarden/browser)
code.

### Password hashing and encryption key derivation

User enters a `$masterPassword` of `p4ssw0rd` and an `$email` of
`nobody@example.com`.

PBKDF2 is used with a password of `$masterPassword`, salt of lowercased
`$email`, and 5000 iterations to stretch password into `$internalKey`.

	def makeKey(password, salt)
	  PBKDF2.new(:password => password, :salt => salt,
	    :iterations => 5000, :hash_function => OpenSSL::Digest::SHA256,
	    :key_length => (256 / 8)).bin_string
	end

	irb> $internalKey = makeKey("p4ssw0rd", "nobody@example.com".downcase)
	=> "\x13\x88j`\x99m\xE3FA\x94\xEE'\xF0\xB2\x1A!\xB6>\\)\xF4\xD5\xCA#\xE5\e\xA6f5o{\xAA"

An IV `$iv` is created with 16 random bytes and `$internalKey` is used as the
key to encrypt 64 random bytes.
The first 32 bytes of the result become `$encKey` and the last 32 bytes become
`$macKey`.

A "CipherString" (a Bitwarden internal format) is created by joining the
[encryption type](https://github.com/bitwarden/browser/blob/f1262147a33f302b5e569f13f56739f05bbec362/src/services/constantsService.js#L13-L21)
(`0` for `AesCbc256_B64`), a dot, the Base64-encoded IV, and the Base64-encoded
`$encKey` and `$macKey`, with the pipe (`|`) character to become `$key`.

	def cipherString(enctype, iv, ct, mac)
	  [ enctype.to_s + "." + iv, ct, mac ].reject{|p| !p }.join("|")
	end

	# encrypt random bytes with a key to make new encryption key
	def makeEncKey(key)
	  pt = OpenSSL::Random.random_bytes(64)
	  iv = OpenSSL::Random.random_bytes(16)

	  cipher = OpenSSL::Cipher.new "AES-256-CBC"
	  cipher.encrypt
	  cipher.key = key
	  cipher.iv = iv
	  ct = cipher.update(pt)
	  ct << cipher.final

	  return cipherString(0, Base64.strict_encode64(iv), Base64.strict_encode64(ct), nil)
	end

	irb> $key = makeEncKey($internalKey)
	=> "0.uRcMe+Mc2nmOet4yWx9BwA==|PGQhpYUlTUq/vBEDj1KOHVMlTIH1eecMl0j80+Zu0VRVfFa7X/MWKdVM6OM/NfSZicFEwaLWqpyBlOrBXhR+trkX/dPRnfwJD2B93hnLNGQ="

This is now the main key associated with the user and sent to the server upon
account creation, and sent back to the device upon sync.

An additional hash of the stretched password becomes `$masterPasswordHash`
and is also sent to the server upon account creation and login, to actually
verify the user account.
This hash is created with 1 round of PBKDF2 over a password of
`$internalKey` (which itself was created by 5000 rounds of (`$masterPassword`,
`$email`)) and salt of `$masterPassword`.

	# base64-encode a wrapped, stretched password+salt for signup/login
	def hashedPassword(password, salt)
	  key = makeKey(password, salt)
	  Base64.strict_encode64(PBKDF2.new(:password => key, :salt => password,
	    :iterations => 1, :key_length => 256/8,
	    :hash_function => OpenSSL::Digest::SHA256).bin_string)
	end

	irb> $masterPasswordHash = hashedPassword("p4ssw0rd", "nobody@example.com")
	=> "r5CFRR+n9NQI8a525FY+0BPR0HGOjVJX0cR1KEMnIOo="

Upon future logins with the user's plain-text `$masterPassword` and `$email`,
`$internalKey` can be calculated from them and then `$masterPassword` should
be cleared from memory.
`$internalKey` becomes the key used to build the encryption and MAC keys used
for individual encryption/decryption of items, and should never leave the
device.

### "Cipher" encryption and decryption

Bitwarden refers to individual items (site logins, secure notes, credit cards,
etc.) as "cipher" objects, with its
[type](https://github.com/bitwarden/browser/blob/f1262147a33f302b5e569f13f56739f05bbec362/src/services/constantsService.js#L22-L27)
value indicating what it is.
Each cipher has a number of key/value pairs, with some values being encrypted:

	{
		"type": 1,
		"folderId": null,
		"organizationId": null,
		"name":"2.zAgCKbTvGowtaRn1er5WGA==|oVaVLIjfBQoRr5EvHTwfhQ==|lHSTUO5Rgfkjl3J/zGJVRfL8Ab5XrepmyMv9iZL5JBE=",
		"notes":"2.NLkXMHtgR8u9azASR4XPOQ==|6/9QPcnoeQJDKBZTjcBAjVYJ7U/ArTch0hUSHZns6v8=|p55cl9FQK/Hef+7yzM7Cfe0w07q5hZI9tTbxupZepyM=",
		"favorite": false,
		"login": {
			"uri": "2.6DmdNKlm3a+9k/5DFg+pTg==|7q1Arwz/ZfKEx+fksV3yo0HMQdypHJvyiix6hzgF3gY=|7lSXqjfq5rD3/3ofNZVpgv1ags696B2XXJryiGjDZvk=",
			"username": "2.4Dwitdv4Br85MABzhMJ4hg==|0BJtHtXbfZWwQXbFcBn0aA==|LM4VC+qNpezmub1f4l1TMLDb9g/Q+sIis2vDbU32ZGA=",
			"password": "2.OOlWRBGib6G8WRvBOziKzQ==|Had/obAdd2/6y4qzM1Kc/A==|LtHXwZc5PkiReFhkzvEHIL01NrsWGvintQbmqwxoXSI=",
			"totp": null
		}
	}

The values for `name`, `notes`, `login.uri`, `login.username`, and
`login.password` are each encrypted as "CipherString" values, with the
leading `2` indicating its type (`AesCbc256_HmacSha256_B64`).

To decrypt a value, the CipherString must be broken up into its IV, cipher
text, and MAC, then each part Base64-decoded.  The MAC is calculated using
`$macKey` and securely compared to the presented MAC, and if equal, the cipher
text is then decrypted using `$encKey`:

	# compare two hmacs, with double hmac verification
	# https://www.nccgroup.trust/us/about-us/newsroom-and-events/blog/2011/february/double-hmac-verification/
	def macsEqual(macKey, mac1, mac2)
	  hmac1 = OpenSSL::HMAC.digest(OpenSSL::Digest.new("SHA256"), macKey, mac1)
	  hmac2 = OpenSSL::HMAC.digest(OpenSSL::Digest.new("SHA256"), macKey, mac2)
	  return hmac1 == hmac2
	end

	# decrypt a CipherString and return plaintext
	def decrypt(str, key, macKey)
	  if str[0].to_i != 2
	    raise "implement #{str[0].to_i} decryption"
	  end

	  # AesCbc256_HmacSha256_B64
	  iv, ct, mac = str[2 .. -1].split("|", 3)

	  iv = Base64.decode64(iv)
	  ct = Base64.decode64(ct)
	  mac = Base64.decode64(mac)

	  cmac = OpenSSL::HMAC.digest(OpenSSL::Digest.new("SHA256"), macKey, iv + ct)
	  if !macsEqual(macKey, mac, cmac)
	    raise "invalid mac"
	  end

	  cipher = OpenSSL::Cipher.new "AES-256-CBC"
	  cipher.decrypt
	  cipher.iv = iv
	  cipher.key = key
	  pt = cipher.update(ct)
	  pt << cipher.final
	  pt
	end

	irb> decrypt("2.6DmdNKlm3a+9k/5DFg+pTg==|7q1Arwz/ZfKEx+fksV3yo0HMQdypHJvyiix6hzgF3gY=|7lSXqjfq5rD3/3ofNZVpgv1ags696B2XXJryiGjDZvk=", $encKey, $macKey)
	=> "https://example.com/login"

Encryption of a value is done by generating a random 16-byte IV `$iv` and
using the key `$encKey` to encrypt the text to `$cipherText`.
The MAC `$mac` is computed over `($iv + $cipherText)`.
`$iv`, `$cipherText`, and `$mac` are each Base64-encoded, joined by a pipe
(`|`) character, and then appended to the type (`2`) and a dot to form a
CipherString.

	# encrypt+mac a value with a key and mac key and random iv, return cipherString
	def encrypt(pt, key, macKey)
	  iv = OpenSSL::Random.random_bytes(16)

	  cipher = OpenSSL::Cipher.new "AES-256-CBC"
	  cipher.encrypt
	  cipher.key = key
	  cipher.iv = iv
	  ct = cipher.update(pt)
	  ct << cipher.final

	  mac = OpenSSL::HMAC.digest(OpenSSL::Digest.new("SHA256"), macKey, iv + ct)

	  cipherString(2, Base64.strict_encode64(iv), Base64.strict_encode64(ct), Base64.strict_encode64(mac))
	end

	irb> encrypt("A secret note here...", $encKey, $macKey)
	=> "2.NLkXMHtgR8u9azASR4XPOQ==|6/9QPcnoeQJDKBZTjcBAjVYJ7U/ArTch0hUSHZns6v8=|p55cl9FQK/Hef+7yzM7Cfe0w07q5hZI9tTbxupZepyM="

## API

### URLs

By default, BitWarden uses three different subdomains of `bitwarden.com`, one
as the `$baseURL` which does most API operations, one as the `$identityURL`
which handles logins (but not signups for some reason) and issues OAuth tokens,
and an `$iconURL` which just fetches, caches, and serves requests for site
icons.

When configuring a self-hosted environment in the device apps before logging
in, all three of these are assumed to be the same URL.

### Signup

Collect an e-mail address and master password, calculate `$internalKey`,
`$masterPasswordHash`, and the `$key` CipherString from the two values:

	irb> $internalKey = makeKey("p4ssw0rd", "nobody@example.com".downcase)
	=> "\x13\x88j`\x99m\xE3FA\x94\xEE'\xF0\xB2\x1A!\xB6>\\)\xF4\xD5\xCA#\xE5\e\xA6f5o{\xAA"

	irb> $masterPasswordHash = hashedPassword("p4ssw0rd", "nobody@example.com")
	=> "r5CFRR+n9NQI8a525FY+0BPR0HGOjVJX0cR1KEMnIOo="

	irb> $key = makeEncKey($internalKey)
	=> "0.uRcMe+Mc2nmOet4yWx9BwA==|PGQhpYUlTUq/vBEDj1KOHVMlTIH1eecMl0j80+Zu0VRVfFa7X/MWKdVM6OM/NfSZicFEwaLWqpyBlOrBXhR+trkX/dPRnfwJD2B93hnLNGQ="

Securely erase `$masterPassword` from memory, as it is no longer needed until
the next login.

Issue a `POST` to `$baseURL/accounts/register` with a JSON body containing the
e-mail address, `$masterPasswordHash`, and `$key` (_not $internalKey_!):

	POST $baseURL/accounts/register
	Content-type: application/json

	{
		"name": null,
		"email": "nobody@example.com",
		"masterPasswordHash": "r5CFRR+n9NQI8a525FY+0BPR0HGOjVJX0cR1KEMnIOo=",
		"masterPasswordHint": null,
		"key": "0.uRcMe+Mc2nmOet4yWx9BwA==|PGQhpYUlTUq/vBEDj1KOHVMlTIH1eecMl0j80+Zu0VRVfFa7X/MWKdVM6OM/NfSZicFEwaLWqpyBlOrBXhR+trkX/dPRnfwJD2B93hnLNGQ=",
	}

The response should be a `200` with a zero-byte body.

### Login

Collect an e-mail address and master password, and calculate
`$internalKey` and `$masterPasswordHash` from the two values:

	irb> $internalKey = makeKey("p4ssw0rd", "nobody@example.com".downcase)
	=> "\x13\x88j`\x99m\xE3FA\x94\xEE'\xF0\xB2\x1A!\xB6>\\)\xF4\xD5\xCA#\xE5\e\xA6f5o{\xAA"

	irb> $masterPasswordHash = hashedPassword("p4ssw0rd", "nobody@example.com")
	=> "r5CFRR+n9NQI8a525FY+0BPR0HGOjVJX0cR1KEMnIOo="

Securely erase the master password from memory, as it is no longer needed
until the next login.

Issue a `POST` to `$identityURL/connect/token` (not `$baseURL` which may be
different).

The `deviceIdentifier` is a random UUID generated by the device and remains
constant across logins.
`deviceType` is `2`
[for Firefox](https://github.com/bitwarden/core/blob/c9a2e67d0965fd046a0b3099e9511c26f0201acd/src/Core/Enums/DeviceType.cs).

	POST $identityURL/connect/token
	Content-type: application/x-www-form-urlencoded

	{
		"grant_type": "password",
		"username": "nobody@example.com",
		"password": "r5CFRR+n9NQI8a525FY+0BPR0HGOjVJX0cR1KEMnIOo=",
		"scope": "api offline_access",
		"client_id": "browser",
		"deviceType": 3
		"deviceIdentifier": "aac2e34a-44db-42ab-a733-5322dd582c3d",
		"deviceName": "firefox",
		"devicePushToken": ""
	}

A successful login will have a `200` status and a JSON response:

	{
		"access_token": "eyJhbGciOiJSUzI1NiIsImtpZCI6IkJDMz[...](JWT string)",
		"expires_in": 3600,
		"token_type": "Bearer",
		"refresh_token": "28fb1911ef6db24025ce1bae5aa940e117eb09dfe609b425b69bff73d73c03bf",
		"Key": "0.uRcMe+Mc2nmOet4yWx9BwA==|PGQhpYUlTUq/vBEDj1KOHVMlTIH1eecMl0j80+Zu0VRVfFa7X/MWKdVM6OM/NfSZicFEwaLWqpyBlOrBXhR+trkX/dPRnfwJD2B93hnLNGQ=",
	}

If 2FA is enabled on the account (which has to be done through the Bitwarden
website for bitwarden.com accounts, or some other mechanism for private
accounts), the return status will be `400` and the JSON response will contain
a non-empty `TwoFactorProviders` array containing the
[provider IDs](https://github.com/bitwarden/browser/blob/f1262147a33f302b5e569f13f56739f05bbec362/src/services/constantsService.js#L33-L40)
of available services:

	{
		"error": "invalid_grant",
		"error_description": "Two factor required.",
		"TwoFactorProviders": [ 0 ],
		"TwoFactorProviders2": { "0" : null }
	}

The Bitwarden apps will prompt for the 2FA token, and then attempt to login
again to `$identityURL/connect/token` with the `twoFactorProvider` and
`twoFactorToken` values filled out:

	POST $identityURL/connect/token
	Content-type: application/x-www-form-urlencoded

	{
		"grant_type": "password",
		"username": "nobody@example.com",
		"password": "r5CFRR+n9NQI8a525FY+0BPR0HGOjVJX0cR1KEMnIOo=",
		"scope": "api offline_access",
		"client_id": "browser",
		"deviceType": 3,
		"deviceIdentifier": "aac2e34a-44db-42ab-a733-5322dd582c3d",
		"deviceName": "firefox",
		"devicePushToken": ""
		"twoFactorToken": "123456",
		"twoFactorProvider": 0,
		"twoFactorRemember": 1,
	}

Upon successful login to an account with 2FA, additional `PrivateKey` and
`TwoFactorToken` values are sent, but I'm not sure what these are for.

	{
		"access_token": "eyJhbGciOiJSUzI1NiIsImtpZCI6IkJDMz[...](JWT string)",
		"expires_in": 3600,
		"token_type": "Bearer",
		"refresh_token": "28fb1911ef6db24025ce1bae5aa940e117eb09dfe609b425b69bff73d73c03bf",
		"PrivateKey": "2.WAfJirrIw2vPRIYZn/IadA==|v/PLyfn3P1YKDdbRCd+40k3Z[...](very long CipherString)",
		"Key": "0.uRcMe+Mc2nmOet4yWx9BwA==|PGQhpYUlTUq/vBEDj1KOHVMlTIH1eecMl0j80+Zu0VRVfFa7X/MWKdVM6OM/NfSZicFEwaLWqpyBlOrBXhR+trkX/dPRnfwJD2B93hnLNGQ=",
		"TwoFactorToken": "CfDJ8MXkSBvqpelMmq7HvH8L8fsvRsCETUwZQeOOXh21leQs2PmyuvuxdlhT95S+Otmn63gl6FNqLDL2gCqSNB+fHWTqdlX38GSWvGJimuAUeLu3Xgrd2Y0bEzjoBW+3YV4mHJPGwIu/2CaWZl6JW4F229x8fwYbPhRADczligiG1EFxbFswRwmZqmSny5o0VgKUHLIiSDfl2elHYzVpkkKYBoysX9pQ1NoYa7IJJReaWYoP"
	}

The `access_token`, `refresh_token`, and `expires_in` values must be stored
and used for further API access.
`$access_token` must be a
[JWT](https://jwt.io/)
string, which the browser extension decodes and parses, and must have at least
`nbf`, `exp`, `iss`, `sub`, `email`, `name`, `premium`, and `iss` keys.
`$access_token` is sent as the `Authentication` header for up to `$expires_in`
seconds, after which the `$refresh_token` will need to be sent back to the
identity server to get a new `$access_token`.

### Sync

The main action of the client is a one-way sync, which just fetches all
objects from the server and updates its local database.

Issue a `GET` to `$baseURL/sync` with an `Authorization` header of the
`$access_token`.

	GET $baseURL/sync
	Authorization: Bearer eyJhbGciOiJSUzI1NiIsImtpZCI6IkJDMz(rest of $access_token)

A successful response will contain a JSON body with `Profile`, `Folders`,
`Ciphers`, and `Domains` objects.

	{
		"Profile": {
			"Id": "0fbfc68d-ba11-416a-ac8a-a82600f0e601",
			"Name": null,
			"Email": "nobody@example.com",
			"EmailVerified": false,
			"Premium": false,
			"MasterPasswordHint": null,
			"Culture": "en-US",
			"TwoFactorEnabled": false,
			"Key": "0.uRcMe+Mc2nmOet4yWx9BwA==|PGQhpYUlTUq/vBEDj1KOHVMlTIH1eecMl0j80+Zu0VRVfFa7X/MWKdVM6OM/NfSZicFEwaLWqpyBlOrBXhR+trkX/dPRnfwJD2B93hnLNGQ=",
			"PrivateKey": null,
			"SecurityStamp": "5d203c3f-bc89-499e-85c4-4431248e1196",
			"Organizations": [
			],
			"Object": "profile"
		},
		"Folders": [
		],
		"Ciphers": [
			{
				"FolderId": null,
				"Favorite": false,
				"Edit": true,
				"Id": "0f01a66f-7802-42bc-9647-a82600f11e10",
				"OrganizationId": null,
				"Type":1,
				"Data":{
					"Uri": "2.6DmdNKlm3a+9k/5DFg+pTg==|7q1Arwz/ZfKEx+fksV3yo0HMQdypHJvyiix6hzgF3gY=|7lSXqjfq5rD3/3ofNZVpgv1ags696B2XXJryiGjDZvk=",
					"Username": "2.4Dwitdv4Br85MABzhMJ4hg==|0BJtHtXbfZWwQXbFcBn0aA==|LM4VC+qNpezmub1f4l1TMLDb9g/Q+sIis2vDbU32ZGA=",
					"Password":"2.OOlWRBGib6G8WRvBOziKzQ==|Had/obAdd2/6y4qzM1Kc/A==|LtHXwZc5PkiReFhkzvEHIL01NrsWGvintQbmqwxoXSI=",
					"Totp":null,
					"Name": "2.zAgCKbTvGowtaRn1er5WGA==|oVaVLIjfBQoRr5EvHTwfhQ==|lHSTUO5Rgfkjl3J/zGJVRfL8Ab5XrepmyMv9iZL5JBE=",
					"Notes": "2.NLkXMHtgR8u9azASR4XPOQ==|6/9QPcnoeQJDKBZTjcBAjVYJ7U/ArTch0hUSHZns6v8=|p55cl9FQK/Hef+7yzM7Cfe0w07q5hZI9tTbxupZepyM=",
					"Fields": null
				},
				"Attachments": null,
				"OrganizationUseTotp": false,
				"RevisionDate": "2017-11-09T14:37:52.9033333",
				"Object":"cipher"
			}
		],
		"Domains": {
			"EquivalentDomains": null,
			"GlobalEquivalentDomains": [
				{
					"Type": 2,
					"Domains": [
						"ameritrade.com",
						"tdameritrade.com"
					],
					"Excluded": false
				},
				[...]
			],
			"Object": "domains"
		},
		"Object": "sync"
	}

### Token Refresh

After `$expires_in` seconds of login (or last refresh), the `$access_token`
expires and has to be refreshed.
Send a `POST` request to the identity server with the `$refresh_token` and
get a new `$access_token` in return.

	POST $identityURL/connect/token
	Content-type: application/x-www-form-urlencoded

	{
		"grant_type": "refresh_token",
		"client_id": "browser",
		"refresh_token": "28fb1911ef6db24025ce1bae5aa940e117eb09dfe609b425b69bff73d73c03bf",
	}

A successful response will contain a JSON body with a new `$access_token`
and the same `$refresh_token`.

	{
		"access_token": "(new access token)",
		"expires_in": 3600,
		"token_type": "Bearer",
		"refresh_token": "28fb1911ef6db24025ce1bae5aa940e117eb09dfe609b425b69bff73d73c03bf",
	}

### Saving a new item

When a new item (login, secure note, etc.) is created on a device, it is
sent to the server via a `POST` to `$baseURL/ciphers`:

	POST $baseURL/ciphers
	Content-type: application/json
	Authorization: Bearer $access_token

	{
		"type": 1,
		"folderId": null,
		"organizationId": null,
		"name": "2.d7MttWzJTSSKx1qXjHUxlQ==|01Ath5UqFZHk7csk5DVtkQ==|EMLoLREgCUP5Cu4HqIhcLqhiZHn+NsUDp8dAg1Xu0Io=",
		"notes": null,
		"favorite": false,
		"login": {
			"uri": "2.T57BwAuV8ubIn/sZPbQC+A==|EhUSSpJWSzSYOdJ/AQzfXuUXxwzcs/6C4tOXqhWAqcM=|OWV2VIqLfoWPs9DiouXGUOtTEkVeklbtJQHkQFIXkC8=",
			"username": "2.JbFkAEZPnuMm70cdP44wtA==|fsN6nbT+udGmOWv8K4otgw==|JbtwmNQa7/48KszT2hAdxpmJ6DRPZst0EDEZx5GzesI=",
			"password": "2.e83hIsk6IRevSr/H1lvZhg==|48KNkSCoTacopXRmIZsbWg==|CIcWgNbaIN2ix2Fx1Gar6rWQeVeboehp4bioAwngr0o=",
			"totp": null
		}
	}

With no errors, the server will send back a JSON response with the
cipher data:

	{
		"FolderId": null,
		"Favorite": false,
		"Edit": true,
		"Id": "4c2869dd-0e1c-499f-b116-a824016df251",
		"OrganizationId": null,
		"Type": 1,
		"Data": {
			"Uri": "2.T57BwAuV8ubIn/sZPbQC+A==|EhUSSpJWSzSYOdJ/AQzfXuUXxwzcs/6C4tOXqhWAqcM=|OWV2VIqLfoWPs9DiouXGUOtTEkVeklbtJQHkQFIXkC8=",
			"Username": "2.JbFkAEZPnuMm70cdP44wtA==|fsN6nbT+udGmOWv8K4otgw==|JbtwmNQa7/48KszT2hAdxpmJ6DRPZst0EDEZx5GzesI=",
			"Password": "2.e83hIsk6IRevSr/H1lvZhg==|48KNkSCoTacopXRmIZsbWg==|CIcWgNbaIN2ix2Fx1Gar6rWQeVeboehp4bioAwngr0o=",
			"Totp": null,
			"Name": "2.d7MttWzJTSSKx1qXjHUxlQ==|01Ath5UqFZHk7csk5DVtkQ==|EMLoLREgCUP5Cu4HqIhcLqhiZHn+NsUDp8dAg1Xu0Io=",
			"Notes": null,
			"Fields": null
		},
		"Attachments": null,
		"OrganizationUseTotp": false,
		"RevisionDate": "2017-11-07T22:12:22.235914Z",
		"Object": "cipher"
	}

### Icons

Each login cipher can show an icon (favicon) for its URL, which is fetched via
Bitwarden's servers (presumably for caching).

To fetch an icon for a URL, issue an unauthenticated `GET` to
`$iconURL/(domain)/icon.png`:

	GET $iconURL/google.com/icon.png
	(no authentication header)

The binary response will contain the icon.

### Updating an item

Send a `PUT` request to `$baseURL/ciphers/(cipher UUID)`:

	PUT $baseURL/ciphers/(cipher UUID)
	Content-type: application/json
	Authorization: Bearer $access_token

	{
		"type": 2,
		"folderId": null,
		"organizationId": null,
		"name": "2.G38TIU3t1pGOfkzjCQE7OQ==|Xa1RupttU7zrWdzIT6oK+w==|J3C6qU1xDrfTgyJD+OrDri1GjgGhU2nmRK75FbZHXoI=",
		"notes": "2.rSw0uVQEFgUCEmOQx0JnDg==|MKqHLD25aqaXYHeYJPH/mor7l3EeSQKsI7A/R+0bFTI=|ODcUScISzKaZWHlUe4MRGuTT2S7jpyDmbOHl7d+6HiM=",
		"favorite": true,
		"secureNote":{
			"type": 0
		}
	}

The JSON response will be the same as when creating a new item.

### Deleting an item

Send an empty `DELETE` request to `$baseURL/ciphers/(cipher UUID)`:

	DELETE $baseURL/ciphers/(cipher UUID)
	Authorization: Bearer (access_token)

A successful but zero-length response will be returned.