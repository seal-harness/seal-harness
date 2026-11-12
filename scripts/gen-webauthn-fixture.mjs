#!/usr/bin/env node
// Generates the committed WebAuthn fixture corpus under
// test/fixtures/webauthn/.
//
// The point of this script is *independence*: the Haskell verifier is built on
// crypton, and the signatures / DER encoding here come from Node's WebCrypto,
// so the tests do not validate the implementation against itself. The script
// is kept for provenance and regeneration; the test suite reads the committed
// JSON and never runs Node.
//
// Run: node scripts/gen-webauthn-fixture.mjs

import { createHash, generateKeyPairSync, sign } from 'node:crypto'
import { writeFileSync, mkdirSync } from 'node:fs'

const RP_ID = 'localhost'
const ORIGIN = 'http://localhost:8080'
const CHALLENGE = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8' // 32 bytes
const CRED_ID = Buffer.from('f1c9a4d3b2e8076f5c4a39281d0b7e6a', 'hex') // 16 bytes

// ── Minimal CBOR writer (independent of the Haskell decoder) ────────────
const head = (major, n) => {
  if (n < 24) return Buffer.from([(major << 5) | n])
  if (n < 0x100) return Buffer.from([(major << 5) | 24, n])
  if (n < 0x10000) {
    const b = Buffer.alloc(3)
    b[0] = (major << 5) | 25
    b.writeUInt16BE(n, 1)
    return b
  }
  throw new Error('fixture: length too large')
}
const cborInt = (n) => (n >= 0 ? head(0, n) : head(1, -1 - n))
const cborBytes = (b) => Buffer.concat([head(2, b.length), b])
const cborText = (s) => {
  const b = Buffer.from(s, 'utf8')
  return Buffer.concat([head(3, b.length), b])
}
const cborMap = (pairs) =>
  Buffer.concat([head(5, pairs.length), ...pairs.flatMap(([k, v]) => [k, v])])

// ── Key material ────────────────────────────────────────────────────────
const { privateKey, publicKey } = generateKeyPairSync('ec', {
  namedCurve: 'prime256v1',
})
const jwk = publicKey.export({ format: 'jwk' })
const x = Buffer.from(jwk.x, 'base64url')
const y = Buffer.from(jwk.y, 'base64url')

const coseKey = cborMap([
  [cborInt(1), cborInt(2)], // kty: EC2
  [cborInt(3), cborInt(-7)], // alg: ES256
  [cborInt(-1), cborInt(1)], // crv: P-256
  [cborInt(-2), cborBytes(x)],
  [cborInt(-3), cborBytes(y)],
])

const sha256 = (b) => createHash('sha256').update(b).digest()

const authData = ({ flags, signCount, attested }) => {
  const fixed = Buffer.alloc(37)
  sha256(Buffer.from(RP_ID, 'utf8')).copy(fixed, 0)
  fixed[32] = flags
  fixed.writeUInt32BE(signCount, 33)
  if (!attested) return fixed
  const aaguid = Buffer.alloc(16)
  const len = Buffer.alloc(2)
  len.writeUInt16BE(CRED_ID.length, 0)
  return Buffer.concat([fixed, aaguid, len, CRED_ID, coseKey])
}

const assertionAuthData = authData({
  flags: 0x01 | 0x04, // UP | UV
  signCount: 2,
  attested: false,
})

const registrationAuthData = authData({
  flags: 0x01 | 0x04 | 0x40, // UP | UV | AT
  signCount: 1,
  attested: true,
})

const attestationObject = cborMap([
  [cborText('fmt'), cborText('none')],
  [cborText('attStmt'), cborMap([])],
  [cborText('authData'), cborBytes(registrationAuthData)],
])

const clientData = (type) =>
  Buffer.from(
    JSON.stringify({ type, challenge: CHALLENGE, origin: ORIGIN, crossOrigin: false }),
    'utf8',
  )

const regClientData = clientData('webauthn.create')
const asnClientData = clientData('webauthn.get')

// Node's classic sign() hashes once with SHA-256 and returns DER — exactly the
// construction WebAuthn specifies.
const message = Buffer.concat([assertionAuthData, sha256(asnClientData)])
const signatureDer = sign('sha256', message, { key: privateKey, dsaEncoding: 'der' })

const b64 = (b) => b.toString('base64url')

const fixture = {
  rp_id: RP_ID,
  origin: ORIGIN,
  challenge: CHALLENGE,
  credential_id: b64(CRED_ID),
  public_key: b64(Buffer.concat([x, y])),
  registration: {
    client_data_json: b64(regClientData),
    attestation_object: b64(attestationObject),
    authenticator_data: b64(registrationAuthData),
    raw_id: b64(CRED_ID),
  },
  assertion: {
    client_data_json: b64(asnClientData),
    authenticator_data: b64(assertionAuthData),
    signature: b64(signatureDer),
    sign_count: 2,
  },
}

mkdirSync('test/fixtures/webauthn', { recursive: true })
writeFileSync('test/fixtures/webauthn/ceremony.json', JSON.stringify(fixture, null, 2) + '\n')
console.log('wrote test/fixtures/webauthn/ceremony.json')
console.log('credential id:', b64(CRED_ID))
console.log('public key   :', b64(Buffer.concat([x, y])))
