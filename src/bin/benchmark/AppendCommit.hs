-- | Event-sourcing style workload: append one tuple per commit to an on-disk database, then reopen and query it.
-- Used to compare against PostgreSQL running the same workload (see scripts/bench-append-postgres.sh).
import ProjectM36.Client
import ProjectM36.Base (Attributes, RelationTuple(..), RelationTupleSet(TupleList), asList)
import ProjectM36.Relation (cardinality, tupleSet)
import ProjectM36.Tuple (tupleAtoms)
import Control.Exception (evaluate)
import qualified ProjectM36.Attribute as A
import qualified Data.Text as T
import qualified Data.Map as M
import qualified Data.Vector as V
import Options.Applicative
import GHC.Clock (getMonotonicTime)
import Control.Monad
import System.Random
import System.Directory (doesDirectoryExist)
import System.IO
import Text.Printf

data Mode = WriteMode' | ReadMode'
  deriving (Eq, Show)

data Opts = Opts { datadir :: FilePath,
                   mode :: Mode,
                   startId :: Int,
                   eventCount :: Int,
                   batchSize :: Int,
                   useFsync :: Bool,
                   useKey :: Bool,
                   lookups :: Int,
                   mutations :: Int
                 }

parseOptions :: Parser Opts
parseOptions = Opts <$>
  strOption (long "datadir" <> short 'd') <*>
  flag ReadMode' WriteMode' (long "write" <> short 'w' <> help "append events (default: reopen and query)") <*>
  option auto (long "start" <> value 1 <> help "first event id to write") <*>
  option auto (long "count" <> short 'c' <> value 1000) <*>
  option auto (long "batch" <> value 500 <> help "report timing every n commits") <*>
  switch (long "fsync" <> help "use CrashSafePersistence (fsync) instead of MinimalPersistence") <*>
  switch (long "key" <> help "add a uniqueness constraint on id when the relvar is created") <*>
  option auto (long "lookups" <> value 1000 <> help "number of point lookups in read mode") <*>
  option auto (long "mutations" <> value 0 <> help "in read mode, also update and then delete this many events by id, one commit each")

eventAttrs :: Attributes
eventAttrs = A.attributesFromList [Attribute "id" IntegerAtomType,
                                   Attribute "kind" TextAtomType,
                                   Attribute "payload" TextAtomType]

eventTuple :: Int -> RelationTuple
eventTuple i = RelationTuple eventAttrs (V.fromList [IntegerAtom (fromIntegral i),
                                                    TextAtom (kinds !! (i `mod` length kinds)),
                                                    TextAtom (T.replicate 4 "0123456789abcdefghijklmno" <> T.pack (show i))])
  where
    kinds = ["created", "renamed", "moved", "archived"]

insertEvent :: Int -> DatabaseContextExpr
insertEvent i = Insert "event" (MakeStaticRelation eventAttrs (TupleList [eventTuple i]))

eCheck :: Show e => IO (Either e a) -> IO a
eCheck v = do
  x <- v
  case x of
    Left err -> error (show err)
    Right x' -> pure x'

timed :: IO a -> IO (Double, a)
timed act = do
  t0 <- getMonotonicTime
  r <- act
  t1 <- getMonotonicTime
  pure (t1 - t0, r)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  opts <- execParser (info (parseOptions <**> helper) (fullDesc <> progDesc "Append-and-commit benchmark for on-disk databases."))
  rando <- initStdGen
  exists <- doesDirectoryExist (datadir opts)
  let strat = if useFsync opts then CrashSafePersistence (datadir opts) else MinimalPersistence (datadir opts)
      connInfo = InProcessConnectionInfo strat emptyNotificationCallback [] basicDatabaseContext rando adminRoleName
  (openSecs, (conn, sessionId)) <- timed $ do
    conn <- eCheck $ connectProjectM36 connInfo
    sessionId <- eCheck $ createSessionAtHead conn "master"
    pure (conn, sessionId)
  printf "open: %.3f s\n" openSecs
  case mode opts of
    WriteMode' -> do
      unless exists $ do
        eCheck $ executeDatabaseContextExpr sessionId conn (Define "event" (map NakedAttributeExpr (A.toList eventAttrs)))
        when (useKey opts) $
          eCheck $ executeDatabaseContextExpr sessionId conn (databaseContextExprForUniqueKey "event" ["id"])
        eCheck $ commit sessionId conn
      let ids = [startId opts .. startId opts + eventCount opts - 1]
          batches = chunk (batchSize opts) ids
      (totalSecs, ()) <- timed $ forM_ batches $ \batch -> do
        (secs, parts) <- timed $ forM batch $ \i -> do
          (execSecs, ()) <- timed $ eCheck $ executeDatabaseContextExpr sessionId conn (insertEvent i)
          (commitSecs, ()) <- timed $ eCheck $ commit sessionId conn
          pure (execSecs, commitSecs)
        let perCommit t = t * 1000 / fromIntegral (length batch)
        printf "append %d..%d: %.3f ms/commit (insert %.3f, commit %.3f)\n" (minimum batch) (maximum batch) (perCommit secs) (perCommit (sum (map fst parts))) (perCommit (sum (map snd parts)))
      printf "append total: %d commits in %.3f s (%.1f commits/s)\n" (eventCount opts) totalSecs (fromIntegral (eventCount opts) / totalSecs)
    ReadMode' -> do
      -- read every tuple: sum the ids and the payload lengths
      let scan = do
            rel <- eCheck $ executeRelationalExpr sessionId conn (RelationVariable "event" ())
            let visit (count, total) tup = case V.toList (tupleAtoms tup) of
                  [IntegerAtom i, TextAtom _, TextAtom payload] -> (count + 1, total + fromIntegral i + T.length payload)
                  _ -> error "unexpected tuple"
            evaluate (foldl' visit (0 :: Int, 0 :: Int) (asList (tupleSet rel)))
      (scanSecs, (n, checksum)) <- timed scan
      printf "scan: %d tuples in %.3f ms (checksum %d)\n" n (scanSecs * 1000) checksum
      scan2Secs <- minimum <$> replicateM 10 (fst <$> timed scan)
      printf "scan (best of 10): %.3f ms\n" (scan2Secs * 1000)
      gen <- newStdGen
      let keys = take (lookups opts) (randomRs (1, max 1 n) gen)
      (lookupSecs, found) <- timed $ forM keys $ \k -> do
        r <- eCheck $ executeRelationalExpr sessionId conn
             (Restrict (AttributeEqualityPredicate "id" (NakedAtomExpr (IntegerAtom (fromIntegral k)))) (RelationVariable "event" ()))
        pure (cardinality r == Finite 1)
      printf "lookup by id: %.4f ms each (%d/%d found)\n" (lookupSecs * 1000 / fromIntegral (lookups opts)) (length (filter id found)) (lookups opts)
      (noopSecs, ()) <- timed $ replicateM_ 1000 (eCheck $ executeDatabaseContextExpr sessionId conn NoOperation)
      printf "no-op database context expression: %.4f ms each\n" noopSecs
      let filterByKind = do
            r <- eCheck $ executeRelationalExpr sessionId conn
                 (Restrict (AttributeEqualityPredicate "kind" (NakedAtomExpr (TextAtom "moved"))) (RelationVariable "event" ()))
            evaluate (length (asList (tupleSet r)))
      (filterSecs, filtered) <- timed filterByKind
      printf "filter by kind: %d tuples in %.3f ms\n" filtered (filterSecs * 1000)
      filter2Secs <- minimum <$> replicateM 10 (fst <$> timed filterByKind)
      printf "filter by kind (best of 10): %.3f ms\n" (filter2Secs * 1000)
      when (mutations opts > 0) $ do
        let targets = take (mutations opts) [1, 1 + max 1 (n `div` mutations opts) .. n]
            byId k = AttributeEqualityPredicate "id" (NakedAtomExpr (IntegerAtom (fromIntegral k)))
            perOp secs = secs * 1000 / fromIntegral (length targets)
        (updateSecs, ()) <- timed $ forM_ targets $ \k -> do
          eCheck $ executeDatabaseContextExpr sessionId conn (Update "event" (M.singleton "payload" (NakedAtomExpr (TextAtom "updated"))) (byId k))
          eCheck $ commit sessionId conn
        printf "update by id: %.3f ms/commit\n" (perOp updateSecs)
        (deleteSecs, ()) <- timed $ forM_ targets $ \k -> do
          eCheck $ executeDatabaseContextExpr sessionId conn (Delete "event" (byId k))
          eCheck $ commit sessionId conn
        printf "delete by id: %.3f ms/commit\n" (perOp deleteSecs)
        remaining <- eCheck $ executeRelationalExpr sessionId conn (RelationVariable "event" ())
        printf "tuples after update and delete: %s\n" (show (cardinality remaining))
  (closeSecs, ()) <- timed (close conn)
  printf "close: %.3f s\n" closeSecs

chunk :: Int -> [a] -> [[a]]
chunk _ [] = []
chunk n xs = let (a, b) = splitAt n xs in a : chunk n b
