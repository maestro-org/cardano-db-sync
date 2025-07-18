{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE TypeFamilies #-}

#if __GLASGOW_HASKELL__ >= 908
{-# OPTIONS_GHC -Wno-x-partial #-}
#endif

module Cardano.Mock.Forging.Tx.Conway.Scenarios (
  delegateAndSendBlocks,
  registerDRepsAndDelegateVotes,
  registerCommitteeCreds,
) where

import Cardano.Ledger.Address (Addr (..), Withdrawals (..))
import Cardano.Ledger.Alonzo.Tx (AlonzoTx (..))
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Coin
import Cardano.Ledger.Conway.TxCert (Delegatee (..))
import Cardano.Ledger.Core (Tx ())
import Cardano.Ledger.Credential (Credential (..), StakeCredential (), StakeReference (..))
import Cardano.Ledger.DRep (DRep (..))
import Cardano.Ledger.Keys (KeyRole (..))
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Mock.Forging.Interpreter
import qualified Cardano.Mock.Forging.Tx.Conway as Conway
import Cardano.Mock.Forging.Tx.Generic
import Cardano.Mock.Forging.Types
import Cardano.Prelude
import Data.List.Extra (chunksOf)
import Data.Maybe.Strict (StrictMaybe (..))
import Ouroboros.Consensus.Cardano.Block (LedgerState (..))
import Ouroboros.Consensus.Shelley.Eras (ConwayEra ())
import Ouroboros.Consensus.Shelley.Ledger (ShelleyBlock ())
import qualified Prelude

newtype ShelleyLedgerState era = ShelleyLedgerState
  {unState :: LedgerState (ShelleyBlock PraosStandard era)}

delegateAndSendBlocks :: Int -> Interpreter -> IO [CardanoBlock]
delegateAndSendBlocks n interpreter = do
  addrFrom <- withConwayLedgerState interpreter (resolveAddress $ UTxOIndex 0)

  registerBlocks <- mkRegisterBlocks stakeCreds interpreter
  delegateBlocks <- mkDelegateBlocks stakeCreds interpreter
  sendBlocks <- mkPaymentBlocks (UTxOAddress addrFrom) addresses interpreter

  pure (registerBlocks <> delegateBlocks <> sendBlocks)
  where
    stakeCreds = createStakeCredentials n
    payCreds = createPaymentCredentials n
    addresses =
      map
        (\(payCred, stakeCred) -> Addr Testnet payCred (StakeRefBase stakeCred))
        (zip payCreds stakeCreds)

mkRegisterBlocks :: [StakeCredential] -> Interpreter -> IO [CardanoBlock]
mkRegisterBlocks creds interpreter = forgeBlocksChunked interpreter creds $ \txCreds _ ->
  Conway.mkDCertTx
    (Conway.mkRegTxCert SNothing <$> txCreds)
    (Withdrawals mempty)
    Nothing

mkDelegateBlocks :: [StakeCredential] -> Interpreter -> IO [CardanoBlock]
mkDelegateBlocks creds interpreter = forgeBlocksChunked interpreter creds $ \txCreds state' ->
  Conway.mkDCertTx
    (map (mkDelegCert state') $ zip (cycle [0, 1, 2]) txCreds)
    (Withdrawals mempty)
    Nothing
  where
    mkDelegCert state' (poolIx, cred) =
      Conway.mkDelegTxCert
        (DelegStake $ resolvePool (PoolIndex poolIx) (unState state'))
        cred

mkPaymentBlocks :: UTxOIndex ConwayEra -> [Addr] -> Interpreter -> IO [CardanoBlock]
mkPaymentBlocks utxoIx addresses interpreter =
  forgeBlocksChunked interpreter addresses $ \txAddrs ->
    Conway.mkPaymentTx' utxoIx (map mkUTxOAddress txAddrs) 0 0 . unState
  where
    mkUTxOAddress addr = (UTxOAddress addr, MaryValue (Coin 1) mempty)

-- | Forge blocks in chunks of 500 txs
forgeBlocksChunked ::
  Interpreter ->
  [a] ->
  ([a] -> ShelleyLedgerState ConwayEra -> Either ForgingError (Tx ConwayEra)) ->
  IO [CardanoBlock]
forgeBlocksChunked interpreter vs f = forM (chunksOf 500 vs) $ \blockCreds -> do
  blockTxs <- withConwayLedgerState interpreter $ \state' ->
    forM (chunksOf 10 blockCreds) $ \txCreds ->
      f txCreds (ShelleyLedgerState state')
  forgeNextFindLeader interpreter (TxConway <$> blockTxs)

registerDRepsAndDelegateVotes :: Interpreter -> IO CardanoBlock
registerDRepsAndDelegateVotes interpreter = do
  blockTxs <-
    withConwayLedgerState interpreter $
      registerDRepAndDelegateVotes'
        (Prelude.head unregisteredDRepIds)
        (StakeIndex 4)

  forgeNextFindLeader interpreter (map TxConway blockTxs)

registerDRepAndDelegateVotes' ::
  Credential 'DRepRole ->
  StakeIndex ->
  Conway.ConwayLedgerState ->
  Either ForgingError [AlonzoTx ConwayEra]
registerDRepAndDelegateVotes' drepId stakeIx ledger = do
  stakeCreds <- resolveStakeCreds stakeIx ledger

  let utxoStake = UTxOAddressNewWithStake 0 stakeIx
      regDelegCert =
        Conway.mkDelegTxCert (DelegVote $ DRepCredential drepId) stakeCreds

  paymentTx <- Conway.mkPaymentTx (UTxOIndex 0) utxoStake 10_000 500 0 ledger
  regTx <- Conway.mkRegisterDRepTx drepId
  delegTx <- Conway.mkDCertTx [regDelegCert] (Withdrawals mempty) Nothing

  pure [paymentTx, regTx, delegTx]

registerCommitteeCreds :: Interpreter -> IO CardanoBlock
registerCommitteeCreds interpreter = do
  blockTxs <- withConwayLedgerState interpreter $ \_ ->
    mapM (uncurry Conway.mkCommitteeAuthTx) bootstrapCommitteeCreds

  forgeNextFindLeader interpreter (map TxConway blockTxs)
