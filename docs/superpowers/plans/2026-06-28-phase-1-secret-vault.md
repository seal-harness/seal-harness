# Phase 1 — Security Foundation + Secret Vault — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking. Also load the repo's `haskell-coder`
> skill before writing any Haskell.

**Goal:** Establish the security floor every later phase imports — opaque
secret types that cannot leak, a crypto seam, and an `age`-backed encrypted
vault — plus the pure path/command/policy primitives, all under `Seal.Security.*`.

**Architecture:** Capability-handle pattern (records of `IO` functions), no
type classes for the vault. Secrets are opaque newtypes with redacted `Show`
and no serialization instances, accessed only via CPS continuations. The vault
delegates encryption to a swappable `VaultEncryptor` handle: the real one shells
out to `age`; tests use an in-process mock, so the suite needs no binary.

**Tech Stack:** `crypton` + `memory` (AES-256-CTR, SHA-256, constant-time eq),
`base64-bytestring` (vault value encoding), `typed-process` (the `age`
subprocess), `unix` (`setFileMode`), `directory`/`filepath` (atomic rename),
`stm` + `MVar` (vault concurrency), `hspec` + `QuickCheck` + `temporary`
(tests).

## Global Constraints

Inherited from `2026-06-28-seal-harness-roadmap.md` → **Global Constraints**.
The load-bearing ones for this phase:

- **Clean-room:** no reference to any upstream repo/product, anywhere.
- **Namespace:** all modules under `Seal.Security.*` (and `Seal.Core.Errors`).
- **Style:** GHC2021; extensions `OverloadedStrings, LambdaCase,
  DerivingStrategies, DeriveGeneric, GeneralizedNewtypeDeriving,
  ImportQualifiedPost, ScopedTypeVariables, TupleSections`; post-positive
  qualified imports.
- **Flags:** `-Wall -Werror` + strict warning set. Build stays green.
- **No secret serialized / shown.** Redacted `Show`, no JSON, CPS access only.
- **TDD + QuickCheck** for pure security functions. **hlint clean** per commit.
- **Verify in the Nix dev shell.** One commit per task with the project trailer.

---

## File Structure

| File | Responsibility |
|---|---|
| `seal-harness.cabal` | Settle language/extensions/warnings; add deps; register new modules + test modules. |
| `src/Seal/Core/Errors.hs` | `CryptoError` and the shared `PublicError` channel type (minimal here; grows later). |
| `src/Seal/Security/Secrets.hs` | Opaque secret newtypes, smart constructors, CPS accessors. |
| `src/Seal/Security/Crypto.hs` | Random bytes, SHA-256 hex, constant-time eq, token gen, AES-256-CTR encrypt/decrypt. |
| `src/Seal/Security/Vault/Age.hs` | `VaultError`, `VaultEncryptor` handle, real `age` shell-out, mocks. |
| `src/Seal/Security/Vault.hs` | `VaultHandle`, `openVault`, all vault operations, unlock modes, atomic write, rekey. |
| `src/Seal/Security/Path.hs` | `SafePath` opaque type + `mkSafePath` workspace confinement. |
| `src/Seal/Security/Policy.hs` | Pure `SecurityPolicy`, allow-list predicates. |
| `src/Seal/Security/Command.hs` | `AuthorizedCommand` proof type + `authorize`/`authorizeShell`. |
| `test/Seal/Security/*Spec.hs` | One spec per module above. |
| `test/Main.hs` | Aggregate the new specs. |

Tasks are ordered by dependency: each builds only on earlier ones.

---

### Task 0: Settle project conventions and `Seal.Core.Errors`

Folds the cabal/style setup into the first real module so it is exercised
immediately.

**Files:**
- Modify: `seal-harness.cabal`
- Create: `src/Seal/Core/Errors.hs`
- Test: `test/Seal/Core/ErrorsSpec.hs`
- Modify: `test/Main.hs`

**Interfaces:**
- Produces: `data CryptoError = BadKeyLength | BadInitVector | ShortCiphertext`
  (`deriving stock (Eq, Show)`); `data PublicError = TemporaryError Text |
  RateLimitError | NotAllowedError` (`deriving stock (Eq, Show)`); class
  `ToPublicError e where toPublicError :: e -> PublicError`.

- [ ] **Step 1: Update the cabal `common` stanza and dependencies.**

In `seal-harness.cabal`, replace the `common warnings` block and the library's
`default-language`/`default-extensions`/`build-depends` so all components share
GHC2021 + strict warnings, and add this phase's dependencies:

```cabal
common settings
    default-language: GHC2021
    default-extensions:
        OverloadedStrings
        LambdaCase
        DerivingStrategies
        DeriveGeneric
        GeneralizedNewtypeDeriving
        ImportQualifiedPost
        ScopedTypeVariables
        TupleSections
    ghc-options:
        -Wall -Werror
        -Wincomplete-uni-patterns
        -Wincomplete-record-updates
        -Wname-shadowing
        -Wredundant-constraints
```

Point `library`, `executable seal`, and `test-suite tests` at
`import: settings` (replacing `import: warnings`). Add to the **library**
`build-depends`: `base16-bytestring` is **not** needed (we use `memory`'s
`convertToBase`); add `bytestring`, `base64-bytestring`, `crypton`, `memory`,
`typed-process`, `unix`, `directory`, `filepath`, `stm`. Add to the **test**
`build-depends`: `QuickCheck`, `temporary`, `bytestring`, `text`, `containers`.
Register `Seal.Core.Errors` under library `exposed-modules` and
`Seal.Core.ErrorsSpec` under the test suite's `other-modules`.

- [ ] **Step 2: Write the failing test.**

`test/Seal/Core/ErrorsSpec.hs`:

```haskell
module Seal.Core.ErrorsSpec (spec) where

import Test.Hspec
import Seal.Core.Errors

data Boom = Boom

instance ToPublicError Boom where
  toPublicError _ = NotAllowedError

spec :: Spec
spec = describe "Seal.Core.Errors" $
  it "maps a domain error to a PublicError without leaking detail" $
    toPublicError Boom `shouldBe` NotAllowedError
```

Wire it into `test/Main.hs`:

```haskell
module Main (main) where

import Test.Hspec
import qualified Seal.Core.ErrorsSpec
import qualified Seal.ConfigSpec

main :: IO ()
main = hspec $ do
  Seal.Core.ErrorsSpec.spec
  Seal.ConfigSpec.spec
```

- [ ] **Step 3: Run it; expect failure.**

Run: `nix develop --command cabal test 2>&1 | tail -20`
Expected: FAIL — `Could not find module 'Seal.Core.Errors'`.

- [ ] **Step 4: Implement `Seal.Core.Errors`.**

```haskell
module Seal.Core.Errors
  ( CryptoError (..)
  , PublicError (..)
  , ToPublicError (..)
  ) where

import Data.Text (Text)

-- | Failures from symmetric crypto in "Seal.Security.Crypto".
data CryptoError
  = BadKeyLength    -- ^ key was not the 32 bytes AES-256 requires
  | BadInitVector   -- ^ could not construct a valid 16-byte IV
  | ShortCiphertext -- ^ ciphertext shorter than the IV it must carry
  deriving stock (Eq, Show)

-- | The only error shape that may cross the boundary to a human/channel.
-- Carries no internal detail (no model names, URLs, paths, or stack traces).
data PublicError
  = TemporaryError Text
  | RateLimitError
  | NotAllowedError
  deriving stock (Eq, Show)

-- | Project domain errors implement this to redact themselves before display.
class ToPublicError e where
  toPublicError :: e -> PublicError
```

- [ ] **Step 5: Run tests + hlint; expect pass/clean.**

Run: `nix develop --command cabal test 2>&1 | tail -20`
Expected: PASS (2 example groups).
Run: `nix develop --command hlint src/ test/`
Expected: `No hints`.

- [ ] **Step 6: Commit.**

```bash
git add seal-harness.cabal src/Seal/Core/Errors.hs test/Seal/Core/ErrorsSpec.hs test/Main.hs
git commit -m "Settle project conventions and add Seal.Core.Errors"
```

---

### Task 1: `Seal.Security.Secrets` — opaque, unleakable secret types

**Files:**
- Create: `src/Seal/Security/Secrets.hs`
- Test: `test/Seal/Security/SecretsSpec.hs`
- Modify: `seal-harness.cabal` (register both modules)

**Interfaces:**
- Produces (constructors **not** exported):
  - `ApiKey`, `BearerToken`, `SecretKey` (wrap `ByteString`); `PairingCode`
    (wraps `Text`).
  - `mkApiKey :: ByteString -> ApiKey`, `mkBearerToken :: ByteString ->
    BearerToken`, `mkSecretKey :: ByteString -> SecretKey`,
    `mkPairingCode :: Text -> PairingCode`.
  - `withApiKey :: ApiKey -> (ByteString -> r) -> r` (and `withBearerToken`,
    `withSecretKey :: SecretKey -> (ByteString -> r) -> r`, `withPairingCode ::
    PairingCode -> (Text -> r) -> r`).
  - `Show` instances print `"<TypeName> <redacted>"`. No `ToJSON`/`FromJSON`.

- [ ] **Step 1: Write the failing test.**

`test/Seal/Security/SecretsSpec.hs`:

```haskell
module Seal.Security.SecretsSpec (spec) where

import Data.ByteString.Char8 qualified as BC
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Seal.Security.Secrets

spec :: Spec
spec = describe "Seal.Security.Secrets" $ do
  it "redacts ApiKey in Show" $
    show (mkApiKey "sk-supersecret") `shouldBe` "ApiKey <redacted>"

  it "redacts SecretKey in Show" $
    show (mkSecretKey "0123456789abcdef") `shouldBe` "SecretKey <redacted>"

  it "round-trips the raw bytes through the CPS accessor" $
    withApiKey (mkApiKey "sk-abc") id `shouldBe` "sk-abc"

  prop "Show never contains the secret bytes" $ \s ->
    let raw = BC.pack s
    in not (raw `BC.isInfixOf` BC.pack (show (mkApiKey raw)))
```

Register `Seal.Security.Secrets` (library) and `Seal.Security.SecretsSpec`
(test) in the cabal, and add the spec to `test/Main.hs`.

- [ ] **Step 2: Run it; expect failure.**

Run: `nix develop --command cabal test 2>&1 | tail -20`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement `Seal.Security.Secrets`.**

```haskell
-- | Opaque secret values. Constructors are intentionally NOT exported, there
-- are no JSON/serialization instances, and 'Show' is redacted. The only way
-- to observe the payload is the CPS accessor, which scopes the secret to a
-- single continuation so it cannot leak into a longer-lived binding.
module Seal.Security.Secrets
  ( ApiKey, BearerToken, PairingCode, SecretKey
  , mkApiKey, mkBearerToken, mkPairingCode, mkSecretKey
  , withApiKey, withBearerToken, withPairingCode, withSecretKey
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)

newtype ApiKey      = ApiKey      ByteString
newtype BearerToken = BearerToken ByteString
newtype SecretKey   = SecretKey   ByteString
newtype PairingCode = PairingCode Text

instance Show ApiKey      where show _ = "ApiKey <redacted>"
instance Show BearerToken where show _ = "BearerToken <redacted>"
instance Show SecretKey   where show _ = "SecretKey <redacted>"
instance Show PairingCode where show _ = "PairingCode <redacted>"

mkApiKey :: ByteString -> ApiKey
mkApiKey = ApiKey

mkBearerToken :: ByteString -> BearerToken
mkBearerToken = BearerToken

mkSecretKey :: ByteString -> SecretKey
mkSecretKey = SecretKey

mkPairingCode :: Text -> PairingCode
mkPairingCode = PairingCode

withApiKey :: ApiKey -> (ByteString -> r) -> r
withApiKey (ApiKey b) f = f b

withBearerToken :: BearerToken -> (ByteString -> r) -> r
withBearerToken (BearerToken b) f = f b

withSecretKey :: SecretKey -> (ByteString -> r) -> r
withSecretKey (SecretKey b) f = f b

withPairingCode :: PairingCode -> (Text -> r) -> r
withPairingCode (PairingCode t) f = f t
```

- [ ] **Step 4: Run tests + hlint; expect pass/clean.**

Run: `nix develop --command cabal test 2>&1 | tail -20` → PASS.
Run: `nix develop --command hlint src/ test/` → `No hints`.

- [ ] **Step 5: Commit.**

```bash
git add src/Seal/Security/Secrets.hs test/Seal/Security/SecretsSpec.hs seal-harness.cabal test/Main.hs
git commit -m "Add opaque, unleakable secret types"
```

---

### Task 2: `Seal.Security.Crypto` — symmetric crypto utilities

**Files:**
- Create: `src/Seal/Security/Crypto.hs`
- Test: `test/Seal/Security/CryptoSpec.hs`
- Modify: cabal + `test/Main.hs`

**Interfaces:**
- Consumes: `SecretKey`, `withSecretKey` (Task 1); `CryptoError` (Task 0).
- Produces:
  - `getRandomBytes :: Int -> IO ByteString`
  - `sha256Hash :: ByteString -> ByteString` (lowercase hex, 64 bytes ASCII)
  - `constantTimeEq :: ByteString -> ByteString -> Bool`
  - `generateToken :: Int -> IO Text` (hex of N random bytes)
  - `encrypt :: SecretKey -> ByteString -> IO (Either CryptoError ByteString)`
    (AES-256-CTR; 16-byte random IV prepended)
  - `decrypt :: SecretKey -> ByteString -> Either CryptoError ByteString`

- [ ] **Step 1: Write the failing test.**

`test/Seal/Security/CryptoSpec.hs`:

```haskell
module Seal.Security.CryptoSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Seal.Core.Errors (CryptoError (..))
import Seal.Security.Secrets (mkSecretKey)
import Seal.Security.Crypto

key32 :: ByteString
key32 = BS.replicate 32 7

spec :: Spec
spec = describe "Seal.Security.Crypto" $ do
  it "sha256Hash is stable lowercase hex" $
    sha256Hash "" `shouldBe`
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  it "constantTimeEq agrees with (==)" $
    constantTimeEq "abc" "abc" && not (constantTimeEq "abc" "abd")
      `shouldBe` True

  prop "encrypt then decrypt round-trips" $ \s -> do
    let plain = BC.pack s
    enc <- encrypt (mkSecretKey key32) plain
    pure $ (enc >>= decrypt (mkSecretKey key32)) == Right plain

  it "rejects a wrong-length key" $ do
    enc <- encrypt (mkSecretKey "short") "data"
    enc `shouldBe` Left BadKeyLength

  it "rejects ciphertext shorter than the IV" $
    decrypt (mkSecretKey key32) "tiny" `shouldBe` Left ShortCiphertext
```

- [ ] **Step 2: Run it; expect failure.**

Run: `nix develop --command cabal test 2>&1 | tail -20`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement `Seal.Security.Crypto`.**

```haskell
module Seal.Security.Crypto
  ( getRandomBytes
  , sha256Hash
  , constantTimeEq
  , generateToken
  , encrypt
  , decrypt
  ) where

import Crypto.Cipher.AES (AES256)
import Crypto.Cipher.Types (ctrCombine, cipherInit, makeIV)
import Crypto.Error (CryptoFailable (..))
import Crypto.Hash (SHA256, hash, Digest)
import Crypto.Random qualified as R
import Data.ByteArray (constEq)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text.Encoding qualified as TE

import Seal.Core.Errors (CryptoError (..))
import Seal.Security.Secrets (SecretKey, withSecretKey)

ivLength :: Int
ivLength = 16

-- | Cryptographically secure random bytes from system entropy.
getRandomBytes :: Int -> IO ByteString
getRandomBytes = R.getRandomBytes

-- | Lowercase-hex SHA-256 of the input (64 ASCII bytes).
sha256Hash :: ByteString -> ByteString
sha256Hash bs = convertToBase Base16 (hash bs :: Digest SHA256)

-- | Constant-time equality, for comparing secrets/tokens/hashes.
constantTimeEq :: ByteString -> ByteString -> Bool
constantTimeEq = constEq

-- | A hex token of @n@ random bytes (so 2n hex chars).
generateToken :: Int -> IO Text
generateToken n = do
  raw <- getRandomBytes n
  pure (TE.decodeUtf8 (convertToBase Base16 raw))

-- | AES-256-CTR encrypt. A fresh random 16-byte IV is generated and prepended
-- to the ciphertext. The key must be exactly 32 bytes.
encrypt :: SecretKey -> ByteString -> IO (Either CryptoError ByteString)
encrypt sk plaintext = withSecretKey sk $ \keyBytes ->
  case cipherInit keyBytes :: CryptoFailable AES256 of
    CryptoFailed _     -> pure (Left BadKeyLength)
    CryptoPassed cipher -> do
      ivBytes <- getRandomBytes ivLength
      case makeIV ivBytes of
        Nothing -> pure (Left BadInitVector)
        Just iv -> pure (Right (ivBytes <> ctrCombine cipher iv plaintext))

-- | Inverse of 'encrypt'. Pure: CTR needs no entropy to decrypt.
decrypt :: SecretKey -> ByteString -> Either CryptoError ByteString
decrypt sk blob = withSecretKey sk $ \keyBytes ->
  if BS.length blob < ivLength
    then Left ShortCiphertext
    else
      let (ivBytes, ciphertext) = BS.splitAt ivLength blob
      in case cipherInit keyBytes :: CryptoFailable AES256 of
           CryptoFailed _      -> Left BadKeyLength
           CryptoPassed cipher ->
             case makeIV ivBytes of
               Nothing -> Left BadInitVector
               Just iv -> Right (ctrCombine cipher iv ciphertext)
```

- [ ] **Step 4: Run tests + hlint; expect pass/clean.**

Run: `nix develop --command cabal test 2>&1 | tail -20` → PASS.
Run: `nix develop --command hlint src/ test/` → `No hints`.

- [ ] **Step 5: Commit.**

```bash
git add src/Seal/Security/Crypto.hs test/Seal/Security/CryptoSpec.hs seal-harness.cabal test/Main.hs
git commit -m "Add symmetric crypto utilities (AES-256-CTR, SHA-256)"
```

---

### Task 3: `Seal.Security.Vault.Age` — the encryption seam

**Files:**
- Create: `src/Seal/Security/Vault/Age.hs`
- Test: `test/Seal/Security/Vault/AgeSpec.hs`
- Modify: cabal + `test/Main.hs`

**Interfaces:**
- Produces:
  - `data VaultError = VaultLocked | VaultNotFound | VaultAlreadyExists |
    VaultKeyNotFound Text | VaultCorrupted Text | AgeError Text |
    AgeNotInstalled Text` (`deriving stock (Eq, Show)`).
  - `data VaultEncryptor = VaultEncryptor { veEncrypt :: ByteString -> IO
    (Either VaultError ByteString), veDecrypt :: ByteString -> IO (Either
    VaultError ByteString) }` — recipient/identity captured in the closure.
  - `mkAgeEncryptor :: AgeRecipient -> AgeIdentity -> IO (Either VaultError
    VaultEncryptor)` — preflights `age --version`.
  - `newtype AgeRecipient = AgeRecipient Text`, `newtype AgeIdentity =
    AgeIdentity Text` (`deriving stock (Eq, Show)`).
  - `mkMockEncryptor :: VaultEncryptor` (XOR 0xAB; no binary needed).
  - `mkFailingEncryptor :: VaultError -> VaultEncryptor`.

- [ ] **Step 1: Write the failing test.**

`test/Seal/Security/Vault/AgeSpec.hs`:

```haskell
module Seal.Security.Vault.AgeSpec (spec) where

import Test.Hspec
import Seal.Security.Vault.Age

spec :: Spec
spec = describe "Seal.Security.Vault.Age" $ do
  it "mock encryptor round-trips" $ do
    enc <- veEncrypt mkMockEncryptor "hello"
    case enc of
      Left e   -> expectationFailure (show e)
      Right ct -> do
        ct `shouldNotBe` Right "hello"  -- ciphertext differs from plaintext
        dec <- veDecrypt mkMockEncryptor ct
        dec `shouldBe` Right "hello"

  it "failing encryptor surfaces its error" $ do
    enc <- veEncrypt (mkFailingEncryptor VaultLocked) "x"
    enc `shouldBe` Left VaultLocked
```

> Note: the first `shouldNotBe` compares a `ByteString` to a `Right`; fix it to
> `ct \`shouldNotBe\` "hello"` when you paste — the intent is "ciphertext is not
> the plaintext".

- [ ] **Step 2: Run it; expect failure.**

Run: `nix develop --command cabal test 2>&1 | tail -20`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement `Seal.Security.Vault.Age`.**

```haskell
-- | The vault's encryption seam. The real encryptor shells out to the @age@
-- binary (so hardware-token support via age plugins is free); tests use the
-- in-process mock, so the suite needs no binary on PATH.
module Seal.Security.Vault.Age
  ( VaultError (..)
  , VaultEncryptor (..)
  , AgeRecipient (..)
  , AgeIdentity (..)
  , mkAgeEncryptor
  , mkMockEncryptor
  , mkFailingEncryptor
  ) where

import Data.Bits (xor)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Process.Typed
  ( ExitCode (..), byteStringInput, proc, readProcess, runProcess, setStdin )

data VaultError
  = VaultLocked
  | VaultNotFound
  | VaultAlreadyExists
  | VaultKeyNotFound Text
  | VaultCorrupted Text
  | AgeError Text          -- ^ stderr from the @age@ subprocess
  | AgeNotInstalled Text   -- ^ message with an install hint
  deriving stock (Eq, Show)

newtype AgeRecipient = AgeRecipient Text deriving stock (Eq, Show)
newtype AgeIdentity  = AgeIdentity  Text deriving stock (Eq, Show)

-- | Encrypt/decrypt with credentials already captured in the closure.
data VaultEncryptor = VaultEncryptor
  { veEncrypt :: ByteString -> IO (Either VaultError ByteString)
  , veDecrypt :: ByteString -> IO (Either VaultError ByteString)
  }

-- | Build a real encryptor backed by @age@. Preflights @age --version@ and
-- returns 'AgeNotInstalled' if the binary is absent.
mkAgeEncryptor :: AgeRecipient -> AgeIdentity -> IO (Either VaultError VaultEncryptor)
mkAgeEncryptor (AgeRecipient recipient) (AgeIdentity identity) = do
  versionResult <- runProcess (proc "age" ["--version"])
  case versionResult of
    ExitFailure _ ->
      pure (Left (AgeNotInstalled "Install age from https://age-encryption.org"))
    ExitSuccess ->
      pure (Right VaultEncryptor
        { veEncrypt = run ["--encrypt", "--recipient", T.unpack recipient]
        , veDecrypt = run ["--decrypt", "--identity", T.unpack identity]
        })
  where
    run :: [String] -> ByteString -> IO (Either VaultError ByteString)
    run args input = do
      let cfg = setStdin (byteStringInput (BL.fromStrict input)) (proc "age" args)
      (code, out, err) <- readProcess cfg
      pure $ case code of
        ExitSuccess   -> Right (BL.toStrict out)
        ExitFailure _ -> Left (AgeError (TE.decodeUtf8 (BL.toStrict err)))

-- | XOR-with-0xAB mock; reversible, no binary required.
mkMockEncryptor :: VaultEncryptor
mkMockEncryptor = VaultEncryptor
  { veEncrypt = pure . Right . BS.map (`xor` 0xAB)
  , veDecrypt = pure . Right . BS.map (`xor` 0xAB)
  }

-- | An encryptor that always fails; for exercising vault error paths.
mkFailingEncryptor :: VaultError -> VaultEncryptor
mkFailingEncryptor e = VaultEncryptor
  { veEncrypt = const (pure (Left e))
  , veDecrypt = const (pure (Left e))
  }
```

- [ ] **Step 4: Run tests + hlint; expect pass/clean.** Fix the test's
`shouldNotBe` per the note. → PASS / `No hints`.

- [ ] **Step 5: Commit.**

```bash
git add src/Seal/Security/Vault/Age.hs test/Seal/Security/Vault/AgeSpec.hs seal-harness.cabal test/Main.hs
git commit -m "Add age-backed vault encryption seam with mocks"
```

---

### Task 4: `Seal.Security.Vault` — the encrypted vault

This is the centerpiece. The improved design factors the three unlock modes
through two helpers (`currentMap`, `persistMap`) instead of duplicating the
get/put/delete/list logic per mode, and gives "key not found" its own error
constructor.

**Files:**
- Create: `src/Seal/Security/Vault.hs`
- Test: `test/Seal/Security/VaultSpec.hs`
- Modify: cabal + `test/Main.hs`

**Interfaces:**
- Consumes: everything from `Seal.Security.Vault.Age` (Task 3).
- Produces:
  - `data UnlockMode = UnlockStartup | UnlockOnDemand | UnlockPerAccess`
    (`deriving stock (Eq, Show)`).
  - `data VaultConfig = VaultConfig { vcPath :: FilePath, vcKeyType :: Text,
    vcUnlock :: UnlockMode }`.
  - `data VaultStatus = VaultStatus { vsLocked :: Bool, vsSecretCount :: Int,
    vsKeyType :: Text }` (`deriving stock (Eq, Show)`).
  - `data VaultHandle = VaultHandle { vhInit, vhUnlock :: IO (Either VaultError
    ()); vhLock :: IO (); vhGet :: Text -> IO (Either VaultError ByteString);
    vhPut :: Text -> ByteString -> IO (Either VaultError ()); vhDelete :: Text
    -> IO (Either VaultError ()); vhList :: IO (Either VaultError [Text]);
    vhStatus :: IO VaultStatus; vhRekey :: VaultEncryptor -> Text -> (Text ->
    IO Bool) -> IO (Either VaultError ()) }`.
  - `openVault :: VaultConfig -> VaultEncryptor -> IO VaultHandle` — builds the
    handle; does not unlock.

- [ ] **Step 1: Write the failing test** (drives behavior with the mock):

`test/Seal/Security/VaultSpec.hs`:

```haskell
module Seal.Security.VaultSpec (spec) where

import Data.List (sort)
import System.IO.Temp (withSystemTempDirectory)
import System.FilePath ((</>))
import Test.Hspec
import Seal.Security.Vault
import Seal.Security.Vault.Age

withVault :: UnlockMode -> (VaultHandle -> IO a) -> IO a
withVault mode k =
  withSystemTempDirectory "seal-vault" $ \dir -> do
    let cfg = VaultConfig (dir </> "vault.age") "mock" mode
    h <- openVault cfg mkMockEncryptor
    _ <- vhInit h
    _ <- vhUnlock h
    k h

spec :: Spec
spec = describe "Seal.Security.Vault" $ do
  it "put then get round-trips a secret" $ withVault UnlockStartup $ \h -> do
    _ <- vhPut h "ANTHROPIC_API_KEY" "sk-123"
    vhGet h "ANTHROPIC_API_KEY" `shouldReturn` Right "sk-123"

  it "lists key names but not values" $ withVault UnlockStartup $ \h -> do
    _ <- vhPut h "a" "1"
    _ <- vhPut h "b" "2"
    fmap (fmap sort) (vhList h) `shouldReturn` Right ["a", "b"]

  it "delete removes a key" $ withVault UnlockStartup $ \h -> do
    _ <- vhPut h "k" "v"
    _ <- vhDelete h "k"
    vhGet h "k" `shouldReturn` Left (VaultKeyNotFound "k")

  it "init twice reports VaultAlreadyExists" $ withVault UnlockStartup $ \h ->
    vhInit h `shouldReturn` Left VaultAlreadyExists

  it "reports locked status before unlock" $
    withSystemTempDirectory "seal-vault" $ \dir -> do
      let cfg = VaultConfig (dir </> "v.age") "mock" UnlockStartup
      h <- openVault cfg mkMockEncryptor
      _ <- vhInit h
      st <- vhStatus h
      vsLocked st `shouldBe` True

  it "get on a locked startup vault returns VaultLocked" $
    withSystemTempDirectory "seal-vault" $ \dir -> do
      let cfg = VaultConfig (dir </> "v.age") "mock" UnlockStartup
      h <- openVault cfg mkMockEncryptor
      _ <- vhInit h
      vhGet h "anything" `shouldReturn` Left VaultLocked

  it "per-access mode reads without an explicit unlock" $
    withSystemTempDirectory "seal-vault" $ \dir -> do
      let cfg = VaultConfig (dir </> "v.age") "mock" UnlockPerAccess
      h <- openVault cfg mkMockEncryptor
      _ <- vhInit h
      _ <- vhPut h "k" "v"
      vhGet h "k" `shouldReturn` Right "v"

  it "rekey re-encrypts and verifies before replacing" $ withVault UnlockStartup $ \h -> do
    _ <- vhPut h "k" "v"
    res <- vhRekey h mkMockEncryptor "mock2" (const (pure True))
    res `shouldBe` Right ()
    vhGet h "k" `shouldReturn` Right "v"
```

- [ ] **Step 2: Run it; expect failure.**

Run: `nix develop --command cabal test 2>&1 | tail -25`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement `Seal.Security.Vault`.**

```haskell
-- | An encrypted secret vault. Values are stored as a base64-encoded JSON map,
-- encrypted as a whole by the 'VaultEncryptor'. Writes are atomic
-- (tmp → chmod 0600 → rename). Three unlock modes trade memory residency for
-- convenience. All mutations are serialised by an 'MVar'; the decrypted map is
-- cached in a 'TVar' for the startup/on-demand modes.
module Seal.Security.Vault
  ( UnlockMode (..)
  , VaultConfig (..)
  , VaultStatus (..)
  , VaultHandle (..)
  , openVault
  ) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Exception (IOException, try)
import Control.Monad (when)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Lazy qualified as BL
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (doesFileExist, removeFile, renameFile)
import System.Posix.Files (setFileMode)

import Seal.Security.Vault.Age (VaultEncryptor (..), VaultError (..))

data UnlockMode = UnlockStartup | UnlockOnDemand | UnlockPerAccess
  deriving stock (Eq, Show)

data VaultConfig = VaultConfig
  { vcPath    :: FilePath
  , vcKeyType :: Text
  , vcUnlock  :: UnlockMode
  } deriving stock (Eq, Show)

data VaultStatus = VaultStatus
  { vsLocked      :: Bool
  , vsSecretCount :: Int
  , vsKeyType     :: Text
  } deriving stock (Eq, Show)

data VaultHandle = VaultHandle
  { vhInit   :: IO (Either VaultError ())
  , vhUnlock :: IO (Either VaultError ())
  , vhLock   :: IO ()
  , vhGet    :: Text -> IO (Either VaultError ByteString)
  , vhPut    :: Text -> ByteString -> IO (Either VaultError ())
  , vhDelete :: Text -> IO (Either VaultError ())
  , vhList   :: IO (Either VaultError [Text])
  , vhStatus :: IO VaultStatus
  , vhRekey  :: VaultEncryptor -> Text -> (Text -> IO Bool) -> IO (Either VaultError ())
  }

-- Internal mutable state (not exported).
data VaultState = VaultState
  { stConfig    :: VaultConfig
  , stEncryptor :: IORef VaultEncryptor
  , stKeyType   :: IORef Text
  , stCache     :: TVar (Maybe (Map Text ByteString))
  , stWriteLock :: MVar ()
  }

openVault :: VaultConfig -> VaultEncryptor -> IO VaultHandle
openVault cfg enc = do
  st <- VaultState cfg
          <$> newIORef enc
          <*> newIORef (vcKeyType cfg)
          <*> newTVarIO Nothing
          <*> newMVar ()
  pure VaultHandle
    { vhInit   = vaultInit st
    , vhUnlock = vaultUnlock st
    , vhLock   = atomically (writeTVar (stCache st) Nothing)
    , vhGet    = \k -> withCurrentMap st (lookupKey k)
    , vhPut    = \k v -> mutate st (Right . Map.insert k v)
    , vhDelete = \k -> mutate st $ \m ->
        if Map.member k m then Right (Map.delete k m) else Left (VaultKeyNotFound k)
    , vhList   = withCurrentMap st (Right . Map.keys)
    , vhStatus = vaultStatus st
    , vhRekey  = vaultRekey st
    }

-- ---------------------------------------------------------------------------
-- Core operations
-- ---------------------------------------------------------------------------

vaultInit :: VaultState -> IO (Either VaultError ())
vaultInit st = withMVar (stWriteLock st) $ \_ -> do
  exists <- doesFileExist (vcPath (stConfig st))
  if exists
    then pure (Left VaultAlreadyExists)
    else writeMap st Map.empty

-- | Decrypt the on-disk vault into the cache (for the cached modes).
vaultUnlock :: VaultState -> IO (Either VaultError ())
vaultUnlock st = do
  res <- readMap st
  case res of
    Left e  -> pure (Left e)
    Right m -> do
      atomically (writeTVar (stCache st) (Just m))
      pure (Right ())

vaultStatus :: VaultState -> IO VaultStatus
vaultStatus st = do
  cache   <- readTVarIO (stCache st)
  keyType <- readIORef (stKeyType st)
  pure VaultStatus
    { vsLocked      = maybe True (const False) cache
    , vsSecretCount = maybe 0 Map.size cache
    , vsKeyType     = keyType
    }

-- | Obtain the current map per unlock mode, then apply a pure observation.
-- 'UnlockOnDemand' transparently unlocks first.
withCurrentMap
  :: VaultState
  -> (Map Text ByteString -> Either VaultError a)
  -> IO (Either VaultError a)
withCurrentMap st f = do
  prepareAccess st
  em <- currentMap st
  pure (em >>= f)

-- | Read-modify-write a mutation under the write lock.
mutate
  :: VaultState
  -> (Map Text ByteString -> Either VaultError (Map Text ByteString))
  -> IO (Either VaultError ())
mutate st f = do
  prepareAccess st
  withMVar (stWriteLock st) $ \_ -> do
    em <- currentMap st
    case em >>= f of
      Left e   -> pure (Left e)
      Right m' -> writeMap st m'

-- | For 'UnlockOnDemand', ensure the cache is populated before we take the
-- write lock (so we never deadlock by unlocking inside it).
prepareAccess :: VaultState -> IO ()
prepareAccess st = case vcUnlock (stConfig st) of
  UnlockOnDemand -> do
    cache <- readTVarIO (stCache st)
    case cache of
      Just _  -> pure ()
      Nothing -> () <$ vaultUnlock st
  _ -> pure ()

-- | The current decrypted map according to unlock mode. Per-access always
-- reads disk; the cached modes read the 'TVar' and are 'VaultLocked' if empty.
currentMap :: VaultState -> IO (Either VaultError (Map Text ByteString))
currentMap st = case vcUnlock (stConfig st) of
  UnlockPerAccess -> readMap st
  _ -> maybe (Left VaultLocked) Right <$> readTVarIO (stCache st)

-- | Persist a map to disk and, for the cached modes, refresh the cache.
writeMap :: VaultState -> Map Text ByteString -> IO (Either VaultError ())
writeMap st m = do
  enc <- readIORef (stEncryptor st)
  let payload = BL.toStrict (Aeson.encode (encodeValues m))
  res <- veEncrypt enc payload
  case res of
    Left e           -> pure (Left e)
    Right ciphertext -> do
      atomicWrite (vcPath (stConfig st)) ciphertext
      case vcUnlock (stConfig st) of
        UnlockPerAccess -> pure ()
        _ -> atomically (writeTVar (stCache st) (Just m))
      pure (Right ())

-- | Read and decrypt the on-disk vault into a map.
readMap :: VaultState -> IO (Either VaultError (Map Text ByteString))
readMap st = do
  enc        <- readIORef (stEncryptor st)
  fileResult <- try @IOException (BS.readFile (vcPath (stConfig st)))
  case fileResult of
    Left _       -> pure (Left VaultNotFound)
    Right fileBs -> do
      plain <- veDecrypt enc fileBs
      pure (plain >>= decodePayload)

-- ---------------------------------------------------------------------------
-- Rekey: write to .new, verify byte-for-byte, confirm, atomic replace
-- ---------------------------------------------------------------------------

vaultRekey
  :: VaultState -> VaultEncryptor -> Text -> (Text -> IO Bool)
  -> IO (Either VaultError ())
vaultRekey st newEnc newKeyType confirm = withMVar (stWriteLock st) $ \_ -> do
  let path    = vcPath (stConfig st)
      newPath = path <> ".new"
  cur <- readMap st
  case cur of
    Left e         -> pure (Left e)
    Right plainMap -> do
      let payload = BL.toStrict (Aeson.encode (encodeValues plainMap))
      enc <- veEncrypt newEnc payload
      case enc of
        Left e           -> pure (Left e)
        Right ciphertext -> do
          atomicWrite newPath ciphertext
          verified <- verifyRekey newEnc newPath plainMap
          if not verified
            then cleanup newPath >> pure (Left (VaultCorrupted "rekey verification failed"))
            else do
              oldKeyType <- readIORef (stKeyType st)
              ok <- confirm (rekeyPrompt oldKeyType newKeyType (Map.size plainMap))
              if not ok
                then cleanup newPath >> pure (Left (VaultCorrupted "rekey cancelled"))
                else do
                  renameFile newPath path
                  writeIORef (stEncryptor st) newEnc
                  writeIORef (stKeyType st) newKeyType
                  atomically (writeTVar (stCache st) (Just plainMap))
                  pure (Right ())

verifyRekey :: VaultEncryptor -> FilePath -> Map Text ByteString -> IO Bool
verifyRekey newEnc newPath expected = do
  readBack <- try @IOException (BS.readFile newPath)
  case readBack of
    Left _   -> pure False
    Right bs -> do
      plain <- veDecrypt newEnc bs
      pure $ case plain >>= decodePayload of
        Right m -> m == expected
        Left _  -> False

rekeyPrompt :: Text -> Text -> Int -> Text
rekeyPrompt oldKt newKt n =
  "Replace vault? Old: " <> oldKt <> ", New: " <> newKt
    <> ", " <> T.pack (show n) <> " secrets verified identical"

cleanup :: FilePath -> IO ()
cleanup path = do
  exists <- doesFileExist path
  when exists (removeFile path)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

lookupKey :: Text -> Map Text ByteString -> Either VaultError ByteString
lookupKey k = maybe (Left (VaultKeyNotFound k)) Right . Map.lookup k

-- | Atomic write: tmp file, chmod 0600, rename over the target.
atomicWrite :: FilePath -> ByteString -> IO ()
atomicWrite path bs = do
  let tmp = path <> ".tmp"
  BS.writeFile tmp bs
  setFileMode tmp 0o600
  renameFile tmp path

-- Values are base64 so binary secrets survive the JSON round-trip.
encodeValues :: Map Text ByteString -> Map Text Text
encodeValues = Map.map (TE.decodeUtf8 . B64.encode)

decodePayload :: ByteString -> Either VaultError (Map Text ByteString)
decodePayload plain =
  case Aeson.decodeStrict plain of
    Nothing      -> Left (VaultCorrupted "invalid JSON")
    Just encoded -> maybe (Left (VaultCorrupted "invalid base64")) Right
                          (traverse decodeValue encoded)
  where
    decodeValue t = either (const Nothing) Just (B64.decode (TE.encodeUtf8 t))
```

- [ ] **Step 4: Run tests + hlint; expect pass/clean.**

Run: `nix develop --command cabal test 2>&1 | tail -25` → PASS.
Run: `nix develop --command hlint src/ test/` → `No hints`.

- [ ] **Step 5: Commit.**

```bash
git add src/Seal/Security/Vault.hs test/Seal/Security/VaultSpec.hs seal-harness.cabal test/Main.hs
git commit -m "Add encrypted secret vault with three unlock modes and verified rekey"
```

- [ ] **Step 6 (integration, optional but recommended): real-`age` smoke test.**

Add a separate, `age`-gated spec that generates a key with `age-keygen`,
builds a real encryptor with `mkAgeEncryptor`, and runs the same
put/get/list/rekey cycle. Skip (via `pendingWith`) when `age` is not on PATH so
CI without the binary stays green; the Nix dev shell should add `age` to
`shell.tools`/`buildInputs` so it runs locally and in CI.

---

### Task 5: `Seal.Security.Path` — workspace confinement

**Files:**
- Create: `src/Seal/Security/Path.hs`
- Test: `test/Seal/Security/PathSpec.hs`
- Modify: cabal + `test/Main.hs`

**Interfaces:**
- Produces (constructor **not** exported):
  - `newtype SafePath` + `getSafePath :: SafePath -> FilePath`.
  - `newtype WorkspaceRoot = WorkspaceRoot FilePath`.
  - `data PathError = PathEscapesWorkspace FilePath | PathIsBlocked Text |
    PathDoesNotExist FilePath` (`deriving stock (Eq, Show)`).
  - `mkSafePath :: WorkspaceRoot -> FilePath -> IO (Either PathError SafePath)`
    — canonicalizes the request, rejects anything resolving outside the
    (canonicalized) root, and rejects blocked basenames (`.env`, `.ssh`,
    `.gnupg`, `.netrc`, `.seal`).

> `WorkspaceRoot` will later move to `Seal.Core.Types`; define it here for now
> and re-export when Phase 2 introduces Core.Types (note left for that task).

- [ ] **Step 1: Write the failing test.**

```haskell
module Seal.Security.PathSpec (spec) where

import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Data.ByteString qualified as BS
import Test.Hspec
import Seal.Security.Path

spec :: Spec
spec = describe "Seal.Security.Path" $ do
  it "accepts a file inside the workspace" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      BS.writeFile (root </> "ok.txt") "hi"
      r <- mkSafePath (WorkspaceRoot root) "ok.txt"
      fmap getSafePath r `shouldSatisfy` either (const False) (const True)

  it "rejects parent traversal" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      r <- mkSafePath (WorkspaceRoot root) "../escape.txt"
      r `shouldSatisfy` isEscape

  it "rejects blocked dotfiles" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      createDirectoryIfMissing True (root </> ".ssh")
      BS.writeFile (root </> ".ssh" </> "id_rsa") "k"
      r <- mkSafePath (WorkspaceRoot root) (".ssh" </> "id_rsa")
      r `shouldSatisfy` isBlocked
  where
    isEscape  = either isEsc (const False)
    isEsc (PathEscapesWorkspace _) = True
    isEsc _ = False
    isBlocked = either isBlk (const False)
    isBlk (PathIsBlocked _) = True
    isBlk _ = False
```

- [ ] **Step 2: Run it; expect failure.** → module not found.

- [ ] **Step 3: Implement `Seal.Security.Path`.**

```haskell
module Seal.Security.Path
  ( SafePath
  , getSafePath
  , WorkspaceRoot (..)
  , PathError (..)
  , mkSafePath
  ) where

import Data.List (isPrefixOf)
import Data.Text (Text)
import System.Directory (canonicalizePath, doesPathExist)
import System.FilePath (takeFileName, (</>), isAbsolute)

newtype SafePath = SafePath FilePath

getSafePath :: SafePath -> FilePath
getSafePath (SafePath p) = p

newtype WorkspaceRoot = WorkspaceRoot FilePath

data PathError
  = PathEscapesWorkspace FilePath
  | PathIsBlocked Text
  | PathDoesNotExist FilePath
  deriving stock (Eq, Show)

blockedNames :: [FilePath]
blockedNames = [".env", ".ssh", ".gnupg", ".netrc", ".seal"]

mkSafePath :: WorkspaceRoot -> FilePath -> IO (Either PathError SafePath)
mkSafePath (WorkspaceRoot root) requested = do
  canonRoot <- canonicalizePath root
  let joined = if isAbsolute requested then requested else canonRoot </> requested
  canon <- canonicalizePath joined
  exists <- doesPathExist canon
  pure $
    if any (`elem` blockedNames) (pathComponents requested)
      then Left (PathIsBlocked "path touches a blocked location")
    else if not (canonRoot `isPrefixOf` canon)
      then Left (PathEscapesWorkspace canon)
    else if not exists
      then Left (PathDoesNotExist canon)
    else Right (SafePath canon)
  where
    pathComponents = foldr (\c acc -> takeFileName c : acc) [] . scanl1 (</>) . splitOn
    splitOn = words . map (\c -> if c == '/' then ' ' else c)
```

> Note for the implementer: the `pathComponents` helper above is a sketch —
> implement blocked-name detection by checking `takeFileName` of each path
> segment from `System.FilePath.splitDirectories requested`; replace the sketch
> with `any (`elem` blockedNames) (splitDirectories requested)`. Keep the
> behavior the tests pin: blocked-name → `PathIsBlocked`, escape →
> `PathEscapesWorkspace`, missing → `PathDoesNotExist`.

- [ ] **Step 4: Run tests + hlint; expect pass/clean.** → PASS / `No hints`.

- [ ] **Step 5: Add a QuickCheck confinement property.**

```haskell
  prop "no relative input ever yields a path outside the root" $ \segs ->
    withSystemTempDirectory "seal-ws" $ \root -> do
      let rel = foldr (</>) "" (filter (not . null) segs)
      r <- mkSafePath (WorkspaceRoot root) rel
      canonRoot <- canonicalizePath root
      pure $ case r of
        Right sp -> canonRoot `isPrefixOf` getSafePath sp
        Left _   -> True
```

Run tests → PASS. Commit.

```bash
git add src/Seal/Security/Path.hs test/Seal/Security/PathSpec.hs seal-harness.cabal test/Main.hs
git commit -m "Add SafePath workspace confinement"
```

---

### Task 6: `Seal.Security.Policy` + `Seal.Security.Command` — pure authorization

**Files:**
- Create: `src/Seal/Security/Policy.hs`, `src/Seal/Security/Command.hs`
- Test: `test/Seal/Security/PolicySpec.hs`, `test/Seal/Security/CommandSpec.hs`
- Modify: cabal + `test/Main.hs`

**Interfaces:**
- Produces (`Policy`):
  - `newtype CommandName = CommandName Text` (`deriving stock (Eq, Ord, Show)`).
  - `data AllowList a = AllowAll | AllowOnly (Set a)`.
  - `data AutonomyLevel = Full | Supervised | Deny` (`deriving stock (Eq,
    Show)`).
  - `data SecurityPolicy = SecurityPolicy { spAllowedCommands :: AllowList
    CommandName, spAutonomy :: AutonomyLevel }`.
  - `defaultPolicy :: SecurityPolicy` (Deny + empty allow-list).
  - `isCommandAllowed :: SecurityPolicy -> CommandName -> Bool`.
- Produces (`Command`):
  - `newtype AuthorizedCommand` (constructor **not** exported) +
    `authorizedProgram :: AuthorizedCommand -> (FilePath, [Text])`.
  - `data CommandError = CommandNotAllowed Text | CommandInAutonomyDeny`
    (`deriving stock (Eq, Show)`).
  - `authorize :: SecurityPolicy -> FilePath -> [Text] -> Either CommandError
    AuthorizedCommand` — rejects if autonomy is `Deny` or the program basename
    is not allowed.
  - `authorizeShell :: SecurityPolicy -> Text -> Either CommandError
    AuthorizedCommand` — allowed only when `CommandName "shell"` is allowed.

- [ ] **Step 1: Write the failing tests** (Policy is pure → QuickCheck-heavy):

`test/Seal/Security/PolicySpec.hs`:

```haskell
module Seal.Security.PolicySpec (spec) where

import Data.Set qualified as Set
import Test.Hspec
import Seal.Security.Policy

spec :: Spec
spec = describe "Seal.Security.Policy" $ do
  it "defaultPolicy denies every command" $
    isCommandAllowed defaultPolicy (CommandName "git") `shouldBe` False

  it "AllowOnly permits listed commands only" $ do
    let p = SecurityPolicy (AllowOnly (Set.fromList [CommandName "git"])) Full
    isCommandAllowed p (CommandName "git") `shouldBe` True
    isCommandAllowed p (CommandName "rm")  `shouldBe` False

  it "AllowAll permits anything" $
    isCommandAllowed (SecurityPolicy AllowAll Full) (CommandName "anything")
      `shouldBe` True
```

`test/Seal/Security/CommandSpec.hs`:

```haskell
module Seal.Security.CommandSpec (spec) where

import Data.Set qualified as Set
import Test.Hspec
import Seal.Security.Policy
import Seal.Security.Command

gitPolicy :: SecurityPolicy
gitPolicy = SecurityPolicy (AllowOnly (Set.fromList [CommandName "git"])) Full

spec :: Spec
spec = describe "Seal.Security.Command" $ do
  it "authorizes an allowed program" $
    fmap authorizedProgram (authorize gitPolicy "/usr/bin/git" ["status"])
      `shouldBe` Right ("/usr/bin/git", ["status"])

  it "rejects a disallowed program" $
    authorize gitPolicy "/bin/rm" ["-rf", "/"]
      `shouldBe` Left (CommandNotAllowed "rm")

  it "rejects everything under Deny autonomy" $
    authorize (SecurityPolicy AllowAll Deny) "/usr/bin/git" ["status"]
      `shouldBe` Left CommandInAutonomyDeny
```

- [ ] **Step 2: Run; expect failure.** → modules not found.

- [ ] **Step 3: Implement `Seal.Security.Policy`.**

```haskell
module Seal.Security.Policy
  ( CommandName (..)
  , AllowList (..)
  , AutonomyLevel (..)
  , SecurityPolicy (..)
  , defaultPolicy
  , isCommandAllowed
  ) where

import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)

newtype CommandName = CommandName Text
  deriving stock (Eq, Ord, Show)

data AllowList a = AllowAll | AllowOnly (Set a)
  deriving stock (Eq, Show)

data AutonomyLevel = Full | Supervised | Deny
  deriving stock (Eq, Show)

data SecurityPolicy = SecurityPolicy
  { spAllowedCommands :: AllowList CommandName
  , spAutonomy        :: AutonomyLevel
  } deriving stock (Eq, Show)

-- | Deny everything: the safe default a config must explicitly widen.
defaultPolicy :: SecurityPolicy
defaultPolicy = SecurityPolicy (AllowOnly Set.empty) Deny

isCommandAllowed :: SecurityPolicy -> CommandName -> Bool
isCommandAllowed p name = case spAllowedCommands p of
  AllowAll      -> True
  AllowOnly set -> name `Set.member` set
```

- [ ] **Step 4: Implement `Seal.Security.Command`.**

```haskell
module Seal.Security.Command
  ( AuthorizedCommand
  , authorizedProgram
  , CommandError (..)
  , authorize
  , authorizeShell
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import System.FilePath (takeFileName)

import Seal.Security.Policy

-- | Proof that a (program, args) pair passed policy. Constructor unexported:
-- the only way to obtain one is 'authorize'/'authorizeShell', so an executor
-- that demands an 'AuthorizedCommand' cannot be handed an unchecked command.
newtype AuthorizedCommand = AuthorizedCommand (FilePath, [Text])

authorizedProgram :: AuthorizedCommand -> (FilePath, [Text])
authorizedProgram (AuthorizedCommand p) = p

data CommandError
  = CommandNotAllowed Text
  | CommandInAutonomyDeny
  deriving stock (Eq, Show)

authorize :: SecurityPolicy -> FilePath -> [Text] -> Either CommandError AuthorizedCommand
authorize policy program args
  | spAutonomy policy == Deny = Left CommandInAutonomyDeny
  | isCommandAllowed policy (CommandName base) = Right (AuthorizedCommand (program, args))
  | otherwise = Left (CommandNotAllowed base)
  where
    base = T.pack (takeFileName program)

authorizeShell :: SecurityPolicy -> Text -> Either CommandError AuthorizedCommand
authorizeShell policy command
  | spAutonomy policy == Deny = Left CommandInAutonomyDeny
  | isCommandAllowed policy (CommandName "shell") =
      Right (AuthorizedCommand ("/bin/sh", ["-c", command]))
  | otherwise = Left (CommandNotAllowed "shell")
```

- [ ] **Step 5: Run tests + hlint; expect pass/clean.** → PASS / `No hints`.

- [ ] **Step 6: Add a QuickCheck property** to `PolicySpec` (allow-list
membership is exactly `isCommandAllowed` under `AllowOnly`), then commit:

```bash
git add src/Seal/Security/Policy.hs src/Seal/Security/Command.hs \
        test/Seal/Security/PolicySpec.hs test/Seal/Security/CommandSpec.hs \
        seal-harness.cabal test/Main.hs
git commit -m "Add pure security policy and AuthorizedCommand proof type"
```

---

## Phase 1 milestone check

Done when, in the Nix dev shell:

- `nix develop --command cabal build all` is `-Werror` clean.
- `nix develop --command cabal test` is green, including every QuickCheck
  property (Secrets redaction, crypto round-trip, vault round-trip across all
  three unlock modes + rekey, path confinement, policy membership).
- `nix develop --command hlint src/ test/` reports `No hints`.
- A throwaway run against a real `age` key (Task 4 Step 6) succeeds when `age`
  is on PATH.

Then: write `2026-07-xx-phase-2-mvp.md` before starting Phase 2.

---

## Self-Review

- **Spec coverage:** Secret types (redacted Show, no JSON, CPS) → Task 1; crypto
  seam → Task 2; `age` + hardware tokens via recipient/identity strings →
  Task 3; vault with three unlock modes, atomic writes, verified rekey → Task 4;
  `SafePath` confinement → Task 5; `AuthorizedCommand` + pure policy → Task 6.
  All README "Secret Protection" and "Security by Construction" rows for this
  phase are covered.
- **Type consistency:** `VaultError` is defined once in Task 3 and imported by
  Task 4; `SecretKey`/`withSecretKey` flow Task 1 → Task 2; `CommandName`/
  `SecurityPolicy` flow Task 6 Policy → Command. Field accessors use the `vh*`/
  `vc*`/`vs*`/`sp*`/`ve*` prefix convention throughout.
- **Known sketch to finish:** `Seal.Security.Path`'s blocked-name detection is
  given as a sketch with an explicit note to implement it via
  `splitDirectories`; the tests pin the required behavior.
- **Deferred:** `WorkspaceRoot` lives in `Seal.Security.Path` for this phase and
  moves to `Seal.Core.Types` in Phase 2 (noted in Task 5).
