{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoImplicitPrelude     #-}
{-# LANGUAGE OverloadedStrings     #-}
-- {-# LANGUAGE RankNTypes            #-}
-- {-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
{-# OPTIONS_GHC -Wall #-}

module Offchain.LockScriptWOF where


import           Cardano.Api as Cardano
import           Cardano.Api                          (PlutusScriptV1,
                                                       PlutusScriptV2,
                                                       writeFileTextEnvelope, Script)
import           Cardano.Api.Shelley                  (PlutusScript (..), PlutusScript(PlutusScriptSerialised), Address(..) )

import qualified Codec.Serialise             as Codec
import           Codec.Serialise
import qualified Data.ByteString.Lazy                 as LBS

import           GHC.Generics           ( Generic )
import qualified Data.ByteString.Short                as SBS
import qualified Data.ByteString.Base16 as B16
import           Data.Functor                         (void)
import           Data.Text                   (pack, unpack, Text)
import           Data.String                                    (fromString)
import qualified Data.Maybe                           as DM (fromJust, fromMaybe)
import qualified Ledger.Typed.Scripts                 as Scripts
import           Ledger.Value                         as Value
import qualified         Data.Aeson                  (decode, encode)
import qualified Ledger.Address                       as LAD
import qualified Plutus.Script.Utils.V1.Typed.Scripts as PSU.V1
import qualified Plutus.Script.Utils.V2.Typed.Scripts as PSU.V2
import qualified Plutus.Script.Utils.V2.Typed.Scripts.Validators as PSUV.V2
import qualified Plutus.V1.Ledger.Api                 as PlutusV1
import qualified Plutus.V1.Ledger.Contexts            as PlutusV1
import qualified Plutus.V1.Ledger.Scripts             as PLV1
import qualified Plutus.V2.Ledger.Api                 as PlutusV2
import qualified Plutus.V2.Ledger.Contexts            as PlutusV2
import           PlutusTx                             (getPir)
import           Data.Aeson                  (decode, encode, FromJSON, ToJSON)
import qualified PlutusTx
import qualified PlutusTx.Builtins
import           PlutusTx.Prelude                     as P hiding (Semigroup (..),unless)
import           Plutus.V1.Ledger.Crypto     as Plutus
import           Ledger.Constraints   (TxConstraints)
import qualified Ledger.Constraints   as Constraints
import Plutus.Contract as Contract 
import Ledger 
import           Prelude              (IO, Semigroup (..), Show (..), String)
import qualified Prelude
import           Ledger.Ada           as Ada
import           Schema               (ToSchema)
import           Text.Printf            (printf)
-- What does it do?
-- Stores info regarding how much ALice deposited
-- 2 Actions, Lock & UNlock the funds


data LockDatum = LockDatum {

    depositAmount :: !Integer,
    ownerKeyHash  :: PubKeyHash

} deriving (Show, FromJSON, ToJSON, Generic)

instance Eq LockDatum where
    {-# INLINABLE (==) #-}
    LockDatum d1 p1 == LockDatum d2 p2 = p1 == p2 && d1 == d2

PlutusTx.unstableMakeIsData ''LockDatum

type AmountToUnlock = Integer
type Password       = Integer

data UserAction = Unlock AmountToUnlock Password deriving (Show, FromJSON, ToJSON, Generic)

PlutusTx.makeLift ''UserAction
PlutusTx.makeIsDataIndexed ''UserAction
 [
   ( 'Unlock, 1 )
 ]

{-# INLINEABLE lockScript #-}
lockScript :: LockDatum -> UserAction -> PlutusV2.ScriptContext -> Bool
lockScript dt rd ctx = traceIfFalse "Oops wrong password" checkPass &&
                       traceIfFalse "Oops not correct signature" checkSign
    
    where

      info :: PlutusV2.TxInfo
      info =  PlutusV2.scriptContextTxInfo ctx

      checkSign :: Bool
      checkSign = PlutusV2.txSignedBy info $ ownerKeyHash dt

      checkPass :: Bool
      checkPass = case rd of 
                    Unlock amt psw -> psw == (42 :: Integer)
                    _              -> False

      checkAmou :: Bool
      checkAmou = case rd of
                   Unlock amt _ -> amt == depositAmount dt
                   _            -> False
      
      getTxInputs :: [PlutusV2.TxInInfo]
      getTxInputs = PlutusV2.txInfoInputs info
      
      depositsEnoughAda :: Bool
      depositsEnoughAda = case Value.flattenValue . PlutusV2.txOutValue . PlutusV2.txInInfoResolved $ head getTxInputs of
                            [(cs, tn, amt)] -> case amt P.>= 10000000 of
                                                True -> True
                                                False -> False
                            _               -> False

typedValidator :: PlutusV2.Validator 
typedValidator = PLV1.mkValidatorScript $$(PlutusTx.compile [|| wrap ||])
   where
      wrap = PSUV.V2.mkUntypedValidator lockScript


-- untypedValidatorV2 :: PSU.V2.Validator -- There is not yet a way to make a V2 typed validator (PLT-494)
-- untypedValidatorV2 = PlutusV2.mkValidatorScript $$(PlutusTx.compile [|| PSU.V2.mkUntypedValidator lockScript ||])

lockingScript :: PlutusV2.Script
lockingScript = PlutusV2.unValidatorScript typedValidator


{-
    As a Short Byte String
-}

scriptSBS :: SBS.ShortByteString
scriptSBS = SBS.toShort . LBS.toStrict . serialise $ lockingScript

{-
    As a Serialised Script
-}

serialisedScript :: PlutusScript PlutusScriptV2
serialisedScript = PlutusScriptSerialised $ scriptSBS

writeSerialisedScript :: IO ()
writeSerialisedScript = void $ writeFileTextEnvelope "locking-v2.plutus" Nothing serialisedScript


-- OFFCHAIN PART STARTS

data LockParams = LockParams {
    userAddr :: PubKeyHash,
    adaMount :: !Integer
} deriving (Generic, ToJSON, FromJSON, ToSchema)

-- newtype UnlockParams = UnlockParams {
--     infoUser :: UserAction
-- }  deriving (Generic, ToJSON, FromJSON, ToSchema)



type LockingSchema = Endpoint "lock" LockParams


contractLock :: Contract () LockingSchema Text ()
contractLock = do
    now <- currentTime
    Contract.logInfo @String $ "now: " ++ show now
    Contract.logInfo @String $ "1: pay to the script address"
    let tx1 = Constraints.mustPayToTheScript Value valHash unitDatum $ Ada.lovelaceValueOf 25000000
    ledgerTx1 <- submitTx tx1
    void $ awaitTxConfirmed $ getCardanoTxId ledgerTx1
    logInfo @String $ printf "made a gift of %d lovelace to %s with deadline %s"



-- lockit :: AsContractError e => LockParams -> Contract w s e ()
-- lockit lp = do
--     let dat = LockDatum
--                 { depositAmount = adaMount lp
--                 , ownerKeyHash    = userAddr lp
--                 }
--         tx  = Constraints.mustPayToTheScript dat $ Ada.lovelaceValueOf $ adaMount lp
--     ledgerTx <- submitTxConstraints typedValidator tx
--     void $ awaitTxConfirmed $ getCardanoTxId ledgerTx
--     logInfo @String $ printf "made a gift of %d lovelace to %s with deadline %s"
--         (adaMount lp)
--         (show $ userAddr lp)
--         (show $ adaMount lp)

-- endpoints :: Contract () LockingSchema Text ()
-- endpoints = awaitPromise give' >> endpoints
--   where
--     give' = endpoint @"lock" lockit
--     -- grab' = endpoint @"grab" $ const grab