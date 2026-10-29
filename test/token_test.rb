# frozen_string_literal: true

require "test_helper"

class TokenTest < Minitest::Test
  T = Cent::Token
  IAT = Time.at(1_700_000_000)
  EXP = Time.at(1_700_003_600)

  def hmac = T::Key.hmac("client_secret")
  def b64d(s) = (s + ("=" * ((4 - (s.size % 4)) % 4))).tr("-_", "+/").unpack1("m0")
  def ed = T::Key.ed25519(OpenSSL::PKey.generate_key("ED25519"))

  # The claims of a token, after checking its HS256 signature.
  def claims(token, secret = "client_secret")
    h, p, s = token.split(".")
    want = [OpenSSL::HMAC.digest("SHA256", secret, "#{h}.#{p}")].pack("m0").tr("+/", "-_").delete("=")

    assert_equal want, s
    [JSON.parse(b64d(h)), JSON.parse(b64d(p))]
  end

  def test_spec_token_vectors
    assert_equal "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9." \
                 "eyJzdWIiOiI0MiIsImV4cCI6MTcwMDAwMzYwMCwiaWF0IjoxNzAwMDAwMDAwfQ." \
                 "HKZwmcYmHVbRESuYd4swVgAH7gg41giR57F_K5FEmEY",
                 T.connection(hmac, user: "42", expires_at: EXP, issued_at: IAT)
    assert_equal "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9." \
                 "eyJzdWIiOiI0MiIsImV4cCI6MTcwMDAwMzYwMCwiaWF0IjoxNzAwMDAwMDAwLCJjaGFubmVsIjoibmV3cyJ9." \
                 "v_Quw-azNV1qFjm9ZQnkp6QBtK6LmtFxY74YcUHlJcA",
                 T.subscription(hmac, user: "42", channel: "news", expires_at: EXP, issued_at: IAT)
  end

  def test_spec_shared_poll_vectors
    assert_equal "1700000000:1700003600:c61dbf52085a6973537e71644fa30a3bbfc29a52d7ce9f1b7618531596ce587d",
                 Cent::SharedPoll.send(:sign_at, IAT, "shared_poll_secret", user: "42", channel: "poll:prices",
                                                                            keys: %w[AAPL GOOG], expires_at: EXP)
    assert_equal "1700000000:0:92dd64af5612afde06cad03bb63435d951e037cb55a087af05c2a1399abade0e",
                 Cent::SharedPoll.send(:sign_at, IAT, "shared_poll_secret", user: "", channel: "poll:prices", keys: [])
    assert_raises(Cent::Error) { Cent::SharedPoll.sign("", user: "", channel: "c", keys: []) }
  end

  def test_connection_claims_on_the_wire
    t = T.connection(hmac.with_key_id("k1"), user: "42", expires_at: EXP, issued_at: IAT, id: "j", audience: "a",
                                             issuer: "i", connection_expires_at: :never, info: { "n" => 1 },
                                             b64info: "AA==", subs: { "news" => { data: { x: 1 } } },
                                             meta: { plan: "pro" }, caps: [{ channels: ["c"], allow: ["sub"] }],
                                             labels: { "l" => "v" })
    header, c = claims(t)

    assert_equal({ "alg" => "HS256", "typ" => "JWT", "kid" => "k1" }, header)
    assert_equal %w[sub exp iat jti aud iss expire_at info b64info subs meta caps labels], c.keys
    assert_equal 0, c["expire_at"]
    assert_equal({ "news" => { "data" => { "x" => 1 } } }, c["subs"])
    assert_equal [{ "channels" => ["c"], "allow" => ["sub"] }], c["caps"]
  end

  def test_subscription_claims_on_the_wire
    t = T.subscription(hmac, user: "42", channel: "news", expires_at: EXP, issued_at: IAT,
                             subscription_expires_at: EXP + 60, data: [1], override: { presence: true },
                             allow: ["pub"], server_tags_filter: { key: "k", cmp: "eq", val: "v" })
    _, c = claims(t)

    assert_equal %w[sub exp iat channel expire_at data override allow server_tags_filter], c.keys
    assert_equal({ "presence" => { "value" => true } }, c["override"])
    assert_equal({ "key" => "k", "cmp" => "eq", "val" => "v" }, c["server_tags_filter"])
  end

  def test_expiry
    _, c = claims(T.connection(hmac, expires_at: :never))

    refute c.key?("exp")
    assert_in_delta Time.now.to_i, c["iat"], 2
    assert_equal "", c["sub"]
    assert_match(/expires_at is required/, assert_raises(T::Error) { T.connection(hmac, expires_at: nil) }.message)
    assert_raises(ArgumentError) { T.connection(hmac, user: "1") }
    assert_raises(T::Error) { T.connection(hmac, expires_at: "tomorrow") }
  end

  def test_claims_refused
    assert_match(/not both/,
                 assert_raises(T::Error) do
                   T.connection(hmac, expires_at: EXP, channels: ["a"], subs: { "b" => {} })
                 end.message)
    assert_raises(T::Error) { T.subscription(hmac, channel: "", expires_at: EXP) }
    assert_match(/token: info is NaN/,
                 assert_raises(Cent::InvalidRequestError) do
                   T.connection(hmac, expires_at: EXP, info: Float::NAN)
                 end.message)
    assert_raises(Cent::InvalidRequestError) { T.connection(hmac, expires_at: EXP, caps: [{ chan: ["a"] }]) }
  end

  def test_asymmetric_keys
    rsa = OpenSSL::PKey::RSA.new(2048)
    ec = OpenSSL::PKey::EC.generate("secp384r1")
    edk = OpenSSL::PKey.generate_key("ED25519")
    [[T::Key.rsa(rsa), rsa, "RS256"], [T::Key.ecdsa(ec), ec, "ES384"], [T::Key.ed25519(edk), edk, "EdDSA"],
     [T::Key.from_pem(rsa.private_to_pem), rsa, "RS256"], [T::Key.from_pem(edk.private_to_pem), edk, "EdDSA"]]
      .each do |key, pkey, alg|
      assert_equal alg, key.alg
      h, p, s = T.connection(key, user: "1", expires_at: EXP).split(".")
      sig = b64d(s)
      data = "#{h}.#{p}"
      ok = case alg
           when "RS256" then pkey.verify("SHA256", sig, data)
           when "ES384"
             assert_equal 96, sig.bytesize
             r, s = [sig[0, 48], sig[48, 48]].map { OpenSSL::BN.new(it, 2) }
             der = OpenSSL::ASN1::Sequence([OpenSSL::ASN1::Integer(r), OpenSSL::ASN1::Integer(s)]).to_der
             pkey.verify("SHA384", der, data)
           else pkey.verify(nil, sig, data)
           end

      assert ok, "#{alg} signature"
    end
  end

  def test_unsupported_keys
    assert_raises(T::Error) { T::Key.ecdsa(OpenSSL::PKey::EC.generate("secp256k1")) }
    assert_raises(T::Error) { T::Key.rsa(OpenSSL::PKey::RSA.new(2048).public_key) }
    assert_raises(T::Error) { T::Key.hmac("") }
    assert_raises(T::Error) { T::Key.from_pem("not a pem") }
    assert_raises(T::Error) { hmac.with_key_id("") }
  end

  def test_jwks
    ec = OpenSSL::PKey::EC.generate("prime256v1")
    rsa = OpenSSL::PKey::RSA.new(2048)
    edk = ed.with_key_id("e")
    keys = JSON.parse(T.jwks(T::Key.ecdsa(ec).with_key_id("c"), T::Key.rsa(rsa).with_key_id("r"), edk))["keys"]

    assert_equal(%w[c r e], keys.map { it["kid"] })
    assert(keys.all? { it["use"] == "sig" })
    c, r, e = keys

    assert_equal({ "kty" => "EC", "alg" => "ES256", "crv" => "P-256" }, c.slice("kty", "alg", "crv"))
    assert_equal 32, b64d(c["x"]).bytesize
    assert_equal rsa.n, OpenSSL::BN.new(b64d(r["n"]), 2)
    assert_equal({ "kty" => "OKP", "alg" => "EdDSA", "crv" => "Ed25519" }, e.slice("kty", "alg", "crv"))
  end

  def test_jwks_refused
    assert_raises(T::Error) { T.jwks }
    assert_raises(T::Error) { T.jwks(hmac.with_key_id("h")) }
    assert_raises(T::Error) { T.jwks(ed) }
    assert_raises(T::Error) { T.jwks(ed.with_key_id("a"), ed.with_key_id("a")) }
  end

  def test_api_token
    key = ed.with_key_id("api")
    t = T.api(key, audience: "centrifugo-api", scope: %w[centrifugo:api other], subject: "billing",
                   expires_at: EXP, issued_at: IAT)
    payload = JSON.parse(b64d(t.split(".")[1]))

    assert_equal({ "sub" => "billing", "exp" => 1_700_003_600, "iat" => 1_700_000_000, "aud" => "centrifugo-api",
                   "scope" => "centrifugo:api other" }, payload)
  end

  def test_api_token_refused
    key = ed.with_key_id("api")
    assert_raises(T::Error) { T.api(hmac.with_key_id("h"), audience: "a", expires_at: EXP) }
    assert_raises(T::Error) { T.api(ed, audience: "a", expires_at: EXP) }
    assert_raises(T::Error) { T.api(key, expires_at: EXP) }
    assert_raises(T::Error) { T.api(key, audience: "a", expires_at: :never) }
    assert_raises(T::Error) { T.api(key, scope: ["a b"], expires_at: EXP) }
    assert_raises(T::Error) { T.api(key, scope: [""], expires_at: EXP) }
  end

  def test_api_tokens_reused_for_half_the_ttl
    keys = [ed.with_key_id("one"), ed.with_key_id("two")]
    current = 0
    tokens = T::ApiTokens.new(current_key: -> { keys[current] }, audience: "a", ttl: 0.2)
    first = tokens.token

    assert_same first, tokens.token
    current = 1
    sleep 0.11
    second = tokens.token

    refute_equal first, second
    assert_equal "two", JSON.parse(b64d(second.split(".")[0]))["kid"]
    assert_equal [second], Array.new(4) { Thread.new { tokens.token } }.map(&:value).uniq
  end

  def test_api_tokens_refusals
    key = ed.with_key_id("k")
    assert_raises(T::Error) { T::ApiTokens.new(audience: "a") }
    assert_raises(T::Error) { T::ApiTokens.new(key:, current_key: -> { key }, audience: "a") }
    assert_raises(T::Error) { T::ApiTokens.new(key:, audience: "a", expires_at: EXP) }
    assert_raises(T::Error) { T::ApiTokens.new(key:, audience: "a", ttl: -1) }
    assert_raises(T::Error) { T::ApiTokens.new(key:, audince: "a") }
    assert_raises(T::Error) { T::ApiTokens.new(key:).token }
  end
end
