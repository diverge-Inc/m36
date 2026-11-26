{-# LANGUAGE DerivingVia, DeriveGeneric, ScopedTypeVariables, BangPatterns #-}
module ProjectM36.TransactionGraph.Persist where
import ProjectM36.Error
import ProjectM36.Transaction.Persist
import ProjectM36.TransactionGraph
import ProjectM36.TransactionGraph.Types
import ProjectM36.Transaction.Types
import ProjectM36.RelationalExpression
import ProjectM36.Base
import ProjectM36.ScriptSession
import ProjectM36.DatabaseContext.Types
import ProjectM36.ValueMarker
import ProjectM36.IsomorphicSchema.Types (Schemas(Schemas))
import ProjectM36.Persist (AppendFile, openAppendFile, appendFileSize, truncateAppendFile, appendBytesSync, writeFileBytesSync, renameSync, DiskSync)
import ProjectM36.FileLock
import System.Directory
import System.FilePath
import System.IO
import qualified Data.Set as S
import qualified Data.Map as M
import Control.Monad (foldM, when)
import Data.Either (isRight)
import qualified Data.List as L
import qualified Data.List.NonEmpty as NE
import Control.Exception.Base
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BL
import qualified Crypto.Hash.SHA256 as SHA256
import System.FilePath.Glob
import Codec.Winery
import Data.Proxy
import Data.Bits (shiftL, (.|.))
import GHC.Generics (Generic)

{-
The database directory contains the transaction log "m36vX" (X is the format version), a lock file, the login roles database, and the compiled modules of functions.

The transaction log is an append-only file. Every commit appends one entry holding the new transactions and the heads of the graph. A transaction is stored as its change relative to its parent (see 'TransactionRecord'), so the size of an entry depends on what the commit changed, not on the size of the database or the length of its history. Opening the database replays the log.

An entry is framed as:

  4 bytes  length of the payload (big endian)
  8 bytes  first 8 bytes of the SHA-256 of the payload
  n bytes  payload ('LogEntry' serialised with winery)

An incomplete or damaged entry at the end of the log (a crash in the middle of a write) is ignored when reading and cut off before the next entry is appended.

Persistence requires a POSIX-compliant, journaled-metadata filesystem.
-}

expectedVersion :: Int
expectedVersion = 9

transactionLogFileName :: FilePath 
transactionLogFileName = "m36v" ++ show expectedVersion

transactionLogPath :: FilePath -> FilePath
transactionLogPath dbdir = dbdir </> transactionLogFileName

lockFilePath :: FilePath -> FilePath
lockFilePath dbdir = dbdir </> "lockFile"

-- | How many bytes of the transaction log this process has applied to its in-memory graph. If the log is longer, another process has committed in the meantime.
type LogPosition = Integer

-- | One entry of the transaction log.
data LogEntry = LogEntry {
  leTransactions :: [TransactionRecord], -- ^ new transactions, parents before children
  leHeads :: [(HeadName, TransactionId)] -- ^ all heads of the graph after this entry
  }
  deriving Generic
  deriving Serialise via WineryRecord LogEntry

{-
verify that the database directory is valid or bootstrap it 
- return error or lock file handle
-}

checkForOtherVersions :: FilePath -> IO (Either PersistenceError ())
checkForOtherVersions dbdir = do
  versionMatches <- globDir1 (compile "m36v*") dbdir
  let otherVersions = L.delete transactionLogFileName (map takeFileName versionMatches)
  pure $ case otherVersions of
    [] -> Right ()
    x : _ -> Left $ WrongDatabaseFormatVersionError transactionLogFileName x

setupDatabaseDir :: DiskSync -> FilePath -> TransactionGraph -> IO (Either PersistenceError LockFile)
setupDatabaseDir sync dbdir bootstrapGraph = do
  dbdirExists <- doesDirectoryExist dbdir
  eWrongVersion <- checkForOtherVersions dbdir
  case eWrongVersion of
    Left err -> pure (Left err)
    Right () -> do
      m36exists <- doesFileExist (transactionLogPath dbdir)  
      if dbdirExists && m36exists then
        Right <$> openLockFile (lockFilePath dbdir)
      else if not m36exists then 
        Right <$> bootstrapDatabaseDir sync dbdir bootstrapGraph
         else
           pure (Left (InvalidDirectoryError dbdir))
{- 
initialize a database directory with the graph from which to bootstrap- return lock file handle which must be closed by the caller
-}
bootstrapDatabaseDir :: DiskSync -> FilePath -> TransactionGraph -> IO LockFile
bootstrapDatabaseDir sync dbdir bootstrapGraph = do
  createDirectory dbdir
  locker <- openLockFile (lockFilePath dbdir)
  createDirectoryIfMissing False (objectFilesPath dbdir)
  _ <- bracket_ (lockFile locker WriteLock) (unlockFile locker) (transactionGraphPersist sync dbdir bootstrapGraph)
  pure locker

-- | The current size of the transaction log.
transactionLogSize :: FilePath -> IO LogPosition
transactionLogSize dbdir = getFileSize (transactionLogPath dbdir)

-- | Open the transaction log for appending.
openTransactionLog :: FilePath -> IO AppendFile
openTransactionLog dbdir = openAppendFile (transactionLogPath dbdir)

-- | Write an entire transaction graph to storage, replacing the transaction log. Not for use on a database which is open, since open connections keep appending to the log they opened.
transactionGraphPersist :: DiskSync -> FilePath -> TransactionGraph -> IO LogPosition
transactionGraphPersist sync destDirectory graph = do
  let entry = encodeLogEntry (mkLogEntry graph (transactionsForGraph graph))
      tempPath = destDirectory </> ("." <> transactionLogFileName <> ".tmp")
  writeFileBytesSync sync tempPath entry
  renameSync sync tempPath (transactionLogPath destDirectory)
  pure (fromIntegral (BS.length entry))

-- | Append the new transactions and the heads of the new graph to the transaction log. The position is how far this process has read the log; anything after it is the remains of an interrupted write and is cut off. Returns the new position. The caller must hold the write lock.
transactionGraphPersistIncremental :: DiskSync -> AppendFile -> LogPosition -> TransactionGraphIncrementalWriteInfo -> IO LogPosition
transactionGraphPersistIncremental sync logFile position tgWriteInfo = do
  let entry = encodeLogEntry (mkLogEntry (newGraph tgWriteInfo) (S.map _uncommittedTransaction (uncommittedTransactions tgWriteInfo)))
  size <- appendFileSize logFile
  when (size > position) (truncateAppendFile logFile position)
  appendBytesSync sync logFile entry
  pure (position + fromIntegral (BS.length entry))

mkLogEntry :: TransactionGraph -> S.Set Transaction -> LogEntry
mkLogEntry graph newTransactions =
  LogEntry { leTransactions = map (\trans -> transactionToRecord (firstParentRelationVariables trans graph) trans) (parentsFirst newTransactions),
             leHeads = map (\(headName, trans) -> (headName, transactionId trans)) (M.toList (transactionHeadsForGraph graph)) }

-- | Order transactions so that every transaction comes after its parents (if they are in the set).
parentsFirst :: S.Set Transaction -> [Transaction]
parentsFirst transSet = go S.empty (S.toList transSet)
  where
    ids = S.map transactionId transSet
    go _ [] = []
    go emitted remaining =
      let ready trans = all (\pid -> S.member pid emitted || S.notMember pid ids) (NE.toList (parents (transactionInfo trans)))
          (now, later) = L.partition ready remaining
      in if null now then
           remaining -- cannot happen in an acyclic graph
         else
           now ++ go (foldr (S.insert . transactionId) emitted now) later

encodeLogEntry :: LogEntry -> BS.ByteString
encodeLogEntry entry = BL.toStrict (BB.toLazyByteString (BB.word32BE (fromIntegral (BS.length payload)) <> BB.byteString (BS.take 8 (SHA256.hash payload)) <> BB.byteString payload))
  where
    payload = serialiseOnly entry

-- | Split log bytes into the payloads of the complete entries and the number of bytes they occupy.
splitLogEntries :: BS.ByteString -> ([BS.ByteString], Int)
splitLogEntries = go 0 []
  where
    go !consumed acc bytes
      | BS.length bytes < 12 = done
      | BS.length rest < len = done
      | BS.take 8 (SHA256.hash payload) /= checksum = done
      | otherwise = go (consumed + 12 + len) (payload : acc) (BS.drop len rest)
      where
        done = (reverse acc, consumed)
        len = BS.foldl' (\n w -> (n `shiftL` 8) .|. fromIntegral w) 0 (BS.take 4 bytes)
        checksum = BS.take 8 (BS.drop 4 bytes)
        rest = BS.drop 12 bytes
        payload = BS.take len rest

{-  
load any transactions which are not already part of the incoming transaction graph
-}
transactionGraphLoad :: FilePath -> TransactionGraph -> Maybe ScriptSession -> IO (Either PersistenceError TransactionGraph)
transactionGraphLoad dbdir graphIn mScriptSession = fmap fst <$> transactionGraphLoadFrom dbdir 0 graphIn mScriptSession

-- | Apply the entries of the transaction log after the position to the graph. Returns the new graph and the position up to which the log was read.
transactionGraphLoadFrom :: FilePath -> LogPosition -> TransactionGraph -> Maybe ScriptSession -> IO (Either PersistenceError (TransactionGraph, LogPosition))
transactionGraphLoadFrom dbdir position graphIn mScriptSession = do
  eBytes <- try $ withBinaryFile (transactionLogPath dbdir) ReadMode $ \h -> do
    hSeek h AbsoluteSeek position
    BS.hGetContents h
  case eBytes of
    Left (err :: IOException) -> error (show err) --rationale- reading essential database files must fail hard
    Right bytes -> do
      let (payloads, consumed) = splitLogEntries bytes
      case getDecoder (schema (Proxy :: Proxy LogEntry)) of
        Left err -> pure (Left (CorruptTransactionLogError (show err)))
        Right decoder -> do
          eGraph <- foldM (\eGraph payload -> case eGraph of
                                        Left err -> pure (Left err)
                                        Right graph -> applyLogEntry dbdir mScriptSession graph (evalDecoder decoder payload)) (Right graphIn) payloads
          pure ((\graph -> (graph, position + fromIntegral consumed)) <$> eGraph)

applyLogEntry :: FilePath -> Maybe ScriptSession -> TransactionGraph -> LogEntry -> IO (Either PersistenceError TransactionGraph)
applyLogEntry dbdir mScriptSession graphIn entry = do
  eGraph <- foldM addRecord (Right graphIn) (leTransactions entry)
  pure $ do
    graph <- eGraph
    headsAssoc <- mapM (\(headName, tid) -> case transactionForId tid graph of
                                              Left _ -> Left (MissingTransactionError tid)
                                              Right trans -> Right (headName, trans)) (leHeads entry)
    pure (TransactionGraph (M.fromList headsAssoc) (transactionsForGraph graph))
  where
    addRecord (Left err) _ = pure (Left err)
    addRecord (Right graph) record
      | isRight (transactionForId (trId record) graph) = pure (Right graph) --the transaction is already known and loaded
      | otherwise = do
          let baseRelVars = case transactionForId (NE.head (parents (trInfo record))) graph of
                Left _ -> M.empty
                Right parentTrans -> either (const M.empty) id (resolveDBC' graph (concreteDatabaseContext parentTrans) relationVariables)
          eTrans <- recordToTransaction dbdir mScriptSession baseRelVars record
          pure $ case eTrans of
            Left err -> Left err
            Right trans -> Right (TransactionGraph (transactionHeadsForGraph graph) (S.insert (withKeyIndexes graph trans) (transactionsForGraph graph)))

-- | Indexes are not stored. A relation variable inherits them from its previous version when its change is applied; this adds the ones which are missing because the relation variable or the key is new in this transaction.
withKeyIndexes :: TransactionGraph -> Transaction -> Transaction
withKeyIndexes graph trans@(Transaction tid tinfo (Schemas context sschemas)) =
  case relationVariables context of
    -- nothing to do: the relation variables are those of an earlier transaction (and the marker must stay as it is since it is part of what the Merkle hash covers)
    NotChangedSinceMarker{} -> trans
    ValueMarker relVars ->
      case resolveDBC' graph context inclusionDependencies of
        Left _ -> trans
        Right incDeps -> Transaction tid tinfo (Schemas context { relationVariables = ValueMarker (ensureAllKeyIndexes incDeps relVars) } sschemas)
