module GeniusYield.Server.Config (
  ServerConfig (..),
  serverConfigOptionalFPIO,
  coreConfigFromServerConfig,
  optionalSigningKeyFromServerConfig,
) where

import Cardano.Api qualified as Api
import Data.Aeson (
  eitherDecodeFileStrict,
  eitherDecodeStrict,
 )
import Data.Strict.Tuple (Pair (..))
import Data.Yaml qualified as Yaml
import Deriving.Aeson
import GHC.IO.Exception (userError)
import GeniusYield.GYConfig (Confidential, GYCoreConfig (..), GYCoreProviderInfo)
import GeniusYield.Types
import Maestro.Types.Common (LowerFirst)
import Network.Wai.Handler.Warp (Port)
import RIO
import RIO.FilePath (takeExtension)
import System.Envy
import Unsafe.Coerce (unsafeCoerce)

{- $setup

>>> :set -XOverloadedStrings -XTypeApplications
>>> import qualified Data.Aeson                 as Aeson
>>> import qualified Data.ByteString.Lazy.Char8 as LBS8
>>> import           Data.Proxy
-}

-- >>> Aeson.encode (MnemonicWallet (MnemonicWalletDetails ["hello"] (Just 1) (Just 2)))
-- "{\"tag\":\"mnemonicWallet\",\"contents\":{\"mnemonic\":[\"hello\"],\"acc_ix\":1,\"addr_ix\":2}}"
data UserWallet = MnemonicWallet !MnemonicWalletDetails | KeyPathWallet !FilePath
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[ConstructorTagModifier '[LowerFirst]] UserWallet

data MnemonicWalletDetails = MnemonicWalletDetails
  { -- | Mnemonic (seed phrase).
    mnemonic ∷ !Mnemonic,
    -- | Account index.
    accIx ∷ !(Maybe Word32),
    -- | Payment address index.
    addrIx ∷ !(Maybe Word32)
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

data ServerConfig = ServerConfig
  { scCoreProvider ∷ !GYCoreProviderInfo,
    scNetworkId ∷ !GYNetworkId,
    scLogging ∷ ![GYLogScribeConfig],
    scMaestroToken ∷ !(Confidential Text),
    scPort ∷ !Port,
    scWallet ∷ !(Maybe UserWallet),
    scServerApiKey ∷ !(Confidential Text),
    scTapToolsApiKey ∷ !(Maybe (Confidential Text)),
    scCollateral ∷ !(Maybe GYTxOutRef),
    scStakeAddress ∷ !(Maybe GYStakeAddressBech32)
  }
  deriving stock (Generic)
  deriving
    (FromJSON)
    via CustomJSON '[FieldLabelModifier '[StripPrefix "sc", LowerFirst]] ServerConfig

instance FromEnv ServerConfig where
  fromEnv _ = forceFromJsonOrYaml <$> env "SERVER_CONFIG"
   where
    forceFromJsonOrYaml ∷ FromJSON a ⇒ String → a
    forceFromJsonOrYaml s =
      let bs = fromString s
          parseResults = eitherDecodeStrict bs :| [first show $ Yaml.decodeEither' bs]
       in go parseResults
     where
      go (x :| []) = case x of
        Left e → error e
        Right a → a
      go (x :| y : ys) = case x of
        Left _ → go (y :| ys)
        Right a → a

eitherDecodeFileStrictJsonOrYaml ∷ FromJSON a ⇒ FilePath → IO (Either String a)
eitherDecodeFileStrictJsonOrYaml fp =
  case takeExtension fp of
    ".json" → eitherDecodeFileStrict fp
    ".yaml" → first show <$> Yaml.decodeFileEither fp
    _ → throwIO $ userError "Only .json or .yaml extensions are supported for configuration."

serverConfigOptionalFPIO ∷ Maybe FilePath → IO ServerConfig
serverConfigOptionalFPIO mfp = do
  e ← maybe decodeEnv eitherDecodeFileStrictJsonOrYaml mfp
  either (throwIO . userError) return e

coreConfigFromServerConfig ∷ ServerConfig → GYCoreConfig
coreConfigFromServerConfig ServerConfig {..} =
  GYCoreConfig
    { cfgCoreProvider = scCoreProvider,
      cfgNetworkId = scNetworkId,
      cfgLogging = scLogging,
      cfgLogTiming = Nothing
    }

optionalSigningKeyFromServerConfig ∷ ServerConfig → IO (Maybe (Pair GYSomePaymentSigningKey GYAddress))
optionalSigningKeyFromServerConfig ServerConfig {..} = do
  case scWallet of
    Nothing → pure Nothing
    Just (MnemonicWallet MnemonicWalletDetails {..}) →
      let wk' = walletKeysFromMnemonicIndexed mnemonic (fromMaybe 0 accIx) (fromMaybe 0 addrIx)
       in pure $ case wk' of
            Left _ → Nothing
            Right wk → Just (AGYExtendedPaymentSigningKey (walletKeysToExtendedPaymentSigningKey wk) :!: walletKeysToAddress wk scNetworkId)
    Just (KeyPathWallet fp) → do
      skey ← readSomePaymentSigningKey fp
      pure $ Just (skey :!: addressFromSomePaymentSigningKey scNetworkId skey)
 where
  addressFromSomePaymentSigningKey ∷ GYNetworkId → GYSomePaymentSigningKey → GYAddress
  addressFromSomePaymentSigningKey nid skey =
    let pkh =
          case skey of
            AGYPaymentSigningKey skey' → paymentKeyHash . paymentVerificationKey $ skey'
            AGYExtendedPaymentSigningKey skey' → extendedPaymentSigningKeyToApi skey' & Api.getVerificationKey & Api.verificationKeyHash & unsafeCoerce & paymentKeyHashFromApi -- Usage of `unsafeCoerce` here as Atlas's key hash types need an overhaul since it is not powerful enough to cater for all the relevant cases.
     in addressFromPaymentKeyHash nid pkh
